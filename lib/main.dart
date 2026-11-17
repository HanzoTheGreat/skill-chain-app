import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path_provider/path_provider.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

const _widgetChannel = MethodChannel('skill_chain_app/widget');

/// Prüft, ob auf dem Homescreen-Widget der Modus geändert wurde, und synchronisiert SQLite.
Future<bool> _resolveAndSyncPublicMode() async {
  bool mode = await getPublicMode();
  try {
    final widgetOverride = await _widgetChannel.invokeMethod<bool?>(
      'consumeWidgetModeOverride',
    );
    if (widgetOverride != null && widgetOverride != mode) {
      mode = widgetOverride;
      await setPublicMode(isOutInPublic: mode);
    } else {
      await _widgetChannel.invokeMethod('syncModeToWidget', {
        'isPublic': mode,
      });
    }
  } catch (_) {}
  return mode;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final appDir = await getApplicationDocumentsDirectory();
  await initDb(appDir: appDir.path);

  final initialMode = await _resolveAndSyncPublicMode();

  runApp(SkillChainApp(initialPublicMode: initialMode));
}

class SkillChainApp extends StatelessWidget {
  final bool initialPublicMode;
  const SkillChainApp({super.key, required this.initialPublicMode});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Skill & Kaskaden App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4FC3F7),
          secondary: Color(0xFFFFB74D),
          error: Color(0xFFE53935),
          surface: Color(0xFF1E1E1E),
        ),
        useMaterial3: true,
      ),
      home: MainNavigationScreen(initialPublicMode: initialPublicMode),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  final bool initialPublicMode;
  const MainNavigationScreen({super.key, required this.initialPublicMode});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  late bool _isOutInPublic;
  bool _isRunnerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isOutInPublic = widget.initialPublicMode;
    _setupWidgetListener();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncFromWidgetIfChanged();
    }
  }

  Future<void> _syncFromWidgetIfChanged() async {
    final mode = await _resolveAndSyncPublicMode();
    if (mounted && mode != _isOutInPublic) {
      setState(() => _isOutInPublic = mode);
    }
  }

  Future<void> _setupWidgetListener() async {
    _widgetChannel.setMethodCallHandler((call) async {
      if (call.method == 'triggerEmergencyNow') {
        await _launchEmergencyCascadeFromAnywhere();
      } else if (call.method == 'onWidgetModeChanged') {
        final newMode = call.arguments as bool? ?? false;
        await setPublicMode(isOutInPublic: newMode);
        if (mounted) {
          setState(() => _isOutInPublic = newMode);
        }
      }
    });

    try {
      final launchedFromWidget =
          await _widgetChannel.invokeMethod<bool>('consumeEmergencyLaunch') ??
              false;
      if (launchedFromWidget) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _launchEmergencyCascadeFromAnywhere();
        });
      }
    } catch (_) {}
  }

  Future<void> _launchEmergencyCascadeFromAnywhere() async {
    final currentMode = await _resolveAndSyncPublicMode();
    bool isLocked = false;
    try {
      isLocked =
          await _widgetChannel.invokeMethod<bool>('isDeviceLocked') ?? false;
    } catch (_) {}

    if (mounted) {
      setState(() {
        _isOutInPublic = currentMode;
        _currentIndex = 0;
      });
    }

    final chain = await getActiveEmergencyChain(isOutInPublic: currentMode);
    if (!mounted) return;

    if (chain == null || chain.skills.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            currentMode
                ? 'Keine passenden Skills in deiner Unterwegs-Kette gefunden!'
                : 'Keine Skills in deiner Zuhause-Kette gefunden!',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (_isRunnerOpen) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }

    _isRunnerOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => EmergencyCascadeRunnerScreen(
          initialChain: chain,
          initialIsOutInPublic: currentMode,
          launchedOnLockedScreen: isLocked,
          onModeChangedInsideRunner: (newMode) async {
            setState(() => _isOutInPublic = newMode);
            await setPublicMode(isOutInPublic: newMode);
            try {
              await _widgetChannel.invokeMethod('syncModeToWidget', {
                'isPublic': newMode,
              });
            } catch (_) {}
          },
        ),
      ),
    );
    _isRunnerOpen = false;

    if (isLocked) {
      try {
        await _widgetChannel.invokeMethod('finishApp');
      } catch (_) {}
    }
  }

  Future<void> _togglePublicMode() async {
    final nextMode = !_isOutInPublic;
    setState(() {
      _isOutInPublic = nextMode;
    });
    await setPublicMode(isOutInPublic: nextMode);
    try {
      await _widgetChannel.invokeMethod('syncModeToWidget', {
        'isPublic': nextMode,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          _currentIndex == 0 ? 'Skills & Akut-Hilfe' : 'Skillketten-Editor',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: _currentIndex == 0
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    avatar: Icon(
                      _isOutInPublic ? Icons.public : Icons.lock,
                      size: 18,
                      color: _isOutInPublic
                          ? Colors.amberAccent
                          : Colors.greenAccent,
                    ),
                    label: Text(
                      _isOutInPublic ? 'Unterwegs' : 'Privat / Zuhause',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    selected: !_isOutInPublic,
                    onSelected: (_) => _togglePublicMode(),
                  ),
                ),
              ]
            : null,
      ),
      body: _currentIndex == 0
          ? SkillDashboardTab(
              isOutInPublic: _isOutInPublic,
              onTriggerEmergency: _launchEmergencyCascadeFromAnywhere,
            )
          : const ChainBuilderTab(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'Skillen & Notfall',
          ),
          NavigationDestination(
            icon: Icon(Icons.link_outlined),
            selectedIcon: Icon(Icons.link),
            label: 'Ketten-Editor',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// TAB 1: SKILL-ZENTRALE & NOTFALLKNOPF
// ============================================================================

class SkillDashboardTab extends StatefulWidget {
  final bool isOutInPublic;
  final VoidCallback onTriggerEmergency;

  const SkillDashboardTab({
    super.key,
    required this.isOutInPublic,
    required this.onTriggerEmergency,
  });

  @override
  State<SkillDashboardTab> createState() => _SkillDashboardTabState();
}

class _SkillDashboardTabState extends State<SkillDashboardTab> {
  TensionZone _selectedZone = TensionZone.low;
  List<Skill> _skills = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  @override
  void didUpdateWidget(covariant SkillDashboardTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOutInPublic != widget.isOutInPublic) {
      _loadSkills();
    }
  }

  Future<void> _loadSkills() async {
    setState(() => _isLoading = true);
    try {
      final loaded = await getSkills(zoneFilter: _selectedZone);
      final filtered = widget.isOutInPublic
          ? loaded.where((s) => !s.onlyPrivate).toList()
          : loaded;
      setState(() {
        _skills = filtered;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler beim Laden: $e')),
        );
      }
    }
  }

  Future<void> _showSkillFormDialog({Skill? existingSkill}) async {
    final isEditing = existingSkill != null;
    final titleCtrl = TextEditingController(text: existingSkill?.title ?? '');
    final descCtrl = TextEditingController(
      text: existingSkill?.description ?? '',
    );
    TensionZone dialogZone = existingSkill?.zone ?? _selectedZone;
    bool onlyPrivate = existingSkill?.onlyPrivate ?? false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(
                isEditing ? 'Skill bearbeiten' : 'Eigenen Skill hinzufügen',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name des Skills',
                        hintText: 'z.B. Kalte Dusche, Igelball...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Konkrete Handlungsanweisung',
                        hintText: 'Was genau musst du tun?',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Anspannungsbereich:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<TensionZone>(
                      value: dialogZone,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: TensionZone.low,
                          child: Text('Niedrig (0 - 50)'),
                        ),
                        DropdownMenuItem(
                          value: TensionZone.high,
                          child: Text('Hoch (55 - 70)'),
                        ),
                        DropdownMenuItem(
                          value: TensionZone.emergency,
                          child: Text('Hochanspannung (> 70)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => dialogZone = val);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Nur privat / zuhause möglich'),
                      subtitle: const Text(
                        'Wird ausgeblendet, wenn oben "Unterwegs" aktiv ist.',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: onlyPrivate,
                      onChanged: (val) {
                        setDialogState(() => onlyPrivate = val);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (titleCtrl.text.trim().isEmpty) return;
                    if (isEditing) {
                      await updateSkill(
                        skillId: existingSkill.id,
                        title: titleCtrl.text.trim(),
                        description: descCtrl.text.trim(),
                        zone: dialogZone,
                        onlyPrivate: onlyPrivate,
                      );
                    } else {
                      await addCustomSkill(
                        title: titleCtrl.text.trim(),
                        description: descCtrl.text.trim(),
                        zone: dialogZone,
                        onlyPrivate: onlyPrivate,
                      );
                    }
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  },
                  child: Text(isEditing ? 'Änderungen speichern' : 'Speichern'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true) {
      setState(() => _selectedZone = dialogZone);
      _loadSkills();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showSkillFormDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Neuer Skill'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SizedBox(
              width: double.infinity,
              height: 76,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD32F2F),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 6,
                ),
                onPressed: widget.onTriggerEmergency,
                icon: const Icon(Icons.warning_amber_rounded, size: 34),
                label: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NOTFALL-KASKADE STARTEN',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                    ),
                    Text(
                      widget.isOutInPublic
                          ? '🌍 Modus: UNTERWEGS-Kaskade (> 70)'
                          : '🏠 Modus: ZUHAUSE-Kaskade (> 70)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildZoneButton(
                  zone: TensionZone.low,
                  title: '0 – 50',
                  subtitle: 'Niedrig',
                  activeColor: Colors.teal.shade700,
                ),
                const SizedBox(width: 8),
                _buildZoneButton(
                  zone: TensionZone.high,
                  title: '55 – 70',
                  subtitle: 'Hoch',
                  activeColor: Colors.deepOrange.shade700,
                ),
                const SizedBox(width: 8),
                _buildZoneButton(
                  zone: TensionZone.emergency,
                  title: '> 70',
                  subtitle: 'Akut-Skills',
                  activeColor: Colors.red.shade900,
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _skills.isEmpty
                    ? const Center(
                        child: Text(
                          'Keine Skills in diesem Bereich vorhanden.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                        itemCount: _skills.length,
                        itemBuilder: (ctx, i) {
                          final skill = _skills[i];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              onTap: () =>
                                  _showSkillFormDialog(existingSkill: skill),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      skill.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 17,
                                      ),
                                    ),
                                  ),
                                  if (skill.onlyPrivate)
                                    const Tooltip(
                                      message: 'Nur Privat / Zuhause',
                                      child: Icon(
                                        Icons.lock_outline,
                                        size: 18,
                                        color: Colors.amberAccent,
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: Text(
                                  skill.description,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Skill bearbeiten',
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      color: Colors.white60,
                                    ),
                                    onPressed: () => _showSkillFormDialog(
                                      existingSkill: skill,
                                    ),
                                  ),
                                  if (skill.isCustom)
                                    IconButton(
                                      tooltip: 'Skill löschen',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.redAccent,
                                      ),
                                      onPressed: () async {
                                        await deleteSkill(skillId: skill.id);
                                        _loadSkills();
                                      },
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoneButton({
    required TensionZone zone,
    required String title,
    required String subtitle,
    required Color activeColor,
  }) {
    final isSelected = _selectedZone == zone;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          setState(() => _selectedZone = zone);
          _loadSkills();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: isSelected ? activeColor : const Color(0xFF262626),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? Colors.white : Colors.white12,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: isSelected ? Colors.white : Colors.white70,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected ? Colors.white : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// TAB 2: DRAG & DROP SKILLKETTEN-EDITOR
// ============================================================================

class ChainBuilderTab extends StatefulWidget {
  const ChainBuilderTab({super.key});

  @override
  State<ChainBuilderTab> createState() => _ChainBuilderTabState();
}

class _ChainBuilderTabState extends State<ChainBuilderTab> {
  List<SkillChain> _chains = [];
  SkillChain? _selectedChain;
  List<Skill> _allAvailableSkills = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final chains = await getAllChains();
    final allSkills = await getSkills(zoneFilter: null);

    SkillChain? currentSelected;
    if (_selectedChain != null) {
      currentSelected = chains
          .where((c) => c.id == _selectedChain!.id)
          .firstOrNull;
    }
    currentSelected ??= chains.where((c) => c.isActivePrivate).firstOrNull ??
        chains.firstOrNull;

    setState(() {
      _chains = chains;
      _selectedChain = currentSelected;
      _allAvailableSkills = allSkills;
      _isLoading = false;
    });
  }

  Future<void> _saveCurrentChainOrder() async {
    if (_selectedChain == null) return;
    final ids = Int64List.fromList(
      _selectedChain!.skills.map((s) => s.id).toList(),
    );
    await updateChainSteps(
      chainId: _selectedChain!.id,
      orderedSkillIds: ids,
    );
  }

  Future<void> _showCreateChainDialog() async {
    final nameCtrl = TextEditingController();
    bool forPrivate = false;
    bool forPublic = false;

    final newChainId = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Neue Skillkette anlegen'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name der Kette',
                        hintText: 'z.B. Supermarkt-Notfall, Essdrang-Stopp...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('🏠 Für "Privat / Zuhause" aktivieren'),
                      value: forPrivate,
                      onChanged: (v) =>
                          setDialogState(() => forPrivate = v ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('🌍 Für "Unterwegs" aktivieren'),
                      value: forPublic,
                      onChanged: (v) =>
                          setDialogState(() => forPublic = v ?? false),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (nameCtrl.text.trim().isEmpty) return;
                    final id = await createChain(
                      name: nameCtrl.text.trim(),
                      setForPrivate: forPrivate,
                      setForPublic: forPublic,
                    );
                    if (ctx.mounted) Navigator.pop(ctx, id);
                  },
                  child: const Text('Anlegen'),
                ),
              ],
            );
          },
        );
      },
    );

    if (newChainId != null) {
      await _loadData();
      setState(() {
        _selectedChain = _chains.where((c) => c.id == newChainId).firstOrNull;
      });
    }
  }

  Future<void> _showAddSkillToChainSheet() async {
    if (_selectedChain == null) return;

    final chosen = await showModalBottomSheet<Skill>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, scrollCtrl) {
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Skill zur Kette hinzufügen',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    itemCount: _allAvailableSkills.length,
                    itemBuilder: (ctx, i) {
                      final s = _allAvailableSkills[i];
                      return ListTile(
                        leading: _zoneBadge(s.zone),
                        title: Row(
                          children: [
                            Expanded(child: Text(s.title)),
                            if (s.onlyPrivate)
                              const Padding(
                                padding: EdgeInsets.only(left: 6.0),
                                child: Icon(
                                  Icons.lock_outline,
                                  size: 16,
                                  color: Colors.amberAccent,
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          s.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.add_circle_outline),
                        onTap: () => Navigator.pop(ctx, s),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (chosen != null) {
      setState(() {
        _selectedChain!.skills.add(chosen);
      });
      await _saveCurrentChainOrder();
    }
  }

  Widget _zoneBadge(TensionZone z) {
    final (label, color) = switch (z) {
      TensionZone.low => ('0-50', Colors.teal),
      TensionZone.high => ('55-70', Colors.deepOrange),
      TensionZone.emergency => ('>70', Colors.redAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  String _formatChainDropdownTitle(SkillChain c) {
    final badges = <String>[];
    if (c.isActivePrivate) badges.add('🏠');
    if (c.isActivePublic) badges.add('🌍');
    final prefix = badges.isNotEmpty ? '${badges.join()} ' : '';
    return '$prefix${c.name}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSkillToChainSheet,
        icon: const Icon(Icons.add_link),
        label: const Text('Skill einfügen'),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            color: const Color(0xFF1E1E1E),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _selectedChain?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Gewählte Skillkette bearbeiten',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        items: _chains.map((c) {
                          return DropdownMenuItem<int>(
                            value: c.id,
                            child: Text(
                              _formatChainDropdownTitle(c),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (id) {
                          if (id == null) return;
                          setState(() {
                            _selectedChain = _chains.firstWhere(
                              (c) => c.id == id,
                            );
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Neue Kette erstellen',
                      onPressed: _showCreateChainDialog,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                if (_selectedChain != null) ...[
                  const SizedBox(height: 6),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '🏠 Als Notfallkette für "Privat / Zuhause"',
                      style: TextStyle(fontSize: 13),
                    ),
                    value: _selectedChain!.isActivePrivate,
                    activeColor: Colors.greenAccent,
                    onChanged: (val) async {
                      if (val) {
                        await setActiveChainForMode(
                          chainId: _selectedChain!.id,
                          forPublicMode: false,
                        );
                        _loadData();
                      }
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '🌍 Als Notfallkette für "Unterwegs"',
                      style: TextStyle(fontSize: 13),
                    ),
                    value: _selectedChain!.isActivePublic,
                    activeColor: Colors.amberAccent,
                    onChanged: (val) async {
                      if (val) {
                        await setActiveChainForMode(
                          chainId: _selectedChain!.id,
                          forPublicMode: true,
                        );
                        _loadData();
                      }
                    },
                  ),
                ],
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.drag_indicator, size: 18, color: Colors.white54),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Gedrückt halten & ziehen, um die Reihenfolge zu ändern:',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: _selectedChain == null || _selectedChain!.skills.isEmpty
                ? const Center(
                    child: Text(
                      'Diese Kette ist noch leer.\nFüge unten rechts Skills hinzu!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                    itemCount: _selectedChain!.skills.length,
                    onReorder: (oldIndex, newIndex) async {
                      setState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = _selectedChain!.skills.removeAt(oldIndex);
                        _selectedChain!.skills.insert(newIndex, item);
                      });
                      await _saveCurrentChainOrder();
                    },
                    itemBuilder: (ctx, index) {
                      final skill = _selectedChain!.skills[index];
                      return Card(
                        key: ValueKey('chain_step_${index}_${skill.id}'),
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.white12,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  skill.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (skill.onlyPrivate)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4.0),
                                  child: Icon(
                                    Icons.lock_outline,
                                    size: 15,
                                    color: Colors.amberAccent,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            skill.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _zoneBadge(skill.zone),
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () async {
                                  setState(() {
                                    _selectedChain!.skills.removeAt(index);
                                  });
                                  await _saveCurrentChainOrder();
                                },
                              ),
                              const Icon(
                                Icons.drag_handle,
                                color: Colors.white54,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// VOLLBILD NOTFALL-KASKADEN-RUNNER (Inkl. Direkt-Moduswechsel ohne PIN!)
// ============================================================================

class EmergencyCascadeRunnerScreen extends StatefulWidget {
  final SkillChain initialChain;
  final bool initialIsOutInPublic;
  final bool launchedOnLockedScreen;
  final Future<void> Function(bool newMode) onModeChangedInsideRunner;

  const EmergencyCascadeRunnerScreen({
    super.key,
    required this.initialChain,
    required this.initialIsOutInPublic,
    required this.onModeChangedInsideRunner,
    this.launchedOnLockedScreen = false,
  });

  @override
  State<EmergencyCascadeRunnerScreen> createState() =>
      _EmergencyCascadeRunnerScreenState();
}

class _EmergencyCascadeRunnerScreenState
    extends State<EmergencyCascadeRunnerScreen> {
  late SkillChain _chain;
  late bool _isOutInPublic;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _chain = widget.initialChain;
    _isOutInPublic = widget.initialIsOutInPublic;
  }

  Future<void> _setModeDirectly(bool targetPublicMode) async {
    if (targetPublicMode == _isOutInPublic) return;

    final nextChain = await getActiveEmergencyChain(
      isOutInPublic: targetPublicMode,
    );
    if (!mounted) return;

    if (nextChain == null || nextChain.skills.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            targetPublicMode
                ? 'Keine passenden Skills in der Unterwegs-Kette!'
                : 'Keine Skills in der Zuhause-Kette!',
          ),
          backgroundColor: Colors.orange.shade900,
        ),
      );
      return;
    }

    setState(() {
      _isOutInPublic = targetPublicMode;
      _chain = nextChain;
      _currentIndex = 0;
    });

    await widget.onModeChangedInsideRunner(targetPublicMode);
  }

  void _nextStep() {
    if (_currentIndex < _chain.skills.length - 1) {
      setState(() => _currentIndex++);
    } else {
      _showEndOfChainDialog();
    }
  }

  void _showEndOfChainDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Kette komplett durchlaufen'),
        content: const Text(
          'Wie ist deine Anspannung jetzt? Möchtest du die Kaskade noch einmal von vorn starten oder beenden?',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _currentIndex = 0);
            },
            child: const Text('Nochmal von vorn'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('Anspannung ist gesunken (Beenden)'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentSkill = _chain.skills[_currentIndex];
    final total = _chain.skills.length;
    final progress = (_currentIndex + 1) / total;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.red.shade900,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SCHRITT ${_currentIndex + 1} VON $total',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                letterSpacing: 1.1,
              ),
            ),
            Text(
              _chain.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.black26,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            minHeight: 6,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // DIREKT-UMSCHALTER FÜR ZUHAUSE VS. UNTERWEGS (Geht komplett ohne PIN!)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: !_isOutInPublic
                            ? Colors.green.shade800
                            : const Color(0xFF222222),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: !_isOutInPublic
                                ? Colors.greenAccent
                                : Colors.white12,
                            width: !_isOutInPublic ? 2 : 1,
                          ),
                        ),
                      ),
                      onPressed: () => _setModeDirectly(false),
                      icon: const Text('🏠', style: TextStyle(fontSize: 16)),
                      label: const Text(
                        'ZUHAUSE-KETTE',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: _isOutInPublic
                            ? Colors.amber.shade900
                            : const Color(0xFF222222),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: _isOutInPublic
                                ? Colors.amberAccent
                                : Colors.white12,
                            width: _isOutInPublic ? 2 : 1,
                          ),
                        ),
                      ),
                      onPressed: () => _setModeDirectly(true),
                      icon: const Text('🌍', style: TextStyle(fontSize: 16)),
                      label: const Text(
                        'UNTERWEGS-KETTE',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const Spacer(),
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.redAccent, width: 2),
                ),
                child: Column(
                  children: [
                    Text(
                      _isOutInPublic
                          ? '🌍 JETZT AUSFÜHREN (UNTERWEGS):'
                          : '🏠 JETZT AUSFÜHREN (ZUHAUSE):',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      currentSkill.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      currentSkill.description,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 19,
                        color: Colors.white70,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),

              SizedBox(
                height: 72,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _nextStep,
                  icon: const Icon(Icons.check_circle_outline, size: 30),
                  label: Text(
                    _currentIndex < total - 1
                        ? 'ERLEDIGT – NÄCHSTER SKILL'
                        : 'LETZTEN SKILL ABSCHLIESSEN',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.trending_down),
                  label: const Text(
                    'Anspannung ist wieder < 50 (Abbrechen)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
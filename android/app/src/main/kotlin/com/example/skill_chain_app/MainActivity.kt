package com.example.skill_chain_app

import android.Manifest
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "skill_chain_app/widget"
    private var pendingEmergencyTrigger = false

    companion object {
        private var activeChannel: MethodChannel? = null

        fun notifyModeChangedFromWidget(isPublic: Boolean) {
            activeChannel?.invokeMethod("onWidgetModeChanged", isPublic)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableShowOnLockscreen()
        requestNotificationPermissionIfNeeded()
        EmergencyWidgetProvider.refreshLockscreenTrigger(this)
        checkEmergencyIntent(intent)
    }

    private fun enableShowOnLockscreen() {
        // Erlaubt das Öffnen der Activity direkt über dem gesperrten Bildschirm (ohne PIN/Fingerabdruck)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    1001
                )
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001) {
            EmergencyWidgetProvider.refreshLockscreenTrigger(this)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        enableShowOnLockscreen()
        if (checkEmergencyIntent(intent)) {
            pendingEmergencyTrigger = false
            activeChannel?.invokeMethod("triggerEmergencyNow", null)
        }
    }

    override fun onDestroy() {
        activeChannel = null
        super.onDestroy()
    }

    private fun checkEmergencyIntent(intent: Intent?): Boolean {
        if (intent?.getBooleanExtra("START_EMERGENCY", false) == true ||
            intent?.action == "ACTION_START_EMERGENCY_CASCADE"
        ) {
            intent.removeExtra("START_EMERGENCY")
            intent.action = null
            pendingEmergencyTrigger = true
            return true
        }
        return false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        activeChannel = channel

        channel.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences(
                EmergencyWidgetProvider.PREFS_NAME,
                Context.MODE_PRIVATE
            )

            when (call.method) {
                "consumeEmergencyLaunch" -> {
                    val shouldTrigger = pendingEmergencyTrigger
                    pendingEmergencyTrigger = false
                    result.success(shouldTrigger)
                }
                "isDeviceLocked" -> {
                    val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    result.success(km.isKeyguardLocked)
                }
                "finishApp" -> {
                    // Schließt die App wieder sauber zurück zum Sperrbildschirm
                    finish()
                    result.success(true)
                }
                "consumeWidgetModeOverride" -> {
                    val isDirty = prefs.getBoolean(
                        EmergencyWidgetProvider.KEY_DIRTY_FROM_WIDGET,
                        false
                    )
                    if (isDirty) {
                        val widgetMode = prefs.getBoolean(
                            EmergencyWidgetProvider.KEY_IS_PUBLIC,
                            false
                        )
                        prefs.edit()
                            .putBoolean(EmergencyWidgetProvider.KEY_DIRTY_FROM_WIDGET, false)
                            .apply()
                        result.success(widgetMode)
                    } else {
                        result.success(null)
                    }
                }
                "syncModeToWidget" -> {
                    val isPublic = call.argument<Boolean>("isPublic") ?: false
                    prefs.edit()
                        .putBoolean(EmergencyWidgetProvider.KEY_IS_PUBLIC, isPublic)
                        .putBoolean(EmergencyWidgetProvider.KEY_DIRTY_FROM_WIDGET, false)
                        .apply()
                    EmergencyWidgetProvider.updateAllWidgets(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
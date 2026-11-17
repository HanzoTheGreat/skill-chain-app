# 🛡️ Skill & Akut-Hilfe (DBT Skill-Chain App)

Eine 100 % lokale, kompromisslos schnelle Open-Source-App zur Akut-Regulation bei Hochanspannung (z. B. im Rahmen einer DBT bei Borderline, Zwangsstörungen oder Essdrang). 

Wenn die Anspannung über 70 % steigt, setzt das rationale Abwägen aus. Statt durch endlose Listen zu scrollen, bietet diese App einen **Notfall-Kaskaden-Runner**, der vorher festgelegte Skillketten Schritt für Schritt im Vollbild abarbeitet – inklusive Direktstart vom Sperrbildschirm ohne PIN-Hürde.

## ✨ Kern-Features

* **100 % Offline & Privat:** Keine Cloud, keine Tracker, kein Account. Alle Skills und Ketten liegen lokal in einer eingebetteten SQLite-Datenbank.
* **Diskrete Anspannungs-Zonen:** Schnelle Filterung nach **0–50 (Niedrig)**, **55–70 (Hoch)** und **> 70 (Hochanspannung / Akut)**.
* **Kontext-Modus (`🏠 Zuhause` vs. `🌍 Unterwegs`):** Skills können als „Nur privat / zuhause möglich“ markiert werden und werden unterwegs automatisch ausgeblendet. Zudem lassen sich getrennte Notfallkaskaden für Zuhause und Unterwegs definieren.
* **Drag & Drop Ketten-Editor:** Eigene Skillkaskaden frei zusammenstellen und per Fingerzeig umsortieren.
* **Homescreen-Widget & Sperrbildschirm-Direktstart:** Startet die passende Notfallkette direkt vom Homescreen oder über das permanente Sperrbildschirm-Banner – im Akutfall komplett ohne PIN-/Fingerabdruck-Abfrage, während der Rest der App geschützt bleibt.

## 🛠️ Tech-Stack & Architektur

* **Frontend:** Flutter (Material 3, Dark-Mode mit Fokus auf maximale Kontraste und große Touch-Targets)
* **Bridge:** `flutter_rust_bridge` (v2)
* **Backend:** Rust + `rusqlite` (`bundled`-Feature – SQLite wird direkt in die Rust-Binary kompiliert)
* **Native Android-Integration:** Kotlin `AppWidgetProvider`, `TileService` (Quick-Settings-Kachel) & Lockscreen-Handling (`showWhenLocked`)

## 🚀 Selbst bauen (Build Instructions)

### Voraussetzungen
* Flutter SDK
* Rust Toolchain (`rustup`) + Android NDK (für Android-Builds)
* `flutter_rust_bridge_codegen` (`cargo install flutter_rust_bridge_codegen`)

### Kompilieren & Starten
```bash
git clone [https://github.com/DEIN_GITHUB_USERNAME/skill_chain_app.git](https://github.com/DEIN_GITHUB_USERNAME/skill_chain_app.git)
cd skill_chain_app

# Abhängigkeiten laden & Rust-Bridge generieren
flutter pub get
flutter_rust_bridge_codegen generate

# Release-Build auf angeschlossenem Android-Gerät starten
flutter run --release

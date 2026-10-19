# TyrannoFi — Build Guide

Standalone Android app. Native `enough_mail` IMAP client, local persistence
via Hive + `flutter_secure_storage` — no server, no WebView, no network
dependency beyond your mail provider and the DNSBL/disposable-domain lookups.

## Prerequisites

- Flutter SDK 3.x
- Java 11+
- Android SDK (auto-downloads on first build)

## Build APK

```bash
# Get dependencies
flutter pub get

# Build APK (debug mode)
flutter build apk --debug

# OR build release APK (optimized)
flutter build apk --release
```

## Output

- **Debug APK:** `build/app/outputs/flutter-apk/app-debug.apk`
- **Release APK:** `build/app/outputs/flutter-apk/app-release.apk`

## Install on Device

```bash
# Via USB / adb
adb install -r build/app/outputs/flutter-apk/app-release.apk

# OR copy to phone and install manually
# File browser → app-release.apk → tap to install
```

## Signed Release Build

Create `android/key.properties` (not checked in):

```properties
storePassword=<your keystore password>
keyPassword=<your key password>
keyAlias=<your key alias>
storeFile=<path to your .jks file>
```

Then build with `flutter build apk --release`.

## Network Requirements

- The app connects **directly to your mail provider's IMAP server** (e.g.
  `imap.gmail.com:993`) — works on any network, no local server required.
- The spam scanner resolves DNS queries against Spamhaus DBL, SURBL and
  abuse.ch, and downloads the disposable-domain list from GitHub (cached
  locally for 24h, falls back to cache when offline).

## Data & Credentials

- Rules, per-provider configs, folder cache and sort progress are stored
  locally in Hive boxes (`android/data/.../app_flutter/`).
- Passwords are stored in the Android Keystore via `flutter_secure_storage`
  — never as plaintext.

## Project Structure

- `lib/main.dart` / `lib/app_state.dart` — app entry and global state
- `lib/services/*.dart` — IMAP, storage, spam logic
- `lib/screens/*.dart` — UI screens
- `lib/models/*.dart` — data models
- `lib/utils/*.dart` — domain parsing, IMAP path encoding, folder merging
- `lib/widgets/*.dart` — shared UI components
- `test/*.dart` — unit tests

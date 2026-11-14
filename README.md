# ssh-client

A Flutter Android SSH client with a globe server picker and liquid-glass morph panels.

Tap a server card on the interactive globe to open a command panel (0.62 screen height, input at the bottom, session output above). Servers are added from floating capsules that morph in place; settings use the same morph panels. Credentials (passwords, PEM private keys, passphrases) are stored in the platform secure storage; server profiles are stored in local preferences. First connect shows the server's SHA-256 host fingerprint for confirmation and pins it afterwards.

## Build

Requires Flutter 3.47 (Dart 3.13), Android SDK with API 35-37, and Java 21.

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

## Status

Work in progress. The current builds are signed with the debug test key; a formal release needs the maintainer's own release keystore. IP geolocation data bundled under `assets/geo/` and `geo/` comes from DB-IP Lite (CC BY 4.0) via lollipopkit/ipgeo-shards; see `geo/README.md`.

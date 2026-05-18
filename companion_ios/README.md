# MusicTracker iPhone Companion

The portable playback / review node for the MACNEO desktop library.
Per the architecture plan, this app is deliberately **small** —
it does NOT own enrichment, identity, manifest compilation, or
reconciliation logic. The desktop is the source of truth; the
phone reports observations.

## Scope

### Owned here
- Local audio playback (`just_audio`)
- Pairing flow + token storage (sqflite for PR2.7, iOS keychain later)
- Sync handshake against the desktop's mobile-sync API
- Local cache of synced tracks + artwork
- Append-only telemetry queue + retry-safe upload
- Phone-side history of every intel_uid ever held (for the
  "Heard this before" prompt)
- Companion UI (Pair / Inventory / Now Playing / Activity / Settings)
- CarPlay scene wiring (deferred to PR2.8+)

### NOT owned here
- Enrichment, identity rules, song-identity grouping
- Manifest compilation (the desktop builds; the phone consumes)
- Telemetry reconciliation — the phone emits; the desktop applies
- Cross-library merge / save / source management
- Variant resolution — the manifest tells the phone what bytes
  to fetch; transport keys off `variant_id`

## Layout

```
companion_ios/
├── pubspec.yaml                  → depends on `../shared_core`
├── lib/
│   ├── main.dart                 → app entry
│   └── src/
│       ├── services/
│       │   ├── desktop_client.dart   → HTTP wrapper for desktop API
│       │   └── token_storage.dart    → persisted pairing credentials
│       └── screens/              (next slice)
└── test/
```

## Status

| Slice | Surface | State |
|---|---|---|
| PR2.7 | Project scaffold + `DesktopClient` + `TokenStorage` | ✅ landed |
| PR2.8.A–C | InventoryService (generations + activation pointer), AudioService (queue + late-bind + Q1 gate), PlaybackEngine abstraction + chaos simulators | ✅ landed |
| PR2.8.D.1 | `JustAudioPlaybackEngine` + iOS `AudioSession.music()` + operational-logging conventions + `DebugSurface` + runtime bootstrap | ✅ landed |
| PR2.8.D.2 | Pair screen + manual IP entry (Slice 1 baseline; Bonjour later) | next |
| PR2.8.D.3 | Sync Home / Confirm Sync / Progress / Complete screens | next |
| PR2.9 | Inventory screen + Now Playing + Activity | next |
| PR2.10 | Settings | later |
| PR2.11 | CarPlay scene | later |

## Bootstrap

The Dart source compiles on its own — `flutter analyze` from
this directory verifies the protocol contract against
`shared_core`. To actually build the iOS app, run:

```
cd companion_ios
flutter create --platforms=ios .
flutter pub get
flutter run -d <iPhone>
```

The `flutter create` step adds the missing iOS platform files
(`ios/`, generated platform bindings, etc.) on top of this
hand-written `lib/` + `pubspec.yaml`. This pattern keeps the
commit history small and readable while leaving the actual
iOS build setup as an explicit, user-triggered step.

### Required iOS Info.plist additions (PR2.8.D.1)

After `flutter create --platforms=ios .` generates `ios/`, open
`ios/Runner/Info.plist` and add:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

Without `UIBackgroundModes: ['audio']` the OS suspends audio
when the screen locks or the app backgrounds — `just_audio` +
`AudioSession.music()` configure the playback category, but the
entitlement is what tells iOS the app intends to keep playing.

CarPlay scene support (PR2.11) will add additional Info.plist
keys (`UISceneDelegateClassName` under `CPTemplateApplication
SceneSession`); the audio entitlement is the prerequisite.

### What runs on first launch (PR2.8.D.1)

`lib/main.dart` boots the three-layer runtime stack:

```
InventoryService.open(<appDocs>/companion_inventory.db)
    │ orphan-sweeps stale staging generations on boot
    ▼
JustAudioPlaybackEngine()
    │ configures AudioSession.music() on first call
    │ pauses on interruption-begin + becomingNoisy
    ▼
AudioService(inventory, engine)
    │ owns queue / late-bound resolution / Q1 sync-block gate
    ▼
DebugSurface (rendered as the home widget)
    │ paired? · active gen · queue · engine · sync state
```

The home screen is intentionally just the `DebugSurface` — a
dense, ugly-on-purpose operational panel for runtime archaeology
while the iOS-specific edges shake out. Subsequent slices layer
the real four-screen UI on top of this stack without replacing
it.

### Operational log conventions

All services emit `debugPrint` lines with tagged prefixes so
runtime archaeology stays grep-able:

| Tag | Source | Examples |
|---|---|---|
| `[boot]` | `main.dart` | db path, orphan sweep, stack-ready |
| `[pair]` | `desktop_client.dart` | request, success |
| `[sync]` | `desktop_client.dart` | session open / complete |
| `[manifest]` | `desktop_client.dart` | manifest received |
| `[telemetry]` | `desktop_client.dart` | batch posted, ack applied |
| `[reconciled]` | `desktop_client.dart` | session completed-success |
| `[generation]` | `inventory_service.dart` | staging / verify / activate |
| `[file]` | `inventory_service.dart` | staged track download |
| `[playback]` | `audio_service.dart` | queue entry / resume / next / pause |
| `[engine]` | `just_audio_playback_engine.dart` | setSource / play / pause / interruption |

## Why `lib/src/`?

Public API surface is `lib/<file>.dart` (only `main.dart` for
now). Implementation lives in `lib/src/` per the standard Dart
convention — keeps the namespace tidy when this package
inevitably grows.

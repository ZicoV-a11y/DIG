/// Pure-Dart shared models + sync-protocol contracts between the
/// desktop app and the future iOS companion. See `pubspec.yaml`
/// description for the ownership boundary.
///
/// Per the user's PR2 guidance:
///   - share semantic DTOs/contracts, NOT SQLite models
///   - share an ecosystem-level event ontology
///   - desktop + iOS keep independent storage layers
library;

export 'src/capacity_policy.dart';
export 'src/device_operational_state.dart';
export 'src/manifest.dart';
export 'src/manifest_diff.dart';
export 'src/residency_class.dart';
export 'src/rotation_summary.dart';
export 'src/semantic_event.dart';
export 'src/sync_session.dart';
export 'src/sync_state.dart';
export 'src/telemetry_event.dart';
export 'src/track_identity.dart';

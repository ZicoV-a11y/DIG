import 'save_snapshot.dart';

/// Category of `.library` file the user can navigate to. Drives
/// the section headers in the Load Operational State dialog and the
/// visual distinction between "live device channel" and "historical
/// lineage" — the ontology must be readable in the UI itself
/// (`feedback_save_trust_cycle.md` / `project_library_knowledge_graph_direction.md`).
enum OperationalStateSource {
  /// `Systems/{THIS_MACHINE}.library` — the live operational source
  /// for this device. Loading it is a no-op (already loaded), but
  /// surfaced for completeness so users understand the file IS
  /// part of the operational state landscape, not magic.
  currentDevice,

  /// `Systems/{OTHER_MACHINE}.library` — operational truth for a
  /// different device whose state has been deposited into this
  /// LibraryRoot. Loadable, but loading replaces this device's
  /// live channel.
  otherDevice,

  /// `Saves/{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library` — a
  /// historical lineage point produced by an autosave. Most
  /// common source — the rolling 20-entry rollback history.
  historicalLineage,

  /// `Shared Libraries/*.library` — future cross-device exchange
  /// layer. Scaffolded but not yet wired for read in V1 of the
  /// Load Operational State dialog. Shown disabled with a
  /// "coming soon" label so users understand the architectural
  /// shape without being able to act on it yet.
  sharedLibrary,
}

/// One row in the operational-state browser. Pure metadata — no DB
/// open happens to construct one. Rich stats (track count, favorite
/// count, etc.) live on [StatePreview] and load lazily when a row
/// is selected, so the dialog opens fast even with many entries.
///
/// Critically NOT named "Save" or "Snapshot" — these are operational
/// identity objects, not backup artifacts. The naming carries the
/// philosophy.
class OperationalState {
  /// Absolute path to the `.library` file on disk.
  final String filePath;

  /// What kind of file this is — drives the section grouping and
  /// the "live device vs historical lineage" visual distinction in
  /// the UI.
  final OperationalStateSource source;

  /// Filename-parsed metadata. Null for `currentDevice` /
  /// `otherDevice` entries whose filenames are just
  /// `{MACHINE}.library` (no timestamp / library / etc. embedded).
  final SaveSnapshot? snapshot;

  /// Machine ID this state represents — for current/other device
  /// entries derived from the filename; for historical lineage
  /// derived from the parsed snapshot.
  final String machineId;

  /// File size in bytes — surfaces in the row for quick visual
  /// comparison ("19.9 MB" feels like the live library; smaller
  /// files might be a fresh install or a corrupt save).
  final int fileSize;

  /// Filesystem modification time. For historical lineage this
  /// is usually equal to the snapshot's captured-at time; for
  /// current/other device files this is the most recent autosave
  /// tick that touched the device channel.
  final DateTime modifiedAt;

  const OperationalState({
    required this.filePath,
    required this.source,
    required this.snapshot,
    required this.machineId,
    required this.fileSize,
    required this.modifiedAt,
  });

  /// The capture time to display to the user. Prefers the
  /// filename-parsed timestamp for historical lineage (more
  /// stable than mtime, which can drift if the file is touched);
  /// falls back to mtime for current/other device entries that
  /// don't have a filename timestamp.
  DateTime get capturedAt => snapshot?.capturedAt ?? modifiedAt;

  /// Display-ready library name. For historical lineage this is
  /// the filename-parsed value (e.g. `NEOMAC_LIBRARY`). For
  /// current/other device files we don't have a library_name in
  /// the filename — return null so the UI can fall back to
  /// "(library name in file)" or similar.
  String? get libraryName => snapshot?.libraryName;
}

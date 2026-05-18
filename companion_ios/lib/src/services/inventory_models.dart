import 'package:shared_core/shared_core.dart';

/// Health state of a single inventory generation.
///
/// Per the architecture: generations are **immutable** once they
/// leave `staging` — every subsequent operation produces a new
/// generation. The status transitions only move forward:
///
///   staging → verifying → ready → active → retired
///   staging → failed (terminal)
///   * → orphaned (interrupted lifecycle, eligible for GC)
///
/// `active` is set by an atomic activation-pointer swap, NOT by
/// mutating the row. The activation_pointer table holds the
/// canonical "which generation is live" value separately from
/// the row's status field — that separation lets us survive
/// crashes between status-update and pointer-swap by re-reading
/// the pointer on next boot.
enum GenerationStatus {
  /// Downloads in progress; cached_tracks rows being appended.
  staging,

  /// Download complete; hash verification running.
  verifying,

  /// Verified + activation-eligible. NOT yet pointed at.
  ready,

  /// Currently pointed at by activation_pointer.
  active,

  /// Was active, now superseded by a newer activation. Files
  /// linger until [garbageCollect] runs.
  retired,

  /// Lifecycle interrupted before reaching `ready` / `active`.
  /// Cleanup-eligible.
  orphaned,

  /// Verification failed (hash mismatch, missing file, etc).
  /// Terminal — no further transitions; eligible for GC.
  failed;

  String get wireName {
    switch (this) {
      case GenerationStatus.staging:
        return 'staging';
      case GenerationStatus.verifying:
        return 'verifying';
      case GenerationStatus.ready:
        return 'ready';
      case GenerationStatus.active:
        return 'active';
      case GenerationStatus.retired:
        return 'retired';
      case GenerationStatus.orphaned:
        return 'orphaned';
      case GenerationStatus.failed:
        return 'failed';
    }
  }

  static GenerationStatus fromWire(String s) {
    switch (s) {
      case 'staging':
        return GenerationStatus.staging;
      case 'verifying':
        return GenerationStatus.verifying;
      case 'ready':
        return GenerationStatus.ready;
      case 'active':
        return GenerationStatus.active;
      case 'retired':
        return GenerationStatus.retired;
      case 'orphaned':
        return GenerationStatus.orphaned;
      case 'failed':
        return GenerationStatus.failed;
      default:
        throw FormatException('Unknown GenerationStatus: $s');
    }
  }
}

/// In-memory projection of an `inventory_generations` row.
/// Immutable — every mutation that the InventoryService allows
/// produces a fresh `Generation`. UI binds to these.
class Generation {
  final String generationId;
  final GenerationStatus status;
  final DateTime createdAt;
  final DateTime statusChangedAt;

  /// Desktop's manifest_version this generation was built from.
  /// Lets the phone correlate its inventory back to the
  /// desktop's `sync_sessions.manifest_version`.
  final int? manifestVersion;

  /// Desktop's session_id this generation was built during.
  /// Null for generations created outside a handshake (manual
  /// rebuild, future bulk-import path).
  final String? sourceSessionId;

  final String? failedReason;

  const Generation({
    required this.generationId,
    required this.status,
    required this.createdAt,
    required this.statusChangedAt,
    this.manifestVersion,
    this.sourceSessionId,
    this.failedReason,
  });
}

/// One row of `cached_tracks` — a single file on disk that's
/// part of [generationId]'s inventory.
///
/// The `transportHash` is the hash the desktop's manifest entry
/// promised. We re-hash on disk and match against it as part of
/// `verifyGeneration` — generation-scoped, never a global cache
/// lookup.
class CachedTrack {
  final String generationId;
  final TrackIdentity identity;
  final String transportHash;
  final String audioPath;
  final int byteSize;
  final DateTime? hashVerifiedAt;

  const CachedTrack({
    required this.generationId,
    required this.identity,
    required this.transportHash,
    required this.audioPath,
    required this.byteSize,
    this.hashVerifiedAt,
  });
}

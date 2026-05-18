import 'track_identity.dart';

/// **Ecosystem-level lifecycle events** — the shared ontology of
/// "things that happen" across the desktop / phone / future
/// playback-node mesh. Independent of which side emits or
/// consumes them.
///
/// Distinct from [TelemetryEvent] (phone→desktop playback wire) in
/// two ways:
///   1. Either side can emit a SemanticEvent (TelemetryEvent is
///      phone-only).
///   2. SemanticEvents include sync / rotation / lifecycle
///      milestones, not just playback state changes.
///
/// Both desktop's operational journal and phone's local activity
/// log render the SAME semantic events — same narration strings,
/// same shape — so a user reading desktop's activity strip and
/// phone's history sees a consistent vocabulary.
///
/// This is the layer the user reminded us to build last: explicit
/// stable semantics replacing inferred heuristics.
enum SemanticEventType {
  /// Threshold-crossed playback event (the canonical "I really
  /// listened to this track" signal). Atomically fires reviewed_at,
  /// play_count++, last_played_at on the receiving side. Emitted
  /// by whichever node performed the playback (desktop or phone).
  playbackThresholdReached,

  /// Track played all the way through. Stronger signal than
  /// thresholdReached; state mutation is the same (already done at
  /// threshold), but narration distinguishes "finished" from "barely
  /// crossed."
  playbackCompleted,

  /// User toggled the favorite star. Carries the new state +
  /// timestamp for LWW reconciliation when two nodes disagree.
  favoriteToggled,

  /// User marked an already-reviewed track back to unreviewed
  /// (right-click "Mark unreviewed"). Clears reviewed_at; track
  /// becomes eligible for phone rotation again.
  reviewedReset,

  /// One side requested a sync handshake. The receiver shows an
  /// approval dialog; on approve the manifest/transfer/telemetry
  /// cycle begins.
  syncRequested,

  /// Sync handshake completed successfully end-to-end. Includes
  /// manifest_version, counts of tracks added/removed, telemetry
  /// events applied.
  syncCompleted,

  /// Sync handshake failed at some stage. Failure stage is in the
  /// payload (`stage` = 'approval_declined' | 'transfer_failed' |
  /// 'network_lost' | etc).
  syncFailed,

  /// Desktop generated a new manifest version for this device.
  /// Records the previous version, new version, count of changed
  /// entries.
  manifestGenerated,

  /// Phone successfully applied a manifest to its local cache.
  /// Fires after the file transfers complete; counts of added /
  /// removed are in the payload.
  manifestApplied,

  /// A `rotating` / `hybrid_fill` track became eligible for
  /// eviction (phone reported threshold-crossed). Doesn't remove
  /// anything yet — that happens in [trackEvicted] on the next
  /// manifest cycle.
  rotationEligible,

  /// A track was removed from a device's inventory (rotated out).
  /// Reason in payload: 'reviewed' | 'unfavorited' | 'unpinned' |
  /// 'desktop_deleted' | 'manual'.
  trackEvicted,

  /// A track was added to a device's inventory. Source in payload:
  /// 'manual' | 'pinned' | 'random' | 'unreviewed_random' |
  /// 'favorite_cache' | 'hybrid_fill'.
  trackProvisioned;

  String get wireName {
    switch (this) {
      case SemanticEventType.playbackThresholdReached:
        return 'playback_threshold_reached';
      case SemanticEventType.playbackCompleted:
        return 'playback_completed';
      case SemanticEventType.favoriteToggled:
        return 'favorite_toggled';
      case SemanticEventType.reviewedReset:
        return 'reviewed_reset';
      case SemanticEventType.syncRequested:
        return 'sync_requested';
      case SemanticEventType.syncCompleted:
        return 'sync_completed';
      case SemanticEventType.syncFailed:
        return 'sync_failed';
      case SemanticEventType.manifestGenerated:
        return 'manifest_generated';
      case SemanticEventType.manifestApplied:
        return 'manifest_applied';
      case SemanticEventType.rotationEligible:
        return 'rotation_eligible';
      case SemanticEventType.trackEvicted:
        return 'track_evicted';
      case SemanticEventType.trackProvisioned:
        return 'track_provisioned';
    }
  }

  static SemanticEventType fromWire(String s) {
    switch (s) {
      case 'playback_threshold_reached':
        return SemanticEventType.playbackThresholdReached;
      case 'playback_completed':
        return SemanticEventType.playbackCompleted;
      case 'favorite_toggled':
        return SemanticEventType.favoriteToggled;
      case 'reviewed_reset':
        return SemanticEventType.reviewedReset;
      case 'sync_requested':
        return SemanticEventType.syncRequested;
      case 'sync_completed':
        return SemanticEventType.syncCompleted;
      case 'sync_failed':
        return SemanticEventType.syncFailed;
      case 'manifest_generated':
        return SemanticEventType.manifestGenerated;
      case 'manifest_applied':
        return SemanticEventType.manifestApplied;
      case 'rotation_eligible':
        return SemanticEventType.rotationEligible;
      case 'track_evicted':
        return SemanticEventType.trackEvicted;
      case 'track_provisioned':
        return SemanticEventType.trackProvisioned;
      default:
        throw FormatException('Unknown SemanticEventType: $s');
    }
  }
}

/// Which node originated this event. Used by narrators to render
/// "Zico iPhone played 3 tracks" vs "Played 3 tracks on desktop."
enum SemanticActor {
  /// Originated on the desktop app.
  desktop,

  /// Originated on a mobile companion. The specific device is in
  /// [SemanticEvent.actorId].
  mobile;

  String get wireName => switch (this) {
        SemanticActor.desktop => 'desktop',
        SemanticActor.mobile => 'mobile',
      };

  static SemanticActor fromWire(String s) => switch (s) {
        'desktop' => SemanticActor.desktop,
        'mobile' => SemanticActor.mobile,
        _ => throw FormatException('Unknown SemanticActor: $s'),
      };
}

/// One ecosystem-level lifecycle event. Stable wire shape across
/// versions: type + actor + timestamp + optional identity +
/// type-specific payload map. Payload schema is documented per
/// [SemanticEventType] in the comments above.
class SemanticEvent {
  final SemanticEventType type;
  final SemanticActor actor;

  /// For [SemanticActor.mobile] this is the device_id. For
  /// [SemanticActor.desktop] this is null (only one desktop in the
  /// current architecture; multi-desktop is deferred per the plan).
  final String? actorId;

  /// Wall-clock ms when the event occurred on the actor's clock.
  /// Treated as authoritative — the desktop reconciler doesn't
  /// rewrite it on receipt.
  final int occurredAt;

  /// The track this event is about. Null for cross-track events
  /// (sync_requested, manifest_applied, etc.).
  final TrackIdentity? identity;

  /// Type-specific structured payload. Kept as a generic map so
  /// per-type schemas can evolve without breaking the envelope.
  final Map<String, Object?> payload;

  const SemanticEvent({
    required this.type,
    required this.actor,
    required this.occurredAt,
    this.actorId,
    this.identity,
    this.payload = const {},
  });

  Map<String, Object?> toJson() => {
        'type': type.wireName,
        'actor': actor.wireName,
        if (actorId != null) 'actor_id': actorId,
        'occurred_at': occurredAt,
        if (identity != null) 'identity': identity!.toJson(),
        if (payload.isNotEmpty) 'payload': payload,
      };

  static SemanticEvent fromJson(Map<String, Object?> j) {
    final type = j['type'];
    final actor = j['actor'];
    final occurredAt = _asInt(j['occurred_at']);
    if (type is! String) {
      throw const FormatException('SemanticEvent.type required');
    }
    if (actor is! String) {
      throw const FormatException('SemanticEvent.actor required');
    }
    if (occurredAt == null) {
      throw const FormatException('SemanticEvent.occurred_at required');
    }
    final id = j['identity'];
    final payload = j['payload'];
    return SemanticEvent(
      type: SemanticEventType.fromWire(type),
      actor: SemanticActor.fromWire(actor),
      actorId: j['actor_id'] as String?,
      occurredAt: occurredAt,
      identity: id is Map<String, Object?> ? TrackIdentity.fromJson(id) : null,
      payload: payload is Map<String, Object?> ? payload : const {},
    );
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

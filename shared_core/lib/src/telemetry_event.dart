import 'track_identity.dart';

/// Discrete playback / state-change events the phone emits and the
/// desktop replays into its intelligence rows.
///
/// **PR2.5 active set** — Slice 1 ships only two:
///   - [thresholdCrossed]   (canonical play/review signal)
///   - [favorited]          (mutable preference state)
///
/// Other values exist for forward-compat — phones from a later
/// slice can already speak them and older desktops drop them with
/// a clear log line (rather than crashing on unknown enum).
enum TelemetryEventType {
  /// Reserved for future analytics. NOT applied by the Slice-1
  /// reconciler.
  playStarted,

  /// Real-playback time crossed `_playThresholdSeconds`. THIS is
  /// the canonical event for desktop reconciliation: it stamps
  /// play_count++, last_played_at = occurred_at, reviewed_at ??=
  /// occurred_at in one atomic update via `repo.updateIntelligence`
  /// — plus a `recordEvent(EventType.tracksPlayed, ...)` for the
  /// activity strip.
  ///
  /// At most one threshold event is emitted per playback SESSION
  /// (per the §2 contract). The phone enforces that — the desktop
  /// reconciler still dedupes via [eventId] so a re-send doesn't
  /// double-count.
  thresholdCrossed,

  /// Reserved for future "watched-to-end" narration. NOT applied
  /// by the Slice-1 reconciler.
  completed,

  /// Reserved for future skip-analytics. NOT applied by the
  /// Slice-1 reconciler.
  skipped,

  /// User toggled the favorite star. Carries the new boolean +
  /// `occurred_at` for LWW reconciliation. Multiple toggles in
  /// quick succession are all sent — only the latest occurred_at
  /// has any visible effect on desktop intelligence, but every
  /// one lands in the audit trail.
  favorited,

  /// Reserved for future phone-side deletion narration. NOT
  /// applied by the Slice-1 reconciler.
  deletedLocally;

  String get wireName {
    switch (this) {
      case TelemetryEventType.playStarted:
        return 'play_started';
      case TelemetryEventType.thresholdCrossed:
        return 'threshold_crossed';
      case TelemetryEventType.completed:
        return 'completed';
      case TelemetryEventType.skipped:
        return 'skipped';
      case TelemetryEventType.favorited:
        return 'favorited';
      case TelemetryEventType.deletedLocally:
        return 'deleted_locally';
    }
  }

  /// The subset the Slice-1 reconciler actually applies. Other
  /// values parse cleanly but the reconciler logs + ignores them.
  bool get isAppliedSlice1 =>
      this == TelemetryEventType.thresholdCrossed ||
      this == TelemetryEventType.favorited;

  static TelemetryEventType fromWire(String s) {
    switch (s) {
      case 'play_started':
        return TelemetryEventType.playStarted;
      case 'threshold_crossed':
        return TelemetryEventType.thresholdCrossed;
      case 'completed':
        return TelemetryEventType.completed;
      case 'skipped':
        return TelemetryEventType.skipped;
      case 'favorited':
        return TelemetryEventType.favorited;
      case 'deleted_locally':
        return TelemetryEventType.deletedLocally;
      default:
        throw FormatException('Unknown TelemetryEventType: $s');
    }
  }
}

/// One phone-emitted event.
///
/// **Idempotency contract**: the [eventId] is a UUID generated on
/// the phone when the event is first persisted to its local
/// `offline_event_queue`. The desktop dedupes by exact event_id —
/// any subsequent upload of the same id (retries, reconnects,
/// double-POSTs from partial network failures) is a no-op.
///
/// **Timestamp authority**: [occurredAt] is the phone's clock at
/// the moment the event happened. The desktop reconciler honors
/// it as authoritative *unless* it's more than a tolerance window
/// (default ~5 minutes) in the future, in which case it's clamped
/// to the receipt time. (Phone clocks can drift / be wrong; LWW
/// favorite reconciliation would otherwise be poisonable by a
/// device with a wildly-wrong clock.)
class TelemetryEvent {
  /// Phone-generated UUID. Required, never null. The desktop's
  /// `processed_mobile_events` table primary-keys on this so
  /// duplicate uploads are no-ops.
  final String eventId;

  final TrackIdentity identity;
  final TelemetryEventType type;

  /// Wall-clock moment the event happened on the phone, in ms
  /// since epoch.
  final int occurredAt;

  /// Optional position in the track at the time of the event, ms.
  final int? positionMs;

  /// Real forward playback time elapsed in the active session,
  /// ms. Drives threshold validation: the reconciler validates
  /// the event corresponds to real playback, not a scrub.
  final int? elapsedPlaybackMs;

  /// For [TelemetryEventType.favorited]: the new favorite state.
  final bool? favoriteValue;

  const TelemetryEvent({
    required this.eventId,
    required this.identity,
    required this.type,
    required this.occurredAt,
    this.positionMs,
    this.elapsedPlaybackMs,
    this.favoriteValue,
  });

  Map<String, Object?> toJson() => {
        'event_id': eventId,
        'identity': identity.toJson(),
        'type': type.wireName,
        'occurred_at': occurredAt,
        if (positionMs != null) 'position_ms': positionMs,
        if (elapsedPlaybackMs != null) 'elapsed_playback_ms': elapsedPlaybackMs,
        if (favoriteValue != null) 'favorite_value': favoriteValue,
      };

  static TelemetryEvent fromJson(Map<String, Object?> j) {
    final eventId = j['event_id'];
    final identity = j['identity'];
    final type = j['type'];
    final occurredAt = _asInt(j['occurred_at']);
    if (eventId is! String || eventId.isEmpty) {
      throw const FormatException('TelemetryEvent.event_id required (UUID)');
    }
    if (identity is! Map<String, Object?>) {
      throw const FormatException('TelemetryEvent.identity required');
    }
    if (type is! String) {
      throw const FormatException('TelemetryEvent.type required');
    }
    if (occurredAt == null) {
      throw const FormatException('TelemetryEvent.occurred_at required');
    }
    return TelemetryEvent(
      eventId: eventId,
      identity: TrackIdentity.fromJson(identity),
      type: TelemetryEventType.fromWire(type),
      occurredAt: occurredAt,
      positionMs: _asInt(j['position_ms']),
      elapsedPlaybackMs: _asInt(j['elapsed_playback_ms']),
      favoriteValue: j['favorite_value'] as bool?,
    );
  }
}

/// Wire envelope for `POST /api/v1/telemetry`. Carries the batch
/// of phone-emitted events. No "last acked event id" — UUIDs make
/// that envelope-level cursor obsolete: dedup is per-event-id, so
/// the phone just sends whatever it has and trusts the desktop's
/// response to tell it what landed.
///
/// [syncSessionId] is the session_id from the handshake this
/// batch belongs to. Optional because the phone can fire
/// catch-up telemetry between sessions (e.g., on app launch
/// before initiating a new handshake) — the reconciler attaches
/// session-less batches to a synthetic per-device "ambient"
/// session.
class TelemetryBatch {
  final String deviceId;
  final String? syncSessionId;
  final List<TelemetryEvent> events;

  const TelemetryBatch({
    required this.deviceId,
    required this.events,
    this.syncSessionId,
  });

  Map<String, Object?> toJson() => {
        'device_id': deviceId,
        if (syncSessionId != null) 'sync_session_id': syncSessionId,
        'events': [for (final e in events) e.toJson()],
      };

  static TelemetryBatch fromJson(Map<String, Object?> j) {
    final deviceId = j['device_id'];
    final events = j['events'];
    if (deviceId is! String) {
      throw const FormatException('TelemetryBatch.device_id required');
    }
    if (events is! List) {
      throw const FormatException('TelemetryBatch.events required (list)');
    }
    return TelemetryBatch(
      deviceId: deviceId,
      syncSessionId: j['sync_session_id'] as String?,
      events: [
        for (final e in events)
          TelemetryEvent.fromJson(e as Map<String, Object?>),
      ],
    );
  }
}

/// Wire response to `POST /api/v1/telemetry`. Tells the phone
/// exactly which event_ids the desktop accepted (whether newly
/// applied or already-processed dedup hits) so the phone can mark
/// them `acknowledged` in its local queue.
///
/// Critically: events the desktop FAILED to apply are NOT in
/// [acceptedEventIds]. The phone retains them in `pending` and
/// retries on the next sync. This is the replay-safe alternative
/// to batch rollback.
class TelemetryAck {
  /// event_ids the desktop has fully reconciled (whether this
  /// upload or a prior one — idempotency means "I've seen this
  /// before" is also a successful outcome).
  final List<String> acceptedEventIds;

  /// Counts for narration / debugging.
  final int eventsApplied;
  final int eventsDeduped;
  final int eventsSkipped;
  final int eventsClockClamped;

  const TelemetryAck({
    required this.acceptedEventIds,
    required this.eventsApplied,
    required this.eventsDeduped,
    required this.eventsSkipped,
    required this.eventsClockClamped,
  });

  Map<String, Object?> toJson() => {
        'accepted_event_ids': acceptedEventIds,
        'events_applied': eventsApplied,
        'events_deduped': eventsDeduped,
        'events_skipped': eventsSkipped,
        'events_clock_clamped': eventsClockClamped,
      };

  static TelemetryAck fromJson(Map<String, Object?> j) {
    final ids = j['accepted_event_ids'];
    return TelemetryAck(
      acceptedEventIds: ids is List
          ? [for (final v in ids) v as String]
          : const [],
      eventsApplied: _asInt(j['events_applied']) ?? 0,
      eventsDeduped: _asInt(j['events_deduped']) ?? 0,
      eventsSkipped: _asInt(j['events_skipped']) ?? 0,
      eventsClockClamped: _asInt(j['events_clock_clamped']) ?? 0,
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

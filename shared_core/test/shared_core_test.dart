// Wire-shape contract tests for the shared_core models.
//
// These are the boundary the desktop app and the future iOS
// companion both bind to. A breakage here means the two apps will
// silently disagree on what arrived over the wire — so the tests
// pin:
//   1. JSON keys (snake_case) match the documented protocol.
//   2. Round-trip fidelity: encode → decode → encode is stable.
//   3. Unknown enum wire values throw FormatException — we want
//      loud failures, not silent fallbacks, when one side is
//      ahead of the other.
//   4. Optional fields are absent (not null) when unset, so the
//      JSON stays small over slow Wi-Fi.

import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

void main() {
  group('TrackIdentity', () {
    test('JSON round-trip preserves all three identifiers', () {
      const id = TrackIdentity(
        intelUid: 'intel-1',
        variantId: 'variant-1',
        contentHash: 'aabbccdd',
      );
      final json = id.toJson();
      expect(json, {
        'intel_uid': 'intel-1',
        'variant_id': 'variant-1',
        'content_hash': 'aabbccdd',
      });
      expect(TrackIdentity.fromJson(json), equals(id));
    });

    test('fromJson rejects empty intel_uid', () {
      expect(
        () => TrackIdentity.fromJson({
          'intel_uid': '',
          'variant_id': 'v',
          'content_hash': 'h',
        }),
        throwsFormatException,
      );
    });

    test('fromJson rejects missing variant_id', () {
      expect(
        () => TrackIdentity.fromJson({
          'intel_uid': 'i',
          'content_hash': 'h',
        }),
        throwsFormatException,
      );
    });

    test('equality is structural', () {
      const a = TrackIdentity(
        intelUid: 'x',
        variantId: 'y',
        contentHash: 'z',
      );
      const b = TrackIdentity(
        intelUid: 'x',
        variantId: 'y',
        contentHash: 'z',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('ResidencyClass', () {
    test('wireName uses snake_case', () {
      expect(ResidencyClass.pinned.wireName, 'pinned');
      expect(ResidencyClass.favoriteCache.wireName, 'favorite_cache');
      expect(ResidencyClass.hybridFill.wireName, 'hybrid_fill');
    });

    test('fromWire round-trips all values', () {
      for (final r in ResidencyClass.values) {
        expect(ResidencyClass.fromWire(r.wireName), r);
      }
    });

    test('fromWire throws on unknown', () {
      // Loud failure is the contract — we don't want a typo in a
      // future iOS build to silently fall back to "rotating."
      expect(
        () => ResidencyClass.fromWire('nope'),
        throwsFormatException,
      );
    });
  });

  group('CapacityPolicy', () {
    test('songs convenience constructor', () {
      const p = CapacityPolicy.songs(100);
      expect(p.mode, CapacityMode.songCount);
      expect(p.value, 100);
    });

    test('bytes convenience constructor', () {
      const p = CapacityPolicy.bytes(5 * 1024 * 1024 * 1024);
      expect(p.mode, CapacityMode.storageBudget);
      expect(p.value, 5368709120);
    });

    test('JSON round-trip', () {
      const p = CapacityPolicy.bytes(1024);
      expect(p.toJson(), {'mode': 'storage_budget', 'value': 1024});
      expect(CapacityPolicy.fromJson(p.toJson()), equals(p));
    });

    test('fromJson rejects missing fields', () {
      expect(
        () => CapacityPolicy.fromJson({'mode': 'song_count'}),
        throwsFormatException,
      );
    });
  });

  group('SyncManifest + ManifestEntry', () {
    test('full round-trip with multiple entries', () {
      const identity1 = TrackIdentity(
        intelUid: 'i1',
        variantId: 'v1',
        contentHash: 'h1',
      );
      const identity2 = TrackIdentity(
        intelUid: 'i2',
        variantId: 'v2',
        contentHash: 'h2',
      );
      const manifest = SyncManifest(
        manifestVersion: 42,
        deviceId: 'device-zico',
        generatedAt: 1747520000,
        capacity: CapacityPolicy.songs(100),
        entries: [
          ManifestEntry(
            identity: identity1,
            title: 'Track One',
            artist: 'Artist',
            durationMs: 240000,
            transportFormat: 'mp3',
            byteSize: 5_000_000,
            transportHash: 'hash1',
            residency: ResidencyClass.manual,
            priorityRank: 1,
            favorite: false,
          ),
          ManifestEntry(
            identity: identity2,
            title: 'Track Two',
            artist: 'Artist',
            durationMs: 300000,
            transportFormat: 'aac_256',
            byteSize: 4_500_000,
            transportHash: 'hash2',
            residency: ResidencyClass.pinned,
            priorityRank: 2,
            favorite: true,
            reviewedAt: 1747400000,
          ),
        ],
      );

      final decoded = SyncManifest.fromJson(manifest.toJson());
      expect(decoded.manifestVersion, 42);
      expect(decoded.deviceId, 'device-zico');
      expect(decoded.capacity, equals(const CapacityPolicy.songs(100)));
      expect(decoded.entries, hasLength(2));
      expect(decoded.entries[0].residency, ResidencyClass.manual);
      expect(decoded.entries[1].favorite, isTrue);
      expect(decoded.entries[1].reviewedAt, 1747400000);
    });

    test('omits null reviewedAt from JSON', () {
      const e = ManifestEntry(
        identity: TrackIdentity(
          intelUid: 'i',
          variantId: 'v',
          contentHash: 'h',
        ),
        title: 't',
        artist: 'a',
        durationMs: 1,
        transportFormat: 'mp3',
        byteSize: 1,
        transportHash: 'h',
        residency: ResidencyClass.rotating,
        priorityRank: 0,
        favorite: false,
      );
      expect(e.toJson().containsKey('reviewed_at'), isFalse);
    });

    test('fromJson rejects missing capacity', () {
      expect(
        () => SyncManifest.fromJson({
          'manifest_version': 1,
          'device_id': 'd',
          'generated_at': 0,
          'entries': const [],
        }),
        throwsFormatException,
      );
    });

    test('fromJson rejects missing transport_hash on entries', () {
      // Integrity metadata is required from day one — phone uses
      // it to validate received bytes. A malformed/old manifest
      // entry without transport_hash must fail loudly so we don't
      // silently ship un-verifiable bytes.
      expect(
        () => ManifestEntry.fromJson({
          'identity': const TrackIdentity(
            intelUid: 'i',
            variantId: 'v',
            contentHash: 'h',
          ).toJson(),
          'title': 't',
          'artist': 'a',
          'duration_ms': 1,
          'transport_format': 'mp3',
          'byte_size': 1,
          'residency': 'rotating',
          'priority_rank': 0,
          'favorite': false,
        }),
        throwsFormatException,
      );
    });
  });

  group('TelemetryEvent + TelemetryBatch', () {
    const id = TrackIdentity(
      intelUid: 'i1',
      variantId: 'v1',
      contentHash: 'h1',
    );

    test('thresholdCrossed round-trips elapsed_playback_ms', () {
      const event = TelemetryEvent(
        eventId: 'evt-7',
        identity: id,
        type: TelemetryEventType.thresholdCrossed,
        occurredAt: 1747520000,
        elapsedPlaybackMs: 10500,
      );
      final json = event.toJson();
      expect(json['type'], 'threshold_crossed');
      expect(json['elapsed_playback_ms'], 10500);
      final decoded = TelemetryEvent.fromJson(json);
      expect(decoded.type, TelemetryEventType.thresholdCrossed);
      expect(decoded.elapsedPlaybackMs, 10500);
    });

    test('favorited carries favorite_value', () {
      const event = TelemetryEvent(
        eventId: 'evt-8',
        identity: id,
        type: TelemetryEventType.favorited,
        occurredAt: 1747520100,
        favoriteValue: true,
      );
      final decoded = TelemetryEvent.fromJson(event.toJson());
      expect(decoded.favoriteValue, isTrue);
    });

    test('event_id is required and rejects non-string', () {
      expect(
        () => TelemetryEvent.fromJson({
          'event_id': 42,
          'identity': id.toJson(),
          'type': 'threshold_crossed',
          'occurred_at': 0,
        }),
        throwsFormatException,
      );
    });

    test('event_id is required and rejects empty string', () {
      expect(
        () => TelemetryEvent.fromJson({
          'event_id': '',
          'identity': id.toJson(),
          'type': 'threshold_crossed',
          'occurred_at': 0,
        }),
        throwsFormatException,
      );
    });

    test('Slice 1 active event set is exactly threshold + favorite', () {
      expect(TelemetryEventType.thresholdCrossed.isAppliedSlice1, isTrue);
      expect(TelemetryEventType.favorited.isAppliedSlice1, isTrue);
      // The four reserved-for-future types parse cleanly (forward
      // compat) but are explicitly NOT in the applied set.
      expect(TelemetryEventType.playStarted.isAppliedSlice1, isFalse);
      expect(TelemetryEventType.completed.isAppliedSlice1, isFalse);
      expect(TelemetryEventType.skipped.isAppliedSlice1, isFalse);
      expect(TelemetryEventType.deletedLocally.isAppliedSlice1, isFalse);
    });

    test('TelemetryBatch round-trips events list', () {
      const batch = TelemetryBatch(
        deviceId: 'device-zico',
        events: [
          TelemetryEvent(
            eventId: 'evt-a',
            identity: id,
            type: TelemetryEventType.thresholdCrossed,
            occurredAt: 1,
          ),
          TelemetryEvent(
            eventId: 'evt-b',
            identity: id,
            type: TelemetryEventType.favorited,
            occurredAt: 2,
            favoriteValue: true,
          ),
        ],
      );
      final decoded = TelemetryBatch.fromJson(batch.toJson());
      expect(decoded.deviceId, 'device-zico');
      expect(decoded.events, hasLength(2));
      expect(decoded.events[0].eventId, 'evt-a');
      expect(decoded.events[1].favoriteValue, isTrue);
    });

    test('TelemetryAck round-trips accepted_event_ids + counters', () {
      const ack = TelemetryAck(
        acceptedEventIds: ['evt-a', 'evt-b'],
        eventsApplied: 1,
        eventsDeduped: 1,
        eventsSkipped: 0,
        eventsClockClamped: 0,
      );
      final decoded = TelemetryAck.fromJson(ack.toJson());
      expect(decoded.acceptedEventIds, ['evt-a', 'evt-b']);
      expect(decoded.eventsApplied, 1);
      expect(decoded.eventsDeduped, 1);
    });
  });

  group('SemanticEvent', () {
    const id = TrackIdentity(
      intelUid: 'i1',
      variantId: 'v1',
      contentHash: 'h1',
    );

    test('playbackThresholdReached carries identity + actor', () {
      const event = SemanticEvent(
        type: SemanticEventType.playbackThresholdReached,
        actor: SemanticActor.mobile,
        actorId: 'device-zico',
        occurredAt: 1747520000,
        identity: id,
        payload: {'elapsed_ms': 10500},
      );
      final decoded = SemanticEvent.fromJson(event.toJson());
      expect(decoded.type, SemanticEventType.playbackThresholdReached);
      expect(decoded.actor, SemanticActor.mobile);
      expect(decoded.actorId, 'device-zico');
      expect(decoded.identity, equals(id));
      expect(decoded.payload['elapsed_ms'], 10500);
    });

    test('syncRequested omits identity', () {
      const event = SemanticEvent(
        type: SemanticEventType.syncRequested,
        actor: SemanticActor.mobile,
        actorId: 'device-zico',
        occurredAt: 1747520000,
      );
      final json = event.toJson();
      expect(json.containsKey('identity'), isFalse);
      expect(json.containsKey('payload'), isFalse);
      final decoded = SemanticEvent.fromJson(json);
      expect(decoded.identity, isNull);
    });

    test('desktop actor omits actor_id', () {
      const event = SemanticEvent(
        type: SemanticEventType.manifestGenerated,
        actor: SemanticActor.desktop,
        occurredAt: 1747520000,
        payload: {'manifest_version': 42},
      );
      final json = event.toJson();
      expect(json.containsKey('actor_id'), isFalse);
      expect(SemanticEvent.fromJson(json).actorId, isNull);
    });

    test('all SemanticEventType wire names are stable', () {
      // Pin every wire name. Any rename here is a wire-protocol
      // break that needs a deliberate migration.
      const expected = {
        SemanticEventType.playbackThresholdReached:
            'playback_threshold_reached',
        SemanticEventType.playbackCompleted: 'playback_completed',
        SemanticEventType.favoriteToggled: 'favorite_toggled',
        SemanticEventType.reviewedReset: 'reviewed_reset',
        SemanticEventType.syncRequested: 'sync_requested',
        SemanticEventType.syncCompleted: 'sync_completed',
        SemanticEventType.syncFailed: 'sync_failed',
        SemanticEventType.manifestGenerated: 'manifest_generated',
        SemanticEventType.manifestApplied: 'manifest_applied',
        SemanticEventType.rotationEligible: 'rotation_eligible',
        SemanticEventType.trackEvicted: 'track_evicted',
        SemanticEventType.trackProvisioned: 'track_provisioned',
      };
      for (final t in SemanticEventType.values) {
        expect(t.wireName, expected[t],
            reason: 'wire name drift for $t');
        expect(SemanticEventType.fromWire(t.wireName), t);
      }
    });

    test('fromJson throws on unknown type', () {
      expect(
        () => SemanticEvent.fromJson({
          'type': 'whatever_new_thing',
          'actor': 'desktop',
          'occurred_at': 0,
        }),
        throwsFormatException,
      );
    });
  });

  group('DeviceOperationalState', () {
    test('all states round-trip via wireName', () {
      for (final s in DeviceOperationalState.values) {
        expect(DeviceOperationalState.fromWire(s.wireName), s);
      }
    });

    test('fromWire throws on unknown', () {
      expect(() => DeviceOperationalState.fromWire('nope'),
          throwsFormatException);
    });
  });

  group('deriveDeviceState', () {
    // Pure function — given the inputs, what does the sidebar
    // Devices panel render? Every transition is testable without
    // a DB.
    const nowMs = 1747520000000;

    test('never seen → offline', () {
      expect(
        deriveDeviceState(
          lastSeenAt: null,
          now: nowMs,
          activeSessionState: null,
        ),
        DeviceOperationalState.offline,
      );
    });

    test('heartbeat within threshold → online', () {
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs - 10_000, // 10s ago
          now: nowMs,
          activeSessionState: null,
        ),
        DeviceOperationalState.online,
      );
    });

    test('heartbeat past stale-threshold but within offline → stale', () {
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs - 60_000, // 1m ago
          now: nowMs,
          activeSessionState: null,
        ),
        DeviceOperationalState.stale,
      );
    });

    test('heartbeat past offline-threshold → offline', () {
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs - (10 * 60 * 1000), // 10m ago
          now: nowMs,
          activeSessionState: null,
        ),
        DeviceOperationalState.offline,
      );
    });

    test('active session wins over stale heartbeat', () {
      // Heartbeat is offline-stale, but an active syncing session
      // is proof the device is right here. UI should show syncing.
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs - (10 * 60 * 1000),
          now: nowMs,
          activeSessionState: ActiveSyncSessionState.syncing,
        ),
        DeviceOperationalState.syncing,
      );
    });

    test('active session awaiting approval → awaitingApproval', () {
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs,
          now: nowMs,
          activeSessionState: ActiveSyncSessionState.awaitingApproval,
        ),
        DeviceOperationalState.awaitingApproval,
      );
    });

    test('active availableForSync session → availableForSync', () {
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs,
          now: nowMs,
          activeSessionState: ActiveSyncSessionState.availableForSync,
        ),
        DeviceOperationalState.availableForSync,
      );
    });

    test('custom thresholds honored', () {
      // Default stale is 30s; bump to 5s for this test.
      expect(
        deriveDeviceState(
          lastSeenAt: nowMs - 10_000, // 10s ago
          now: nowMs,
          activeSessionState: null,
          heartbeatStaleAfter: const Duration(seconds: 5),
        ),
        DeviceOperationalState.stale,
      );
    });
  });

  group('SyncSession', () {
    test('JSON round-trip with full counters', () {
      const session = SyncSession(
        sessionId: 'sess-1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: 1747520000,
        currentState: SyncState.transferring,
        manifestVersion: 42,
        tracksAdded: 50,
        tracksRemoved: 48,
        bytesTransferred: 4_970_000_000,
        telemetryApplied: 84,
        telemetryDeduped: 3,
        telemetryClockClamped: 1,
      );
      final decoded = SyncSession.fromJson(session.toJson());
      expect(decoded.sessionId, 'sess-1');
      expect(decoded.initiatedBy, SyncInitiator.phone);
      expect(decoded.currentState, SyncState.transferring);
      expect(decoded.tracksAdded, 50);
      expect(decoded.telemetryClockClamped, 1);
      expect(decoded.isActive, isTrue);
      expect(decoded.isSuccessful, isFalse);
    });

    test('isSuccessful only true on completed + rotationComplete', () {
      const inFlight = SyncSession(
        sessionId: 's',
        deviceId: 'd',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.rotationComplete,
      );
      expect(inFlight.isSuccessful, isFalse,
          reason: 'active session is never "successful"');

      const successful = SyncSession(
        sessionId: 's',
        deviceId: 'd',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.rotationComplete,
        completedAt: 100,
      );
      expect(successful.isSuccessful, isTrue);

      const failed = SyncSession(
        sessionId: 's',
        deviceId: 'd',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.approvalDeclined,
        completedAt: 100,
        failureState: 'approval_declined',
      );
      expect(failed.isSuccessful, isFalse);
      expect(failed.isActive, isFalse);
    });

    test('isSyncBlockingPlayback gates playback engines', () {
      // Q1 contract: sync is a playback-exclusive maintenance
      // window. Pure helper, both desktop and phone bind to it
      // (desktop pauses engine + refuses play(); companion app
      // does the same on its just_audio engine).

      // No active session → playback fine.
      expect(isSyncBlockingPlayback(null), isFalse);

      // Active non-terminal session → blocked.
      const inFlight = SyncSession(
        sessionId: 's',
        deviceId: 'd',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.transferring,
      );
      expect(isSyncBlockingPlayback(inFlight), isTrue);

      // Terminal but snapshot still around (RotationSummary
      // modal showing) → NOT blocked. Lets playback resume
      // while the summary is visible.
      const finished = SyncSession(
        sessionId: 's',
        deviceId: 'd',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.rotationComplete,
        completedAt: 100,
      );
      expect(isSyncBlockingPlayback(finished), isFalse);

      const failed = SyncSession(
        sessionId: 's',
        deviceId: 'd',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.transferFailed,
        completedAt: 100,
        failureState: 'transfer_failed',
      );
      expect(isSyncBlockingPlayback(failed), isFalse);
    });

    test('TelemetryBatch round-trips optional syncSessionId', () {
      const batch = TelemetryBatch(
        deviceId: 'iphone-zico',
        syncSessionId: 'sess-42',
        events: [],
      );
      final decoded = TelemetryBatch.fromJson(batch.toJson());
      expect(decoded.syncSessionId, 'sess-42');

      // Session-less batches are explicitly supported (ambient
      // catch-up telemetry between handshakes).
      const sessionless = TelemetryBatch(
        deviceId: 'iphone-zico',
        events: [],
      );
      expect(sessionless.toJson().containsKey('sync_session_id'),
          isFalse);
      expect(TelemetryBatch.fromJson(sessionless.toJson()).syncSessionId,
          isNull);
    });
  });

  group('SyncState', () {
    test('all states round-trip via wireName', () {
      for (final s in SyncState.values) {
        expect(syncStateFromWire(s.wireName), s);
      }
    });

    test('fromWire throws on unknown', () {
      expect(() => syncStateFromWire('nope'), throwsFormatException);
    });

    test('receivingTelemetry is distinct from applyingTelemetry', () {
      // Mockup splits the macOS progress window's "Receiving
      // playback history" (network step) from "Applying to library"
      // (DB reconciliation step). Pin both as separate states.
      expect(SyncState.receivingTelemetry, isNot(SyncState.applyingTelemetry));
      expect(SyncState.receivingTelemetry.wireName, 'receiving_telemetry');
      expect(syncStateFromWire('receiving_telemetry'),
          SyncState.receivingTelemetry);
    });

    test('finalizingRotation is a distinct pre-terminal state', () {
      expect(SyncState.finalizingRotation.wireName, 'finalizing_rotation');
      expect(syncStateFromWire('finalizing_rotation'),
          SyncState.finalizingRotation);
    });
  });

  group('isCancellableSyncState', () {
    test('pre-reconciliation phases are cancellable', () {
      // Cancellation philosophy: only safe when partial work is
      // recoverable. Pre-transfer phases drop in-memory work
      // cleanly; transferring + receivingTelemetry recover via
      // HTTP Range / event-id dedup.
      const cancellable = [
        SyncState.negotiating,
        SyncState.approving,
        SyncState.preparingManifest,
        SyncState.preparingTransports,
        SyncState.transferring,
        SyncState.receivingTelemetry,
      ];
      for (final s in cancellable) {
        expect(isCancellableSyncState(s), isTrue,
            reason: '${s.wireName} should be cancellable');
      }
    });

    test('post-reconciliation phases are NOT cancellable', () {
      // applyingTelemetry + finalizingRotation mutate desktop
      // intelligence rows — cancelling mid-reconciliation leaves
      // inconsistent state. Per-event idempotency makes
      // letting them finish near-free anyway.
      expect(isCancellableSyncState(SyncState.applyingTelemetry), isFalse);
      expect(isCancellableSyncState(SyncState.finalizingRotation), isFalse);
    });

    test('terminal + idle are NOT cancellable', () {
      // Nothing to cancel.
      expect(isCancellableSyncState(SyncState.idle), isFalse);
      expect(isCancellableSyncState(SyncState.rotationComplete), isFalse);
      expect(isCancellableSyncState(SyncState.approvalDeclined), isFalse);
      expect(isCancellableSyncState(SyncState.transferFailed), isFalse);
      expect(isCancellableSyncState(SyncState.networkLost), isFalse);
    });
  });

  group('isTerminalSyncState', () {
    test('rotationComplete + all failure states are terminal', () {
      expect(isTerminalSyncState(SyncState.rotationComplete), isTrue);
      expect(isTerminalSyncState(SyncState.approvalDeclined), isTrue);
      expect(isTerminalSyncState(SyncState.transferFailed), isTrue);
      expect(isTerminalSyncState(SyncState.networkLost), isTrue);
    });

    test('lifecycle states are non-terminal', () {
      const lifecycle = [
        SyncState.idle,
        SyncState.negotiating,
        SyncState.approving,
        SyncState.preparingManifest,
        SyncState.preparingTransports,
        SyncState.transferring,
        SyncState.receivingTelemetry,
        SyncState.applyingTelemetry,
        SyncState.finalizingRotation,
      ];
      for (final s in lifecycle) {
        expect(isTerminalSyncState(s), isFalse,
            reason: '${s.wireName} should NOT be terminal');
      }
    });
  });

  group('isLegalSyncStateTransition', () {
    test('happy-path spine: idle → completed walks legally', () {
      // The success path the orchestrator walks every clean sync.
      const path = [
        SyncState.idle,
        SyncState.negotiating,
        SyncState.approving,
        SyncState.preparingManifest,
        SyncState.transferring,
        SyncState.receivingTelemetry,
        SyncState.applyingTelemetry,
        SyncState.finalizingRotation,
        SyncState.rotationComplete,
      ];
      for (var i = 0; i < path.length - 1; i++) {
        expect(
          isLegalSyncStateTransition(path[i], path[i + 1]),
          isTrue,
          reason:
              'Spine step ${path[i].wireName} → ${path[i + 1].wireName}',
        );
      }
    });

    test('self-loops are illegal', () {
      // Every transition is an observed event, never a no-op.
      for (final s in SyncState.values) {
        expect(isLegalSyncStateTransition(s, s), isFalse,
            reason: 'self-loop on ${s.wireName}');
      }
    });

    test('terminal states have no outbound edges', () {
      // approvalDeclined cannot become syncing; rotationComplete
      // cannot become anything. The orchestrator's terminal
      // states are dead-ends by design.
      for (final terminal in [
        SyncState.rotationComplete,
        SyncState.approvalDeclined,
        SyncState.transferFailed,
        SyncState.networkLost,
      ]) {
        for (final target in SyncState.values) {
          expect(
            isLegalSyncStateTransition(terminal, target),
            isFalse,
            reason: '${terminal.wireName} → ${target.wireName}',
          );
        }
      }
    });

    test('arbitrary jumps are rejected', () {
      // The state machine forbids skipping phases — e.g.,
      // negotiating cannot leap to transferring without going
      // through approving + preparingManifest.
      expect(
        isLegalSyncStateTransition(
            SyncState.negotiating, SyncState.transferring),
        isFalse,
      );
      expect(
        isLegalSyncStateTransition(SyncState.idle, SyncState.rotationComplete),
        isFalse,
      );
      expect(
        isLegalSyncStateTransition(
            SyncState.transferring, SyncState.applyingTelemetry),
        isFalse,
        reason: 'must pass through receivingTelemetry first',
      );
    });

    test('failure edges exist where realistic', () {
      // Each phase that touches the network can land in
      // networkLost. Each phase that touches the desktop's
      // database can land in transferFailed.
      expect(
        isLegalSyncStateTransition(
            SyncState.approving, SyncState.approvalDeclined),
        isTrue,
      );
      expect(
        isLegalSyncStateTransition(
            SyncState.transferring, SyncState.transferFailed),
        isTrue,
      );
      expect(
        isLegalSyncStateTransition(
            SyncState.receivingTelemetry, SyncState.networkLost),
        isTrue,
      );
      // But "approving" cannot land in "transferFailed" — by
      // construction it never touched the transport yet.
      expect(
        isLegalSyncStateTransition(
            SyncState.approving, SyncState.transferFailed),
        isFalse,
      );
    });
  });

  group('SyncFailureCode', () {
    test('all codes round-trip via wireName', () {
      for (final c in SyncFailureCode.values) {
        expect(SyncFailureCode.fromWire(c.wireName), c);
      }
    });

    test('fromWire throws on unknown', () {
      expect(() => SyncFailureCode.fromWire('what'),
          throwsFormatException);
    });

    test('granular taxonomy is distinct from lifecycle terminals', () {
      // SyncFailureCode is for audit narration. SyncState is for
      // the lifecycle machine. They're parallel vocabularies —
      // multiple codes can land in the same SyncState terminal.
      expect(SyncFailureCode.values, hasLength(6));
      expect(
        SyncFailureCode.values.map((c) => c.wireName).toSet(),
        equals({
          'transfer_failed',
          'telemetry_failed',
          'manifest_invalid',
          'authorization_failed',
          'device_unreachable',
          'inventory_conflict',
        }),
      );
    });
  });

  group('SyncSession.copyWith', () {
    test('returns a new instance with applied overrides', () {
      const original = SyncSession(
        sessionId: 'sess-1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: 1000,
        currentState: SyncState.negotiating,
      );
      final next = original.copyWith(
        currentState: SyncState.preparingManifest,
        tracksAdded: 5,
      );
      expect(identical(next, original), isFalse);
      expect(next.sessionId, 'sess-1'); // immutable fields preserved
      expect(next.currentState, SyncState.preparingManifest);
      expect(next.tracksAdded, 5);
      expect(next.tracksRemoved, 0,
          reason: 'unchanged counters stay at original value');
    });

    test('omitting all overrides yields an equivalent snapshot', () {
      const original = SyncSession(
        sessionId: 'sess-1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: 1000,
        currentState: SyncState.transferring,
        tracksAdded: 10,
      );
      final next = original.copyWith();
      expect(next.currentState, SyncState.transferring);
      expect(next.tracksAdded, 10);
      // Different instance but equal values — copyWith is the
      // immutable-update primitive the orchestrator builds on.
      expect(identical(next, original), isFalse);
    });
  });

  group('ManifestDiff', () {
    const id1 = TrackIdentity(
      intelUid: 'i1',
      variantId: 'v1',
      contentHash: 'h1',
    );
    const id2 = TrackIdentity(
      intelUid: 'i2',
      variantId: 'v2',
      contentHash: 'h2',
    );

    test('net counts + bytes derive correctly', () {
      const diff = ManifestDiff(
        needAdd: [id1, id2],
        needRemove: [id1],
        needAddBytes: 10_000_000,
        needRemoveBytes: 3_000_000,
        currentInventoryBytes: 100_000_000,
        currentTrackCount: 50,
      );
      expect(diff.netCountChange, 1);
      expect(diff.netBytesChange, 7_000_000);
      expect(diff.afterSyncTrackCount, 51);
      expect(diff.afterSyncBytes, 107_000_000);
      expect(diff.isNoOp, isFalse);
    });

    test('empty diff is no-op', () {
      const diff = ManifestDiff(
        needAdd: [],
        needRemove: [],
        needAddBytes: 0,
        needRemoveBytes: 0,
        currentInventoryBytes: 0,
        currentTrackCount: 0,
      );
      expect(diff.isNoOp, isTrue);
    });

    test('JSON round-trip', () {
      const diff = ManifestDiff(
        needAdd: [id1],
        needRemove: [id2],
        needAddBytes: 5_000_000,
        needRemoveBytes: 4_000_000,
        currentInventoryBytes: 50_000_000,
        currentTrackCount: 10,
      );
      final decoded = ManifestDiff.fromJson(diff.toJson());
      expect(decoded.needAdd.first, equals(id1));
      expect(decoded.needRemove.first, equals(id2));
      expect(decoded.netBytesChange, 1_000_000);
    });

    test('fromJson rejects missing arrays', () {
      expect(
        () => ManifestDiff.fromJson({'need_add': []}),
        throwsFormatException,
      );
    });
  });

  group('RotationSummary', () {
    test('addedBytes / removedBytes aggregate from entries', () {
      const summary = RotationSummary(
        added: [
          RotationTrackEntry(
            intelUid: 'i1',
            title: 'Awake',
            artist: 'Tycho',
            byteSize: 5_000_000,
          ),
          RotationTrackEntry(
            intelUid: 'i2',
            title: 'Four Tet',
            artist: 'Lush',
            byteSize: 4_500_000,
          ),
        ],
        removed: [
          RotationTrackEntry(
            intelUid: 'i3',
            title: 'Teardrop',
            artist: 'Massive Attack',
            byteSize: 6_000_000,
          ),
        ],
        afterSyncTrackCount: 100,
        afterSyncBytes: 5 * 1024 * 1024 * 1024,
        completedAt: 1747520000,
        aggregatePlayCount: 123,
      );
      expect(summary.addedBytes, 9_500_000);
      expect(summary.removedBytes, 6_000_000);
    });

    test('JSON round-trip preserves entries + totals', () {
      const summary = RotationSummary(
        added: [
          RotationTrackEntry(
            intelUid: 'i1',
            title: 'Awake',
            artist: 'Tycho',
            byteSize: 5_000_000,
          ),
        ],
        removed: [],
        afterSyncTrackCount: 100,
        afterSyncBytes: 5368709120,
        completedAt: 1747520000,
        aggregatePlayCount: 123,
      );
      final decoded = RotationSummary.fromJson(summary.toJson());
      expect(decoded.added, hasLength(1));
      expect(decoded.added.first.title, 'Awake');
      expect(decoded.afterSyncTrackCount, 100);
      expect(decoded.aggregatePlayCount, 123);
    });
  });
}

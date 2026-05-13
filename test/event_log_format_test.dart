import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/widgets/event_log_format.dart';

/// Tests for the shared event-log formatter. Both the Activity Log
/// dialog (utility rail) and the Load Operational State dialog's
/// activity timeline call into these functions; drift between
/// surfaces is the smell this test guards against.
///
/// Coverage targets:
///   - Every EventType has a non-default descriptor (no event falls
///     through to the forward-compat "unknown type" branch by
///     accident).
///   - Aggregate events render count + plurality correctly.
///   - Auto-move detail lines render temporal evidence iff the
///     successor overlapped the missing row within the grace window.
///   - Detail lines tolerate missing payload fields without throwing.
ActivityEvent _ev(
  String type, {
  String? path,
  Map<String, Object?> payload = const {},
}) {
  return ActivityEvent(
    id: 1,
    recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
    eventType: type,
    path: path,
    sourceId: null,
    payload: payload,
  );
}

void main() {
  group('eventDescriptorFor — every known type has a labeled descriptor',
      () {
    test('aggregate event types', () {
      expect(
        eventDescriptorFor(_ev(EventType.tracksPlayed,
                payload: {'count': 1}))
            .label,
        'Played 1 track',
      );
      expect(
        eventDescriptorFor(_ev(EventType.tracksPlayed,
                payload: {'count': 12}))
            .label,
        'Played 12 tracks',
      );
      expect(
        eventDescriptorFor(_ev(EventType.tracksPlayed,
                payload: {'count': 1420}))
            .label,
        'Played 1,420 tracks',
      );
      expect(
        eventDescriptorFor(_ev(EventType.favoritesAdded,
                payload: {'count': 1}))
            .label,
        'Added 1 favorite',
      );
      expect(
        eventDescriptorFor(_ev(EventType.favoritesAdded,
                payload: {'count': 4}))
            .label,
        'Added 4 favorites',
      );
      expect(
        eventDescriptorFor(_ev(EventType.scanCompleted)).label,
        'Library scan completed',
      );
      expect(
        eventDescriptorFor(_ev(EventType.scanCompleted,
                payload: {'source_name': 'Z CRATE'}))
            .label,
        'Library scan completed — Z CRATE',
      );
    });

    test('lifecycle event types', () {
      for (final type in <String>[
        EventType.removedExternal,
        EventType.autoMoveSameSource,
        EventType.autoMoveCrossSource,
        EventType.foundElsewhere,
        EventType.purged,
        EventType.manualRelink,
        EventType.contentUpdatedExternal,
        EventType.appInitiatedMove,
        EventType.appInitiatedCopy,
      ]) {
        final desc = eventDescriptorFor(_ev(type));
        expect(desc.label, isNotEmpty, reason: 'type=$type');
        // Unknown types fall through to the literal type string; every
        // known type should override that fallback with a real label.
        expect(desc.label, isNot(equals(type)), reason: 'type=$type');
      }
    });

    test('unknown event type → fallback descriptor with the raw type', () {
      final desc = eventDescriptorFor(_ev('future_event_v99'));
      expect(desc.label, 'future_event_v99');
    });
  });

  group('eventDetailLineFor — temporal evidence on auto-move events',
      () {
    test('auto-move with clean succession (negative overlap) omits '
        'overlap hint', () {
      final detail = eventDetailLineFor(_ev(
        EventType.autoMoveSameSource,
        payload: {
          'successor_path': '/A/new.mp3',
          'matched_on': 'content_hash',
          // missing.last_seen_at=1000, successor.first_seen_at=2500
          //   → overlap_ms = 1000 - 2500 = -1500 (clean).
          'overlap_ms': -1500,
        },
      ));
      expect(detail, '→ new.mp3  ·  matched on content_hash');
    });

    test('auto-move with zero overlap omits hint (boundary)', () {
      final detail = eventDetailLineFor(_ev(
        EventType.autoMoveCrossSource,
        payload: {
          'successor_path': '/B/new.mp3',
          'matched_on': 'content_hash',
          'overlap_ms': 0,
        },
      ));
      expect(detail, '→ new.mp3  ·  matched on content_hash');
    });

    test('auto-move with within-grace positive overlap surfaces hint',
        () {
      final detail = eventDetailLineFor(_ev(
        EventType.autoMoveSameSource,
        payload: {
          'successor_path': '/A/new.mp3',
          'matched_on': 'fingerprint',
          // 3 minutes — within the 10-minute grace.
          'overlap_ms': 180000,
        },
      ));
      expect(detail, '→ new.mp3  ·  matched on fingerprint  ·  3m overlap');
    });

    test('auto-move overlap formats in smallest natural unit', () {
      // 5 seconds → "5s"
      final fiveSec = eventDetailLineFor(_ev(
        EventType.autoMoveSameSource,
        payload: {
          'successor_path': '/A/new.mp3',
          'matched_on': 'content_hash',
          'overlap_ms': 5000,
        },
      ));
      expect(fiveSec, contains('5s overlap'));

      // 250 ms → "250ms"
      final subSec = eventDetailLineFor(_ev(
        EventType.autoMoveSameSource,
        payload: {
          'successor_path': '/A/new.mp3',
          'matched_on': 'content_hash',
          'overlap_ms': 250,
        },
      ));
      expect(subSec, contains('250ms overlap'));
    });

    test('auto-move without overlap_ms in payload still renders the '
        'main line (forward-compat with pre-Phase-2 events)', () {
      final detail = eventDetailLineFor(_ev(
        EventType.autoMoveSameSource,
        payload: {
          'successor_path': '/A/new.mp3',
          'matched_on': 'fingerprint',
        },
      ));
      expect(detail, '→ new.mp3  ·  matched on fingerprint');
    });

    test('auto-move without successor_path returns null', () {
      final detail = eventDetailLineFor(_ev(
        EventType.autoMoveSameSource,
        payload: const {},
      ));
      expect(detail, isNull);
    });
  });

  group('eventDetailLineFor — non-auto-move types', () {
    test('app_initiated_move with via', () {
      final detail = eventDetailLineFor(_ev(
        EventType.appInitiatedMove,
        payload: {
          'dest_path': '/B/song.mp3',
          'via': 'rename',
        },
      ));
      expect(detail, '→ song.mp3  ·  via rename');
    });

    test('app_initiated_copy', () {
      final detail = eventDetailLineFor(_ev(
        EventType.appInitiatedCopy,
        payload: {
          'dest_path': '/B/song.mp3',
        },
      ));
      expect(detail, '→ song.mp3');
    });

    test('purged surfaces prior_state', () {
      final detail = eventDetailLineFor(_ev(
        EventType.purged,
        payload: {'prior_state': 'missing'},
      ));
      expect(detail, 'prior state: missing');
    });

    test('manual_relink surfaces linked basename', () {
      final detail = eventDetailLineFor(_ev(
        EventType.manualRelink,
        payload: {'linked_to': '/A/sibling.mp3'},
      ));
      expect(detail, 'linked to sibling.mp3');
    });

    test('content_updated_external surfaces hash transition', () {
      final detail = eventDetailLineFor(_ev(
        EventType.contentUpdatedExternal,
        payload: {
          'old_content_hash_prefix': 'abc12345',
          'new_content_hash_prefix': 'def67890',
        },
      ));
      expect(detail, 'sha: abc12345… → def67890…');
    });

    test('found_elsewhere — single matching path', () {
      final detail = eventDetailLineFor(_ev(
        EventType.foundElsewhere,
        payload: {
          'matching_paths': ['/A/other.mp3'],
        },
      ));
      expect(detail, '↔ other.mp3');
    });

    test('found_elsewhere — multiple matching paths show summary', () {
      final detail = eventDetailLineFor(_ev(
        EventType.foundElsewhere,
        payload: {
          'matching_paths': ['/A/one.mp3', '/B/two.mp3', '/C/three.mp3'],
        },
      ));
      expect(detail, '↔ one.mp3  ·  +2 more');
    });

    test('aggregate events have no detail line', () {
      expect(
        eventDetailLineFor(
            _ev(EventType.tracksPlayed, payload: {'count': 5})),
        isNull,
      );
      expect(
        eventDetailLineFor(
            _ev(EventType.favoritesAdded, payload: {'count': 1})),
        isNull,
      );
      expect(
        eventDetailLineFor(_ev(EventType.scanCompleted)),
        isNull,
      );
    });

    test('unknown event type → no detail line', () {
      expect(eventDetailLineFor(_ev('future_event_v99')), isNull);
    });
  });
}

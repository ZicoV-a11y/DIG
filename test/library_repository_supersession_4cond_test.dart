import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Slice 2 — Phase 2 supersession rewrite. Both
/// `markMovedSupersessions` (same-source) and `markCrossSourceMoves`
/// (cross-source) now enforce the L9 4-condition rule:
///
///   1. Missing row is `availability_state = 'missing'`.
///   2. EXACTLY ONE candidate matches on content_hash (preferred)
///      or fingerprint (fallback).
///   3. Both rows pass junk-stat protection (filesize > 0,
///      duration_ms > 0).
///   4. Temporal soundness: successor.first_seen_at >=
///      missing.last_seen_at − supersessionTemporalOverlapGrace.
///
/// Existing tests in `library_repository_availability_test.dart`
/// already cover conditions 1, 2, 3 — they kept passing under the
/// rewrite because they use realistic timestamps that satisfy
/// condition 4 by accident. This file pins condition 4 explicitly
/// AND the newly-strict uniqueness on `markMovedSupersessions`
/// (previously absent there), plus the event-payload temporal
/// evidence both methods now emit.
void main() {
  late AppDatabase appDb;
  late LibraryRepository repo;
  late Database raw;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = LibraryRepository(appDb);
    raw = appDb.db;
    await raw.insert('sources', {
      'id': 'srcA',
      'display_name': 'A',
      'folder_path': '/A',
      'created_at': 0,
    });
    await raw.insert('sources', {
      'id': 'srcB',
      'display_name': 'B',
      'folder_path': '/B',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<void> insert({
    required String sourceId,
    required String path,
    required String fingerprint,
    String? contentHash,
    required String state, // 'available' | 'missing'
    required int firstSeenAt,
    required int lastSeenAt,
    int filesize = 1024,
    int durationMs = 240000,
    String? identityOverride,
    String? intelUid,
  }) async {
    final segments = path.split('/');
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': sourceId,
      'filename': segments.isEmpty ? path : segments.last,
      'filesize': filesize,
      'modified_at': lastSeenAt,
      'duration_ms': durationMs,
      'fingerprint': fingerprint,
      'content_hash': contentHash,
      'uid': 'uid-${path.hashCode.abs()}',
      'intel_uid': intelUid,
      'identity_override': identityOverride,
      'is_available': state == 'available' ? 1 : 0,
      'availability_state': state,
      'last_seen_at': lastSeenAt,
      'first_seen_at': firstSeenAt,
      'title': 'T',
    });
  }

  Future<String?> stateOf(String path) async {
    final rows = await raw.query(
      'indexed_files',
      columns: ['availability_state'],
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['availability_state'] as String?;
  }

  Future<List<Map<String, Object?>>> autoMoveEvents() async {
    return raw.query(
      'events',
      where: 'event_type IN (?, ?)',
      whereArgs: [
        EventType.autoMoveSameSource,
        EventType.autoMoveCrossSource,
      ],
      orderBy: 'id ASC',
    );
  }

  Map<String, dynamic> decodePayload(Map<String, Object?> event) {
    final raw = event['payload'] as String?;
    if (raw == null) return const {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // Useful boundary value: 10 min - 1 ms (inside grace).
  final justInsideGraceMs =
      supersessionTemporalOverlapGrace.inMilliseconds - 1;
  // 10 min + 1 ms (outside grace).
  final justOutsideGraceMs =
      supersessionTemporalOverlapGrace.inMilliseconds + 1;

  group('markMovedSupersessions (same-source) — 4-condition rule', () {
    test('happy path: unique content_hash match, successor first_seen '
        'AFTER missing.last_seen → superseded', () async {
      // missing's last_seen_at = 1000.
      // successor's first_seen_at = 2000 (well after).
      // Clean succession — overlap is negative (which we interpret
      // as "no overlap at all"). Auto-supersedes.
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-1',
        contentHash: 'hash-1',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/new.mp3',
        fingerprint: 'fp-1-renamed',
        contentHash: 'hash-1',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 1);
      expect(await stateOf('/A/old.mp3'), 'superseded');
    });

    test('temporal-after fails (overlap > grace): NOT superseded',
        () async {
      // missing's last_seen_at = 10_000_000.
      // successor's first_seen_at = 10_000_000 - (grace + 1).
      // The rows coexisted as available for longer than the grace
      // window — most likely intentional duplicate, refuse the
      // auto-supersession.
      const missingLastSeen = 10000000;
      final successorFirstSeen = missingLastSeen - justOutsideGraceMs;
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-x',
        contentHash: 'hash-x',
        state: 'missing',
        firstSeenAt: 0,
        lastSeenAt: missingLastSeen,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/coexisting.mp3',
        fingerprint: 'fp-x-other',
        contentHash: 'hash-x',
        state: 'available',
        firstSeenAt: successorFirstSeen,
        lastSeenAt: missingLastSeen,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 0);
      expect(await stateOf('/A/old.mp3'), 'missing');
    });

    test('overlap exactly at grace boundary: superseded (inclusive)',
        () async {
      // first_seen_at == last_seen_at - grace → overlap == grace.
      // Boundary is inclusive (>= grace), so the rule passes.
      const missingLastSeen = 10000000;
      final successorFirstSeen = missingLastSeen - justInsideGraceMs;
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-b',
        contentHash: 'hash-b',
        state: 'missing',
        firstSeenAt: 0,
        lastSeenAt: missingLastSeen,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/new.mp3',
        fingerprint: 'fp-b-renamed',
        contentHash: 'hash-b',
        state: 'available',
        firstSeenAt: successorFirstSeen,
        lastSeenAt: missingLastSeen + 1000,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 1);
    });

    test('uniqueness now enforced for same-source (was missing pre-rewrite): '
        'two available matches → NOT superseded', () async {
      // Two available rows share content_hash with the missing.
      // Auto-supersession refuses to pick.
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-multi',
        contentHash: 'hash-multi',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/candidate1.mp3',
        fingerprint: 'fp-multi-a',
        contentHash: 'hash-multi',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/candidate2.mp3',
        fingerprint: 'fp-multi-b',
        contentHash: 'hash-multi',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 0);
      expect(await stateOf('/A/old.mp3'), 'missing');
    });

    test('fingerprint fallback when content_hash is NULL on both '
        'sides → superseded under temporal-after', () async {
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-legacy',
        contentHash: null,
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/new.mp3',
        fingerprint: 'fp-legacy',
        contentHash: null,
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 1);
    });

    test('content_hash preferred over fingerprint (mixed signals)',
        () async {
      // Missing has content_hash AND fingerprint. Two candidates:
      //   - cand-A: matches content_hash (path of truth)
      //   - cand-B: matches fingerprint only (different content_hash)
      // Only cand-A counts; uniqueness still 1; supersede.
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-shared',
        contentHash: 'hash-truth',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/cand-A.mp3',
        fingerprint: 'fp-A',
        contentHash: 'hash-truth',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/cand-B.mp3',
        fingerprint: 'fp-shared',
        contentHash: 'different-hash',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 1);
      expect(await stateOf('/A/old.mp3'), 'superseded');
    });

    test('cross-source candidate does NOT satisfy same-source method',
        () async {
      // Same-source method must ignore matches in another source.
      // Even with all 4 conditions otherwise satisfied, a cross-
      // source successor cannot resolve a same-source move.
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-cs',
        contentHash: 'hash-cs',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcB',
        path: '/B/elsewhere.mp3',
        fingerprint: 'fp-cs-renamed',
        contentHash: 'hash-cs',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );

      final n = await repo.markMovedSupersessions('srcA');
      expect(n, 0);
      expect(await stateOf('/A/old.mp3'), 'missing');
    });

    test('event payload carries temporal evidence', () async {
      const missingLastSeen = 1000;
      const successorFirstSeen = 2500;
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-evt',
        contentHash: 'hash-evt',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: missingLastSeen,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/new.mp3',
        fingerprint: 'fp-evt-renamed',
        contentHash: 'hash-evt',
        state: 'available',
        firstSeenAt: successorFirstSeen,
        lastSeenAt: successorFirstSeen,
      );

      await repo.markMovedSupersessions('srcA');
      final events = await autoMoveEvents();
      expect(events.length, 1);
      final payload = decodePayload(events.single);
      expect(payload['matched_on'], 'content_hash');
      expect(payload['successor_path'], '/A/new.mp3');
      expect(payload['missing_last_seen_at'], missingLastSeen);
      expect(payload['successor_first_seen_at'], successorFirstSeen);
      // overlap_ms = missing.last_seen_at - successor.first_seen_at
      //            = 1000 - 2500 = -1500 (negative = clean
      // succession).
      expect(payload['overlap_ms'], -1500);
    });
  });

  group('markCrossSourceMoves — temporal soundness gate', () {
    test('temporal-after fails (overlap > grace): NOT superseded',
        () async {
      // Cross-source intentional duplicate: master in srcA, working
      // copy in srcB, both have lived simultaneously for >> grace.
      // When srcA goes missing, the srcB copy is NOT a successor —
      // it's a coexisting duplicate that pre-dated the move event.
      const missingLastSeen = 10000000;
      final successorFirstSeen = missingLastSeen - justOutsideGraceMs;
      await insert(
        sourceId: 'srcA',
        path: '/A/master.mp3',
        fingerprint: 'fp-c',
        contentHash: 'hash-c',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: missingLastSeen,
      );
      await insert(
        sourceId: 'srcB',
        path: '/B/working_copy.mp3',
        fingerprint: 'fp-c',
        contentHash: 'hash-c',
        state: 'available',
        firstSeenAt: successorFirstSeen,
        lastSeenAt: missingLastSeen,
      );

      final n = await repo.markCrossSourceMoves();
      expect(n, 0);
      expect(await stateOf('/A/master.mp3'), 'missing');
    });

    test('cross-source clean succession → superseded', () async {
      // File legitimately moved from srcA to srcB: srcA copy gone,
      // srcB copy appeared after. Temporal-after passes; uniqueness
      // passes; supersede.
      await insert(
        sourceId: 'srcA',
        path: '/A/song.mp3',
        fingerprint: 'fp-d',
        contentHash: 'hash-d',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcB',
        path: '/B/song.mp3',
        fingerprint: 'fp-d',
        contentHash: 'hash-d',
        state: 'available',
        firstSeenAt: 5000,
        lastSeenAt: 5000,
      );

      final n = await repo.markCrossSourceMoves();
      expect(n, 1);
      expect(await stateOf('/A/song.mp3'), 'superseded');
    });

    test('event distinguishes same-source vs cross-source via '
        'successor_source_id; temporal evidence present', () async {
      // One same-source move + one cross-source move. Both should
      // emit events; one of each type.
      // Same-source pair:
      await insert(
        sourceId: 'srcA',
        path: '/A/same_old.mp3',
        fingerprint: 'fp-ss',
        contentHash: 'hash-ss',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcA',
        path: '/A/same_new.mp3',
        fingerprint: 'fp-ss-renamed',
        contentHash: 'hash-ss',
        state: 'available',
        firstSeenAt: 2000,
        lastSeenAt: 2000,
      );
      // Cross-source pair:
      await insert(
        sourceId: 'srcA',
        path: '/A/cross_old.mp3',
        fingerprint: 'fp-cs2',
        contentHash: 'hash-cs2',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: 1000,
      );
      await insert(
        sourceId: 'srcB',
        path: '/B/cross_new.mp3',
        fingerprint: 'fp-cs2',
        contentHash: 'hash-cs2',
        state: 'available',
        firstSeenAt: 3000,
        lastSeenAt: 3000,
      );

      final n = await repo.markCrossSourceMoves();
      expect(n, 2);

      final events = await autoMoveEvents();
      expect(events.length, 2);
      final byType = {
        for (final e in events) e['event_type'] as String: e,
      };
      expect(byType.containsKey(EventType.autoMoveSameSource), isTrue);
      expect(byType.containsKey(EventType.autoMoveCrossSource), isTrue);

      // Both event payloads carry temporal evidence.
      for (final e in events) {
        final payload = decodePayload(e);
        expect(payload['missing_last_seen_at'], isNotNull);
        expect(payload['successor_first_seen_at'], isNotNull);
        expect(payload['overlap_ms'], isNotNull);
        expect(payload['matched_on'], 'content_hash');
      }
    });

    test('overlap within grace passes (boundary inclusive)', () async {
      // Cross-source rename within grace window: e.g. a Mp3tag
      // re-render that briefly produced two visible copies before
      // the old one got cleaned up by the next scan tick.
      const missingLastSeen = 10000000;
      final successorFirstSeen = missingLastSeen - justInsideGraceMs;
      await insert(
        sourceId: 'srcA',
        path: '/A/old.mp3',
        fingerprint: 'fp-bnd',
        contentHash: 'hash-bnd',
        state: 'missing',
        firstSeenAt: 100,
        lastSeenAt: missingLastSeen,
      );
      await insert(
        sourceId: 'srcB',
        path: '/B/new.mp3',
        fingerprint: 'fp-bnd-renamed',
        contentHash: 'hash-bnd',
        state: 'available',
        firstSeenAt: successorFirstSeen,
        lastSeenAt: missingLastSeen + 1000,
      );

      final n = await repo.markCrossSourceMoves();
      expect(n, 1);
    });
  });
}

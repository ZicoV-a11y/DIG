// PR1 review-semantics contract — tests that pin the v15 migration's
// promises and the threshold-driven mutation API.
//
// What "threshold-canonical review semantics" buys us:
//
//   1. `tracks.reviewed_at` is the durable flag (replaces the derived
//      `cumulative_ms >= 3` heuristic).
//   2. `repo.updateIntelligence(reviewedAt: ms)` stamps it; the
//      `clearReviewedAt: true` flag NULLs it (right-click "Mark
//      unreviewed" path).
//   3. Toggling `favorite` auto-stamps `favorite_toggled_at` so the
//      iPhone-sync reconciler can run last-write-wins.
//   4. Bucket consolidation merges review timestamps (earliest wins —
//      review is sticky) and favorite-toggle timestamps (latest wins —
//      LWW reconciliation).
//   5. v14 → v15 backfill preserves every existing "reviewed"
//      judgement: any track with `cumulative_ms >= 3000` gets a
//      `reviewed_at` value so the visible state on disk matches the
//      visible state in the UI both before and after the upgrade.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/intelligence_record.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    // Seed a source so any indexed_files inserts further down keep
    // their FK constraint happy.
    await raw.insert('sources', {
      'id': 'src1',
      'display_name': 'test',
      'folder_path': '/test',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<void> insertTrack({
    required String uid,
    String fingerprint = '',
    bool favorite = false,
    int playCount = 0,
    int cumulativeMs = 0,
    int? lastPlayedAt,
    int? reviewedAt,
    int? favoriteToggledAt,
    int createdAt = 100,
  }) async {
    await raw.insert('tracks', {
      'uid': uid,
      'fingerprint': fingerprint,
      'created_at': createdAt,
      'favorite': favorite ? 1 : 0,
      'play_count': playCount,
      'cumulative_ms': cumulativeMs,
      'last_played_at': lastPlayedAt,
      'reviewed_at': reviewedAt,
      'favorite_toggled_at': favoriteToggledAt,
    });
  }

  Future<Map<String, Object?>> readRow(String uid) async {
    final rows = await raw.query('tracks', where: 'uid = ?', whereArgs: [uid]);
    return rows.first;
  }

  group('updateIntelligence reviewed_at semantics', () {
    test('reviewedAt parameter stamps the column', () async {
      await insertTrack(uid: 'u1');
      await repo.updateIntelligence(intelUid: 'u1', reviewedAt: 42);
      final row = await readRow('u1');
      expect(row['reviewed_at'], 42);
    });

    test('clearReviewedAt: true nulls the column', () async {
      await insertTrack(uid: 'u1', reviewedAt: 42);
      await repo.updateIntelligence(intelUid: 'u1', clearReviewedAt: true);
      final row = await readRow('u1');
      expect(row['reviewed_at'], isNull);
    });

    test('clearReviewedAt wins over reviewedAt when both passed', () async {
      // Defense-in-depth: if a caller passes both, explicit-clear is
      // the safer choice (we don't want a programming error to leave
      // a track marked reviewed when the caller asked to clear it).
      await insertTrack(uid: 'u1', reviewedAt: 100);
      await repo.updateIntelligence(
        intelUid: 'u1',
        reviewedAt: 200,
        clearReviewedAt: true,
      );
      final row = await readRow('u1');
      expect(row['reviewed_at'], isNull);
    });

    test('omitting both leaves reviewed_at untouched', () async {
      await insertTrack(uid: 'u1', reviewedAt: 99);
      await repo.updateIntelligence(intelUid: 'u1', playCount: 5);
      final row = await readRow('u1');
      expect(row['reviewed_at'], 99);
      expect(row['play_count'], 5);
    });
  });

  group('updateIntelligence favorite_toggled_at semantics', () {
    test('favorite mutation auto-stamps favorite_toggled_at', () async {
      await insertTrack(uid: 'u1');
      final before = DateTime.now().millisecondsSinceEpoch;
      await repo.updateIntelligence(intelUid: 'u1', favorite: true);
      final after = DateTime.now().millisecondsSinceEpoch;
      final row = await readRow('u1');
      expect(row['favorite'], 1);
      final stamped = row['favorite_toggled_at'] as int;
      expect(stamped, greaterThanOrEqualTo(before));
      expect(stamped, lessThanOrEqualTo(after));
    });

    test('explicit favoriteToggledAt overrides the auto-stamp', () async {
      // Phone-sync reconciler uses this to preserve the originating
      // timestamp from the device. The auto-stamp would otherwise
      // rewrite history on every desktop write.
      await insertTrack(uid: 'u1');
      await repo.updateIntelligence(
        intelUid: 'u1',
        favorite: true,
        favoriteToggledAt: 12345,
      );
      final row = await readRow('u1');
      expect(row['favorite'], 1);
      expect(row['favorite_toggled_at'], 12345);
    });

    test('favoriteToggledAt without favorite still writes', () async {
      // Allows phone-sync to land a remote-origin timestamp even
      // when desktop and phone agree on the bool — keeps the LWW
      // clock monotonic.
      await insertTrack(uid: 'u1', favorite: true, favoriteToggledAt: 100);
      await repo.updateIntelligence(intelUid: 'u1', favoriteToggledAt: 500);
      final row = await readRow('u1');
      expect(row['favorite_toggled_at'], 500);
      expect(row['favorite'], 1);
    });

    test('omitting favorite + favoriteToggledAt leaves both untouched',
        () async {
      await insertTrack(uid: 'u1', favorite: true, favoriteToggledAt: 100);
      await repo.updateIntelligence(intelUid: 'u1', playCount: 5);
      final row = await readRow('u1');
      expect(row['favorite'], 1);
      expect(row['favorite_toggled_at'], 100);
    });
  });

  group('fetchIntelligence returns the new fields', () {
    test('round-trips reviewed_at + favorite_toggled_at', () async {
      await insertTrack(
        uid: 'u1',
        favorite: true,
        reviewedAt: 42,
        favoriteToggledAt: 99,
      );
      final intel = await repo.fetchIntelligence('u1');
      expect(intel, isNotNull);
      expect(intel!.reviewedAt, 42);
      expect(intel.favoriteToggledAt, 99);
      expect(intel.favorite, isTrue);
    });

    test('returns nulls for unstamped fields', () async {
      await insertTrack(uid: 'u1');
      final intel = await repo.fetchIntelligence('u1');
      expect(intel!.reviewedAt, isNull);
      expect(intel.favoriteToggledAt, isNull);
    });
  });

  group('v14→v15 backfill (simulated)', () {
    // The migration runs at DB open from a lower version; in-memory
    // databases always open at the current version. We invoke the
    // same UPDATE statement directly to verify the backfill rule
    // matches the contract.
    Future<int> runBackfill() async {
      return await raw.rawUpdate(
        'UPDATE tracks '
        'SET reviewed_at = COALESCE(last_played_at, created_at) '
        'WHERE cumulative_ms >= 3000 AND reviewed_at IS NULL',
      );
    }

    test('marks tracks reviewed using last_played_at when present',
        () async {
      await insertTrack(uid: 'u1', cumulativeMs: 5000, lastPlayedAt: 200);
      final backfilled = await runBackfill();
      expect(backfilled, 1);
      final row = await readRow('u1');
      expect(row['reviewed_at'], 200);
    });

    test('falls back to created_at when last_played_at is null', () async {
      await insertTrack(
        uid: 'u1',
        cumulativeMs: 5000,
        createdAt: 150,
        lastPlayedAt: null,
      );
      await runBackfill();
      final row = await readRow('u1');
      expect(row['reviewed_at'], 150);
    });

    test('does NOT mark tracks with cumulative_ms < 3000', () async {
      await insertTrack(uid: 'u1', cumulativeMs: 2999, lastPlayedAt: 200);
      await runBackfill();
      final row = await readRow('u1');
      expect(row['reviewed_at'], isNull);
    });

    test('does NOT overwrite an already-set reviewed_at', () async {
      await insertTrack(
        uid: 'u1',
        cumulativeMs: 5000,
        lastPlayedAt: 200,
        reviewedAt: 50,
      );
      await runBackfill();
      final row = await readRow('u1');
      expect(row['reviewed_at'], 50);
    });
  });

  group('importIntelligenceRecords merges reviewed_at + favorite_toggled_at',
      () {
    test('reviewed_at merge takes EARLIEST non-null (sticky review)',
        () async {
      // Review is sticky — the EARLIEST moment review was asserted
      // is the truth. A later import shouldn't postpone the review
      // timestamp.
      await insertTrack(
        uid: 'u1',
        playCount: 5,
        cumulativeMs: 5000,
        reviewedAt: 200,
      );
      final summary = await repo.importIntelligenceRecords([
        IntelligenceRecord(
          uid: 'u1',
          fingerprint: '',
          basename: '',
          filesize: 0,
          durationMs: 0,
          createdAt: 0,
          favorite: false,
          playCount: 2,
          cumulativeMs: 2000,
          lastPlayedAt: null,
          reviewedAt: 100, // earlier than local
        ),
      ]);
      expect(summary.mergedByUid, 1);
      final row = await readRow('u1');
      expect(row['reviewed_at'], 100);
      expect(row['play_count'], 7); // sum
    });

    test('reviewed_at merge keeps local when imported is null', () async {
      await insertTrack(uid: 'u1', reviewedAt: 50);
      await repo.importIntelligenceRecords([
        IntelligenceRecord(
          uid: 'u1',
          fingerprint: '',
          basename: '',
          filesize: 0,
          durationMs: 0,
          createdAt: 0,
          favorite: false,
          playCount: 0,
          cumulativeMs: 0,
          lastPlayedAt: null,
        ),
      ]);
      final row = await readRow('u1');
      expect(row['reviewed_at'], 50);
    });

    test('favorite_toggled_at merge takes LATEST (LWW)', () async {
      await insertTrack(uid: 'u1', favoriteToggledAt: 100);
      await repo.importIntelligenceRecords([
        IntelligenceRecord(
          uid: 'u1',
          fingerprint: '',
          basename: '',
          filesize: 0,
          durationMs: 0,
          createdAt: 0,
          favorite: true,
          playCount: 0,
          cumulativeMs: 0,
          lastPlayedAt: null,
          favoriteToggledAt: 500,
        ),
      ]);
      final row = await readRow('u1');
      expect(row['favorite_toggled_at'], 500);
    });

    test('ghost insert carries reviewed_at + favorite_toggled_at through',
        () async {
      await repo.importIntelligenceRecords([
        IntelligenceRecord(
          uid: 'ghost',
          fingerprint: 'fp',
          basename: '',
          filesize: 0,
          durationMs: 0,
          createdAt: 0,
          favorite: true,
          playCount: 3,
          cumulativeMs: 4000,
          lastPlayedAt: 999,
          reviewedAt: 800,
          favoriteToggledAt: 850,
        ),
      ]);
      final row = await readRow('ghost');
      expect(row['reviewed_at'], 800);
      expect(row['favorite_toggled_at'], 850);
    });
  });

  group('exportIntelligenceRecords emits new fields', () {
    test('round-trips reviewed_at + favorite_toggled_at to JSON', () async {
      await insertTrack(
        uid: 'u1',
        favorite: true,
        reviewedAt: 200,
        favoriteToggledAt: 300,
      );
      final exported = await repo.exportIntelligenceRecords();
      expect(exported, hasLength(1));
      expect(exported[0].reviewedAt, 200);
      expect(exported[0].favoriteToggledAt, 300);

      final json = exported[0].toJson();
      expect(json['reviewedAt'], 200);
      expect(json['favoriteToggledAt'], 300);

      // And re-parse must preserve them.
      final reparsed = IntelligenceRecord.fromJson(json);
      expect(reparsed.reviewedAt, 200);
      expect(reparsed.favoriteToggledAt, 300);
    });

    test('omits null fields from JSON for forward-compat', () async {
      await insertTrack(uid: 'u1');
      final exported = await repo.exportIntelligenceRecords();
      final json = exported[0].toJson();
      expect(json.containsKey('reviewedAt'), isFalse);
      expect(json.containsKey('favoriteToggledAt'), isFalse);
    });
  });
}

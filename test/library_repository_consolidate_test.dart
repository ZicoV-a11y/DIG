import 'package:flutter_test/flutter_test.dart';
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
    // Seed the source FK so indexed_files inserts succeed.
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

  Future<void> insertIndexedFile({
    required String path,
    required String filename,
    required String fingerprint,
    required String uid,
    String? intelUid,
    String title = 'Song',
    String artist = 'Artist',
    int durationMs = 300000,
  }) async {
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': 'src1',
      'filename': filename,
      'filesize': 0,
      'modified_at': 0,
      'duration_ms': durationMs,
      'fingerprint': fingerprint,
      'uid': uid,
      'intel_uid': intelUid,
      'is_available': 1,
      'last_seen_at': 0,
      'title': title,
      'artist': artist,
    });
  }

  Future<void> insertTracksRow({
    required String uid,
    required String fingerprint,
    bool favorite = false,
    int playCount = 0,
    int cumulativeMs = 0,
    int? lastPlayedAt,
  }) async {
    await raw.insert('tracks', {
      'uid': uid,
      'fingerprint': fingerprint,
      'created_at': 0,
      'favorite': favorite ? 1 : 0,
      'play_count': playCount,
      'cumulative_ms': cumulativeMs,
      'last_played_at': lastPlayedAt,
    });
  }

  Future<Map<String, Object?>?> tracksRowOrNull(String uid) async {
    final rows = await raw.query(
      'tracks',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> intelUidFor(String path) async {
    final rows = await raw.query(
      'indexed_files',
      columns: ['intel_uid'],
      where: 'path = ?',
      whereArgs: [path],
    );
    return rows.first['intel_uid'] as String?;
  }

  group('consolidateBucketIntelligence', () {
    test('returns null for empty path list', () async {
      expect(await repo.consolidateBucketIntelligence([]), isNull);
    });

    test('returns null when no indexed_files rows match', () async {
      expect(
        await repo.consolidateBucketIntelligence(['/missing.mp3']),
        isNull,
      );
    });

    test('promotes bucket with no existing intel — creates one tracks row', () async {
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
      );
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
      );

      final canonical = await repo.consolidateBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );
      expect(canonical, isNotNull);
      // Both rows now point at canonical.
      expect(await intelUidFor('/a/song.mp3'), canonical);
      expect(await intelUidFor('/b/song.aiff'), canonical);
      // One tracks row exists with default values.
      final row = await tracksRowOrNull(canonical!);
      expect(row, isNotNull);
      expect(row!['favorite'], 0);
      expect(row['play_count'], 0);
    });

    test('one existing intel uid — re-points the unpromoted variant', () async {
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
        intelUid: 'uid-mp3',
      );
      await insertTracksRow(
        uid: 'uid-mp3',
        fingerprint: 'fp-mp3',
        favorite: true,
        playCount: 3,
      );
      // AIFF has no intel yet.
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
      );

      final canonical = await repo.consolidateBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );
      expect(canonical, 'uid-mp3');
      expect(await intelUidFor('/a/song.mp3'), 'uid-mp3');
      expect(await intelUidFor('/b/song.aiff'), 'uid-mp3');
      // Existing tracks row is unchanged (no merge needed).
      final row = await tracksRowOrNull('uid-mp3');
      expect(row!['favorite'], 1);
      expect(row['play_count'], 3);
    });

    test('two distinct intel uids — picks highest playCount as canonical and merges', () async {
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
        intelUid: 'uid-mp3',
      );
      await insertTracksRow(
        uid: 'uid-mp3',
        fingerprint: 'fp-mp3',
        favorite: false,
        playCount: 3,
        cumulativeMs: 60000,
        lastPlayedAt: 1000,
      );
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
        intelUid: 'uid-aiff',
      );
      await insertTracksRow(
        uid: 'uid-aiff',
        fingerprint: 'fp-aiff',
        favorite: true,
        playCount: 5, // higher → canonical
        cumulativeMs: 90000,
        lastPlayedAt: 2000,
      );

      final canonical = await repo.consolidateBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );
      expect(canonical, 'uid-aiff'); // higher playCount wins

      // Both rows now point at canonical.
      expect(await intelUidFor('/a/song.mp3'), 'uid-aiff');
      expect(await intelUidFor('/b/song.aiff'), 'uid-aiff');

      // Orphan deleted.
      expect(await tracksRowOrNull('uid-mp3'), isNull);

      // Canonical holds merged values.
      final row = await tracksRowOrNull('uid-aiff');
      expect(row!['favorite'], 1); // OR
      expect(row['play_count'], 8); // 3 + 5
      expect(row['cumulative_ms'], 150000); // 60000 + 90000
      expect(row['last_played_at'], 2000); // max
    });

    test('tiebreaker on playCount → lexicographically smallest uid', () async {
      // Same play count on both: smallest uid wins for determinism.
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-b', // intentionally `b`
        intelUid: 'uid-b',
      );
      await insertTracksRow(uid: 'uid-b', fingerprint: 'fp-mp3', playCount: 4);
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-a',
        intelUid: 'uid-a',
      );
      await insertTracksRow(uid: 'uid-a', fingerprint: 'fp-aiff', playCount: 4);

      final canonical = await repo.consolidateBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );
      expect(canonical, 'uid-a'); // lex smallest
      expect(await tracksRowOrNull('uid-b'), isNull); // orphan gone
    });

    test('also re-points OTHER indexed_files rows that point at orphan uid', () async {
      // Scenario: a literal fingerprint-duplicate of the AIFF lives at
      // a third path and shares its intel_uid via the older
      // fingerprint-sharing path. After consolidation it should also
      // be re-pointed at canonical so its in-memory mirror works.
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
        intelUid: 'uid-mp3',
      );
      await insertTracksRow(uid: 'uid-mp3', fingerprint: 'fp-mp3', playCount: 9);
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
        intelUid: 'uid-aiff',
      );
      await insertTracksRow(uid: 'uid-aiff', fingerprint: 'fp-aiff', playCount: 1);
      // Sneaky third row: literal duplicate of the AIFF at a moved
      // path, sharing intel via fingerprint.
      await insertIndexedFile(
        path: '/c/dup.aiff',
        filename: 'dup.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-dup',
        intelUid: 'uid-aiff',
      );

      final canonical = await repo.consolidateBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );
      expect(canonical, 'uid-mp3'); // higher playCount

      // Sneaky third row gets re-pointed even though it wasn't in
      // the input paths list, because it shared the orphan's uid.
      expect(await intelUidFor('/c/dup.aiff'), 'uid-mp3');
    });
  });
}

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
    String? identityOverride,
  }) async {
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': 'src1',
      'filename': filename,
      'filesize': 0,
      'modified_at': 0,
      'duration_ms': 300000,
      'fingerprint': fingerprint,
      'uid': uid,
      'intel_uid': intelUid,
      'identity_override': identityOverride,
      'is_available': 1,
      'last_seen_at': 0,
      'title': 'T',
      'artist': 'A',
    });
  }

  Future<void> insertTracksRow({
    required String uid,
    int playCount = 0,
    bool favorite = false,
  }) async {
    await raw.insert('tracks', {
      'uid': uid,
      'fingerprint': 'fp',
      'created_at': 0,
      'favorite': favorite ? 1 : 0,
      'play_count': playCount,
      'cumulative_ms': 0,
      'last_played_at': null,
    });
  }

  Future<Map<String, Object?>?> indexedFileRow(String path) async {
    final rows = await raw.query(
      'indexed_files',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<bool> tracksRowExists(String uid) async {
    final rows = await raw.query(
      'tracks',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  group('unlinkBucketIntelligence', () {
    test('empty input returns empty set', () async {
      expect(await repo.unlinkBucketIntelligence([]), isEmpty);
    });

    test('missing paths return empty set', () async {
      expect(
        await repo.unlinkBucketIntelligence(['/missing']),
        isEmpty,
      );
    });

    test('forces every row to a singleton override (own uid)', () async {
      await insertTracksRow(uid: 'canonical');
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
        intelUid: 'canonical',
        identityOverride: 'shared-override',
      );
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
        intelUid: 'canonical',
        identityOverride: 'shared-override',
      );

      await repo.unlinkBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );

      final mp3 = await indexedFileRow('/a/song.mp3');
      final aiff = await indexedFileRow('/b/song.aiff');
      // Each row's override now equals its own uid.
      expect(mp3!['identity_override'], 'uid-mp3');
      expect(aiff!['identity_override'], 'uid-aiff');
      // intel_uid cleared on both.
      expect(mp3['intel_uid'], isNull);
      expect(aiff['intel_uid'], isNull);
    });

    test('deletes orphaned tracks row and returns its uid', () async {
      await insertTracksRow(
        uid: 'canonical',
        playCount: 25,
        favorite: true,
      );
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
        intelUid: 'canonical',
      );
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
        intelUid: 'canonical',
      );

      final deleted = await repo.unlinkBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );

      expect(deleted, {'canonical'});
      expect(await tracksRowExists('canonical'), isFalse);
    });

    test('preserves tracks row that still has external referrers', () async {
      // Defensive: if an indexed_files row outside the bucket still
      // points at the canonical intel uid (e.g., a literal-duplicate
      // sharing intel via the older fingerprint path), don't delete
      // the row — it would orphan that outside referrer.
      await insertTracksRow(
        uid: 'canonical',
        playCount: 25,
      );
      await insertIndexedFile(
        path: '/a/song.mp3',
        filename: 'song.mp3',
        fingerprint: 'fp-mp3',
        uid: 'uid-mp3',
        intelUid: 'canonical',
      );
      await insertIndexedFile(
        path: '/b/song.aiff',
        filename: 'song.aiff',
        fingerprint: 'fp-aiff',
        uid: 'uid-aiff',
        intelUid: 'canonical',
      );
      // Outsider that's NOT part of the bucket being unlinked.
      await insertIndexedFile(
        path: '/c/outside.mp3',
        filename: 'outside.mp3',
        fingerprint: 'fp-outside',
        uid: 'uid-outside',
        intelUid: 'canonical',
      );

      final deleted = await repo.unlinkBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );

      // Nothing deleted — outsider still referenced canonical.
      expect(deleted, isEmpty);
      expect(await tracksRowExists('canonical'), isTrue);
      // The outsider's intel_uid is untouched.
      final outsider = await indexedFileRow('/c/outside.mp3');
      expect(outsider!['intel_uid'], 'canonical');
    });

    test('handles paths with no prior intel cleanly', () async {
      // No tracks row, no intel_uid, no override yet — unlink just
      // sets the override to the row's uid.
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

      final deleted = await repo.unlinkBucketIntelligence(
        ['/a/song.mp3', '/b/song.aiff'],
      );

      expect(deleted, isEmpty);
      final mp3 = await indexedFileRow('/a/song.mp3');
      expect(mp3!['identity_override'], 'uid-mp3');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tests for `LibraryRepository.healOrphanedIdentitySiblings`.
///
/// Background: `copyTrackFile` used to stamp `identity_override` on
/// the source + new dest row only, leaving 4-field-matched codec
/// siblings (e.g. an AIFF sharing basename+title+artist+duration
/// with the MP3 pair) orphaned with a NULL override. Since
/// `sameSongIdentity` treats the asymmetric "one has override, one
/// is NULL" case as intentionally distinct, the AIFF visually fell
/// out of the bucket.
///
/// The heal pass backfills the override onto pristine NULL-override
/// siblings — but MUST NOT touch rows that were explicitly unlinked
/// (those have their own uid as the override, never NULL).
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

  Future<void> insert({
    required String path,
    required String filename,
    required String uid,
    String title = 'Right Now',
    String artist = 'Masaki Morii',
    int durationMs = 405000,
    String? identityOverride,
    int isAvailable = 1,
  }) async {
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': 'src1',
      'filename': filename,
      'filesize': 0,
      'modified_at': 0,
      'duration_ms': durationMs,
      'fingerprint': 'fp-$uid',
      'uid': uid,
      'intel_uid': null,
      'identity_override': identityOverride,
      'is_available': isAvailable,
      'last_seen_at': 0,
      'title': title,
      'artist': artist,
    });
  }

  Future<String?> overrideOf(String path) async {
    final rows = await raw.query(
      'indexed_files',
      columns: ['identity_override'],
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.first['identity_override'] as String?;
  }

  test('pristine NULL-override sibling adopts override from 4-field match',
      () async {
    // Reproduces the user's AIFF-disappearance bug: two MP3s share an
    // override (the Copy that stamped them is implicit here), an
    // AIFF with the same basename/title/artist/duration has NULL.
    await insert(
      path: '/dl/Right Now (Original Mix).mp3',
      filename: 'Right Now (Original Mix).mp3',
      uid: 'uid-mp3-a',
      identityOverride: 'shared-bucket-uuid',
    );
    await insert(
      path: '/z/Right Now (Original Mix).mp3',
      filename: 'Right Now (Original Mix).mp3',
      uid: 'uid-mp3-b',
      identityOverride: 'shared-bucket-uuid',
    );
    await insert(
      path: '/dl/Right Now (Original Mix).aiff',
      filename: 'Right Now (Original Mix).aiff',
      uid: 'uid-aiff',
      identityOverride: null,
    );

    final healed = await repo.healOrphanedIdentitySiblings();
    expect(healed, 1);
    expect(
      await overrideOf('/dl/Right Now (Original Mix).aiff'),
      'shared-bucket-uuid',
    );
    // MP3 rows are untouched.
    expect(
      await overrideOf('/dl/Right Now (Original Mix).mp3'),
      'shared-bucket-uuid',
    );
  });

  test('idempotent — running twice heals nothing the second time',
      () async {
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/song.aiff',
      filename: 'song.aiff',
      uid: 'uid-aiff',
    );

    expect(await repo.healOrphanedIdentitySiblings(), 1);
    expect(await repo.healOrphanedIdentitySiblings(), 0);
  });

  test('does NOT touch unlinked rows (override = own uid)', () async {
    // Unlink semantics: a row with identity_override set to its OWN
    // uid is intentionally a singleton. The heal pass must NOT
    // sweep it back into a bucket.
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/song.aiff',
      filename: 'song.aiff',
      uid: 'uid-aiff-self',
      identityOverride: 'uid-aiff-self', // explicitly unlinked
    );

    final healed = await repo.healOrphanedIdentitySiblings();
    expect(healed, 0);
    expect(await overrideOf('/dl/song.aiff'), 'uid-aiff-self');
  });

  test('does NOT widen across mismatched basenames', () async {
    // Same title/artist/duration but different basenames — they are
    // intentionally NOT 4-field siblings.
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/different-name.aiff',
      filename: 'different-name.aiff',
      uid: 'uid-aiff',
      identityOverride: null,
    );

    final healed = await repo.healOrphanedIdentitySiblings();
    expect(healed, 0);
    expect(await overrideOf('/dl/different-name.aiff'), isNull);
  });

  test('does NOT widen across mismatched durations (>1 second drift)',
      () async {
    // Same basename + title + artist but durations differ by more
    // than one whole second — different recording (radio edit vs
    // extended mix). Stays separate.
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      durationMs: 240000,
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/song.aiff',
      filename: 'song.aiff',
      uid: 'uid-aiff',
      durationMs: 420000,
      identityOverride: null,
    );

    final healed = await repo.healOrphanedIdentitySiblings();
    expect(healed, 0);
    expect(await overrideOf('/dl/song.aiff'), isNull);
  });

  test('does NOT widen when title or artist is empty', () async {
    // Without metadata there's no song identity to inherit. Pristine
    // empty-metadata rows are individually opaque and must stay
    // singletons.
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/song.aiff',
      filename: 'song.aiff',
      uid: 'uid-aiff',
      title: '',
      artist: '',
    );

    expect(await repo.healOrphanedIdentitySiblings(), 0);
    expect(await overrideOf('/dl/song.aiff'), isNull);
  });

  test('does NOT widen onto rows that are not available', () async {
    // is_available = 0 rows are missing/superseded — they shouldn't
    // be merged back into the bucket via heal; that's a job for the
    // explicit supersession logic.
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/song.aiff',
      filename: 'song.aiff',
      uid: 'uid-aiff',
      isAvailable: 0,
    );

    expect(await repo.healOrphanedIdentitySiblings(), 0);
    expect(await overrideOf('/dl/song.aiff'), isNull);
  });

  test('empty-string override is treated the same as NULL', () async {
    // Defensive: a writer somewhere might store '' instead of null.
    // Heal treats both as pristine.
    await insert(
      path: '/dl/song.mp3',
      filename: 'song.mp3',
      uid: 'uid-mp3',
      identityOverride: 'bucket-1',
    );
    await insert(
      path: '/dl/song.aiff',
      filename: 'song.aiff',
      uid: 'uid-aiff',
      identityOverride: '',
    );

    expect(await repo.healOrphanedIdentitySiblings(), 1);
    expect(await overrideOf('/dl/song.aiff'), 'bucket-1');
  });
}

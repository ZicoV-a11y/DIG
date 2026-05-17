import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/widgets/delete_track_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression coverage for the in-app delete pathway.
///
/// The controller's `deleteTracksToTrash` orchestrates three repo
/// primitives in sequence: `purgeIndexedFiles` for DB cleanup,
/// `updateIntelligence(favorite: false)` for the optional FAV
/// cascade, and (on the Dart side) in-memory pruning of trashed
/// rows. The trash hop itself goes over a platform channel so the
/// tests can't cover it end-to-end — what they CAN cover is the
/// repo-level contract: after the controller's repo writes land,
/// the DB looks the way the user expects.
///
/// Properties pinned:
///   - `DeleteDecision` carries the right fields verbatim.
///   - `purgeIndexedFiles` removes the requested paths AND records
///     a `purged` event per row. Intel rows in `tracks` survive —
///     that's the guardrail-#5 promise the FAV-preservation popup
///     leans on (re-add reconnects history).
///   - `updateIntelligence(favorite: false)` clears favorite on
///     the song's intel row. Surviving variants in OTHER paths
///     pointing at the same intel_uid have a row that the controller
///     mirrors to false in-memory; that mirror isn't tested here
///     (it's an in-memory walk, not a DB primitive) but the DB-side
///     of the cascade is.
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
      'display_name': 'Z CRATE',
      'folder_path': '/Z',
      'created_at': 0,
    });
    await raw.insert('sources', {
      'id': 'src2',
      'display_name': 'Afro:Tech:Deep',
      'folder_path': '/Afro',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<void> insertIndexedFile({
    required String path,
    required String filename,
    required String sourceId,
    required String uid,
    String? intelUid,
  }) async {
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': sourceId,
      'filename': filename,
      'filesize': 1000,
      'modified_at': 0,
      'duration_ms': 300000,
      'fingerprint': 'fp-$uid',
      'uid': uid,
      'intel_uid': intelUid,
      'is_available': 1,
      'last_seen_at': 0,
      'title': 'T',
      'artist': 'A',
    });
  }

  Future<void> insertTracksRow({
    required String uid,
    bool favorite = false,
  }) async {
    await raw.insert('tracks', {
      'uid': uid,
      'fingerprint': 'fp-$uid',
      'created_at': 0,
      'favorite': favorite ? 1 : 0,
      'play_count': 0,
      'cumulative_ms': 0,
      'last_played_at': null,
    });
  }

  Future<bool> indexedFileExists(String path) async {
    final rows = await raw.query(
      'indexed_files',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> tracksFavorite(String uid) async {
    final rows = await raw.query(
      'tracks',
      columns: ['favorite'],
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return ((rows.first['favorite'] as int?) ?? 0) != 0;
  }

  group('DeleteDecision', () {
    test('carries paths, intelUid, clearFavorite verbatim', () {
      const d = DeleteDecision(
        paths: ['/a.mp3', '/b.aiff'],
        intelUid: 'canonical-uid',
        clearFavorite: true,
      );
      expect(d.paths, ['/a.mp3', '/b.aiff']);
      expect(d.intelUid, 'canonical-uid');
      expect(d.clearFavorite, isTrue);
    });
  });

  group('purgeIndexedFiles (delete path)', () {
    test(
      'removes the requested paths, leaves other rows intact, '
      'records one `purged` event per row',
      () async {
        await insertIndexedFile(
          path: '/Z/song.aiff',
          filename: 'song.aiff',
          sourceId: 'src1',
          uid: 'u1',
          intelUid: 'i1',
        );
        await insertIndexedFile(
          path: '/Afro/song.mp3',
          filename: 'song.mp3',
          sourceId: 'src2',
          uid: 'u2',
          intelUid: 'i1',
        );
        await insertTracksRow(uid: 'i1', favorite: true);

        final deleted = await repo.purgeIndexedFiles(['/Z/song.aiff']);
        expect(deleted, 1);
        expect(await indexedFileExists('/Z/song.aiff'), isFalse);
        expect(await indexedFileExists('/Afro/song.mp3'), isTrue,
            reason: 'sibling variant must survive the per-path purge');

        // Intel row keeps the favorite — purge only touches
        // indexed_files. Whether to clear favorite is a separate
        // decision the controller carries via DeleteDecision.
        expect(await tracksFavorite('i1'), isTrue,
            reason: 'tracks row must survive a purge so re-added '
                'files reconnect their favorite/history');

        final events = await repo.loadRecentEvents(
          eventTypes: [EventType.purged],
        );
        expect(events, hasLength(1));
        expect(events.first.path, '/Z/song.aiff');
      },
    );
  });

  group('FAV cascade primitive (clearFavorite=true path)', () {
    test(
      'updateIntelligence(favorite: false) clears the song-level '
      'favorite even when surviving variants still reference the '
      'same intel uid',
      () async {
        // Q variant (about to be deleted) + Z variant (will survive)
        // share an intel uid. This is the popup case: user deletes
        // Q while Z still exists, picks "Remove Favorite".
        await insertIndexedFile(
          path: '/Z/song.aiff',
          filename: 'song.aiff',
          sourceId: 'src1',
          uid: 'u-q',
          intelUid: 'shared-intel',
        );
        await insertIndexedFile(
          path: '/Afro/song.mp3',
          filename: 'song.mp3',
          sourceId: 'src2',
          uid: 'u-z',
          intelUid: 'shared-intel',
        );
        await insertTracksRow(uid: 'shared-intel', favorite: true);

        // Step 1: trash + DB cleanup of the chosen variant.
        await repo.purgeIndexedFiles(['/Z/song.aiff']);
        // Step 2: FAV cascade — same primitive the controller calls.
        await repo.updateIntelligence(
          intelUid: 'shared-intel',
          favorite: false,
        );

        expect(await tracksFavorite('shared-intel'), isFalse,
            reason: 'FAV cascade must land on the intel row '
                'so the surviving variant reflects the new state');
        expect(await indexedFileExists('/Afro/song.mp3'), isTrue,
            reason: 'surviving variant\'s indexed_file row '
                'must not be affected by the FAV clear');
      },
    );

    test(
      'clearFavorite=false (user picked "Keep Favorite") leaves '
      'the intel row\'s favorite intact',
      () async {
        await insertIndexedFile(
          path: '/Z/song.aiff',
          filename: 'song.aiff',
          sourceId: 'src1',
          uid: 'u-q',
          intelUid: 'shared-intel',
        );
        await insertIndexedFile(
          path: '/Afro/song.mp3',
          filename: 'song.mp3',
          sourceId: 'src2',
          uid: 'u-z',
          intelUid: 'shared-intel',
        );
        await insertTracksRow(uid: 'shared-intel', favorite: true);

        // Trash + DB cleanup only. NO favorite write.
        await repo.purgeIndexedFiles(['/Z/song.aiff']);

        expect(await tracksFavorite('shared-intel'), isTrue,
            reason: 'Keep Favorite must preserve the intel row '
                'unchanged so the surviving variant stays starred');
      },
    );

    test(
      'single-variant deletion: tracks row survives even though '
      'no variant remains pointing at it (re-add reconnect)',
      () async {
        // No surviving variant. The dialog wouldn't show the FAV
        // section in this case — favorite has no representation
        // anyway. But the tracks row must STILL persist so a
        // later re-add of the same file reconnects history.
        await insertIndexedFile(
          path: '/Z/orphan.aiff',
          filename: 'orphan.aiff',
          sourceId: 'src1',
          uid: 'u-only',
          intelUid: 'i-only',
        );
        await insertTracksRow(uid: 'i-only', favorite: true);

        await repo.purgeIndexedFiles(['/Z/orphan.aiff']);

        expect(await indexedFileExists('/Z/orphan.aiff'), isFalse);
        // Intel row persists by design — guardrail #5.
        expect(await tracksFavorite('i-only'), isTrue,
            reason: 'tracks row + favorite must survive a no-survivor '
                'delete so re-adding the file restores curation history');
      },
    );
  });
}

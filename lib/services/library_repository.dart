import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/track.dart';
import '../models/watched_folder.dart';
import 'database.dart';

class LibraryRepository {
  final AppDatabase _appDb;

  LibraryRepository(this._appDb);

  Database get _db => _appDb.db;

  Future<List<WatchedFolder>> loadFolders() async {
    final rows = await _db.query('watched_folders', orderBy: 'added_at ASC');
    return rows
        .map(
          (r) => WatchedFolder(
            path: r['path'] as String,
            displayName: r['display_name'] as String,
          ),
        )
        .toList();
  }

  Future<List<Track>> loadTracks() async {
    final rows = await _db.query('tracks');
    return rows.map(_trackFromRow).toList();
  }

  Future<void> insertFolder(WatchedFolder folder) async {
    await _db.insert(
      'watched_folders',
      {
        'path': folder.path,
        'display_name': folder.displayName,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteFolder(String path) async {
    await _db.delete(
      'watched_folders',
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  Future<void> insertTracksBatch(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final t in tracks) {
      batch.insert(
        'tracks',
        {
          'path': t.id,
          'folder_path': t.folderPath,
          'title': t.title,
          'artist': t.artist,
          'album': '',
          'duration_ms': t.duration.inMilliseconds,
          'favorite': t.favorite ? 1 : 0,
          'cumulative_ms': t.cumulativeListened.inMilliseconds,
          'play_count': t.playCount,
          'first_seen_at': now,
          'last_played_at': null,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateTrackState(Track t) async {
    await _db.update(
      'tracks',
      {
        'favorite': t.favorite ? 1 : 0,
        'cumulative_ms': t.cumulativeListened.inMilliseconds,
        'play_count': t.playCount,
        'duration_ms': t.duration.inMilliseconds,
      },
      where: 'path = ?',
      whereArgs: [t.id],
    );
  }

  Future<void> markPlayed(String trackId) async {
    await _db.update(
      'tracks',
      {'last_played_at': DateTime.now().millisecondsSinceEpoch},
      where: 'path = ?',
      whereArgs: [trackId],
    );
  }
}

Track _trackFromRow(Map<String, Object?> r) {
  return Track(
    id: r['path'] as String,
    title: r['title'] as String,
    artist: (r['artist'] as String?) ?? '',
    folderPath: r['folder_path'] as String,
    duration: Duration(milliseconds: (r['duration_ms'] as int?) ?? 0),
    favorite: (r['favorite'] as int? ?? 0) != 0,
    cumulativeListened: Duration(
      milliseconds: (r['cumulative_ms'] as int?) ?? 0,
    ),
    playCount: (r['play_count'] as int?) ?? 0,
  );
}

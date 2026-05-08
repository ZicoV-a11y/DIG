import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/track.dart';
import '../models/watched_folder.dart';
import 'database.dart';
import 'metadata_extractor.dart';

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
          'album': t.album,
          'genre': t.genre,
          'musical_key': t.musicalKey,
          'bpm': t.bpm,
          'duration_ms': t.duration.inMilliseconds,
          'has_artwork': t.hasArtwork ? 1 : 0,
          'favorite': t.favorite ? 1 : 0,
          'cumulative_ms': t.cumulativeListened.inMilliseconds,
          'play_count': t.playCount,
          'first_seen_at': now,
          'last_played_at': null,
          'metadata_read_at': t.metadataReadAt?.millisecondsSinceEpoch ?? 0,
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

  Future<Map<String, String>> loadSettings() async {
    final rows = await _db.query('app_settings');
    return {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateMetadataBatch(List<TrackMetadata> items) async {
    if (items.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final m in items) {
      // Don't stamp metadata_read_at if extraction failed —
      // failed reads should retry on next launch.
      if (!m.readSucceeded) continue;
      final values = <String, Object?>{
        'has_artwork': m.hasArtwork ? 1 : 0,
        'metadata_read_at': now,
      };
      if (m.title != null) values['title'] = m.title;
      if (m.artist != null) values['artist'] = m.artist;
      if (m.album != null) values['album'] = m.album;
      if (m.genre != null) values['genre'] = m.genre;
      if (m.musicalKey != null) values['musical_key'] = m.musicalKey;
      if (m.bpm != null) values['bpm'] = m.bpm;
      if (m.duration != null && m.duration! > Duration.zero) {
        values['duration_ms'] = m.duration!.inMilliseconds;
      }
      batch.update(
        'tracks',
        values,
        where: 'path = ?',
        whereArgs: [m.path],
      );
    }
    await batch.commit(noResult: true);
  }
}

Track _trackFromRow(Map<String, Object?> r) {
  final readAt = r['metadata_read_at'] as int?;
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
    album: (r['album'] as String?) ?? '',
    genre: (r['genre'] as String?) ?? '',
    musicalKey: (r['musical_key'] as String?) ?? '',
    bpm: (r['bpm'] as num?)?.toDouble(),
    hasArtwork: (r['has_artwork'] as int? ?? 0) != 0,
    metadataReadAt: (readAt == null || readAt == 0)
        ? null
        : DateTime.fromMillisecondsSinceEpoch(readAt),
  );
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'track_uid.dart';

class AppDatabase {
  // v5 introduced the lightweight-index + lazy-intelligence model.
  // v6 adds `tracks.fingerprint` so cross-machine import + ghost-row
  // reconnect can find intelligence by musical-equivalence even when
  // the imported uid (which includes mtime) differs from anything
  // local.
  // v7 adds `sources.parent_source_id` + `sources.path_prefix` so a
  // folder picked inside an already-watched source becomes a virtual
  // "sub-view" instead of a duplicate scanning source.
  static const _schemaVersion = 7;

  late final Database _db;

  Database get db => _db;

  Future<void> open() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final dir = await getApplicationSupportDirectory();
    final dbPath = '${dir.path}/music_tracker.db';
    await _migrateFromSandboxedContainer(dbPath);
    _db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _migrateFromSandboxedContainer(String newPath) async {
    if (File(newPath).existsSync()) return;
    final home = Platform.environment['HOME'];
    if (home == null) return;
    final oldPath =
        '$home/Library/Containers/com.example.musicTracker/Data/Library/Application Support/com.example.musicTracker/music_tracker.db';
    final oldFile = File(oldPath);
    if (!oldFile.existsSync()) return;
    try {
      await Directory(newPath).parent.create(recursive: true);
      await oldFile.copy(newPath);
      debugPrint('[db] migrated DB from sandboxed container → $newPath');
    } catch (e) {
      debugPrint('[db] sandboxed DB migration failed: $e');
    }
  }

  Future<void> openInMemory() async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfiNoIsolate;
    _db = await factory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> close() => _db.close();

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    _createV5Schema(batch);
    batch.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await batch.commit(noResult: true);
  }

  static void _createV5Schema(Batch batch) {
    batch.execute('''
      CREATE TABLE sources (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        scan_mode TEXT NOT NULL DEFAULT 'recursive',
        enabled INTEGER NOT NULL DEFAULT 1,
        last_scan_at INTEGER,
        track_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        parent_source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,
        path_prefix TEXT
      )
    ''');
    batch.execute('CREATE INDEX idx_sources_path ON sources(folder_path)');
    batch.execute(
      'CREATE INDEX idx_sources_parent ON sources(parent_source_id)',
    );

    batch.execute('''
      CREATE TABLE indexed_files (
        path TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        filesize INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        fingerprint TEXT NOT NULL,
        uid TEXT NOT NULL,
        intel_uid TEXT,
        is_available INTEGER NOT NULL DEFAULT 1,
        last_seen_at INTEGER NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        genre TEXT NOT NULL DEFAULT '',
        musical_key TEXT NOT NULL DEFAULT '',
        bpm REAL,
        has_artwork INTEGER NOT NULL DEFAULT 0,
        metadata_read_at INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_idx_fingerprint ON indexed_files(fingerprint)');
    batch.execute('CREATE INDEX idx_idx_uid ON indexed_files(uid)');
    batch.execute('CREATE INDEX idx_idx_intel ON indexed_files(intel_uid)');
    batch.execute('CREATE INDEX idx_idx_source ON indexed_files(source_id)');
    batch.execute('CREATE INDEX idx_idx_avail ON indexed_files(is_available)');
    batch.execute('CREATE INDEX idx_idx_meta_read ON indexed_files(metadata_read_at)');

    // tracks has NO foreign key — source removal must never delete
    // intelligence rows (guardrail 5: "source removal never destroys
    // user work"). `fingerprint` (file-content equivalence) is
    // duplicated here so import + ghost-reconnect can locate rows
    // without joining to indexed_files (which may not yet exist on a
    // fresh import target).
    batch.execute('''
      CREATE TABLE tracks (
        uid TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        favorite INTEGER NOT NULL DEFAULT 0,
        play_count INTEGER NOT NULL DEFAULT 0,
        cumulative_ms INTEGER NOT NULL DEFAULT 0,
        last_played_at INTEGER
      )
    ''');
    batch.execute('CREATE INDEX idx_tracks_fingerprint ON tracks(fingerprint)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Pre-v5 cumulative migrations carried forward unchanged.
    if (oldVersion < 2) {
      final batch = db.batch();
      batch.execute('ALTER TABLE tracks ADD COLUMN genre TEXT NOT NULL DEFAULT \'\'');
      batch.execute('ALTER TABLE tracks ADD COLUMN musical_key TEXT NOT NULL DEFAULT \'\'');
      batch.execute('ALTER TABLE tracks ADD COLUMN bpm REAL');
      batch.execute('ALTER TABLE tracks ADD COLUMN has_artwork INTEGER NOT NULL DEFAULT 0');
      batch.execute('ALTER TABLE tracks ADD COLUMN metadata_read_at INTEGER NOT NULL DEFAULT 0');
      batch.execute(
        'CREATE INDEX IF NOT EXISTS idx_tracks_metadata_read ON tracks(metadata_read_at)',
      );
      await batch.commit(noResult: true);
    }
    if (oldVersion < 3) {
      await db.execute('UPDATE tracks SET metadata_read_at = 0');
    }
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      await _migrateV4toV5(db);
    }
    if (oldVersion < 6) {
      await _migrateV5toV6(db);
    }
    if (oldVersion < 7) {
      await _migrateV6toV7(db);
    }
  }

  /// Add sub-view columns to `sources`. Purely additive; existing
  /// rows become top-level sources by default (NULL parent / prefix).
  static Future<void> _migrateV6toV7(Database db) async {
    debugPrint('[db] starting v6 → v7 migration (sub-view columns)');
    final stopwatch = Stopwatch()..start();
    await db.execute(
      'ALTER TABLE sources ADD COLUMN parent_source_id TEXT '
      'REFERENCES sources(id) ON DELETE CASCADE',
    );
    await db.execute(
      'ALTER TABLE sources ADD COLUMN path_prefix TEXT',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sources_parent '
      'ON sources(parent_source_id)',
    );
    debugPrint(
      '[db] v6 → v7 done in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  /// Add `tracks.fingerprint` and backfill it from the linked
  /// `indexed_files` row(s). Purely additive; the v5 schema's tracks
  /// table is mutated in place (no rename-and-rebuild needed).
  static Future<void> _migrateV5toV6(Database db) async {
    debugPrint('[db] starting v5 → v6 migration (add tracks.fingerprint)');
    final stopwatch = Stopwatch()..start();
    await db.execute(
      "ALTER TABLE tracks ADD COLUMN fingerprint TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_fingerprint '
      'ON tracks(fingerprint)',
    );
    // Backfill: for each tracks row, take the fingerprint from any
    // indexed_files row whose intel_uid points at it. (There may be
    // multiple siblings with the same fingerprint — they're all
    // equivalent for backfill purposes.)
    final updated = await db.rawUpdate('''
      UPDATE tracks
      SET fingerprint = (
        SELECT fingerprint FROM indexed_files
        WHERE indexed_files.intel_uid = tracks.uid
        LIMIT 1
      )
      WHERE fingerprint = ''
    ''');
    debugPrint(
      '[db] v5 → v6 done in ${stopwatch.elapsedMilliseconds}ms '
      '($updated tracks rows backfilled).',
    );
  }

  /// Split the legacy `tracks` table (one row per scanned file with
  /// metadata + intelligence intermingled) into the new model:
  ///
  /// 1. `sources` — generated UUIDs for each old `watched_folders` row.
  /// 2. `indexed_files` — every old row gets one (lightweight). The
  ///    file is stat'd best-effort; missing files become
  ///    `is_available = 0` with `filesize = 0`, `modified_at = 0`.
  /// 3. `tracks` — sparse, only rows whose old data showed evidence of
  ///    user interaction (`play_count > 0` OR `cumulative_ms > 0` OR
  ///    `favorite = 1`).
  ///
  /// Old tables are renamed to `*_v4_backup` and **not dropped**
  /// (guardrail 11: operational trust).
  static Future<void> _migrateV4toV5(Database db) async {
    debugPrint('[db] starting v4 → v5 migration');
    final stopwatch = Stopwatch()..start();

    // Step 1: rename old tables out of the way so the new ones can take
    // their canonical names. `tracks` already exists, so we can't
    // create the new `tracks` until the old one is moved.
    await db.execute('ALTER TABLE tracks RENAME TO tracks_v4_backup');
    await db.execute(
      'ALTER TABLE watched_folders RENAME TO watched_folders_v4_backup',
    );

    // Step 2: build the new schema fresh.
    final createBatch = db.batch();
    _createV5Schema(createBatch);
    await createBatch.commit(noResult: true);

    // Step 3: build sources from old watched_folders.
    final folderRows = await db.query('watched_folders_v4_backup');
    final folderToSourceId = <String, String>{};
    final uuid = const Uuid();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (folderRows.isNotEmpty) {
      final batch = db.batch();
      for (final row in folderRows) {
        final path = row['path'] as String;
        final displayName = row['display_name'] as String;
        final addedAt = (row['added_at'] as int?) ?? now;
        final id = uuid.v4();
        folderToSourceId[path] = id;
        batch.insert('sources', {
          'id': id,
          'display_name': displayName,
          'folder_path': path,
          'scan_mode': 'recursive',
          'enabled': 1,
          'last_scan_at': null,
          'track_count': 0,
          'created_at': addedAt,
        });
      }
      await batch.commit(noResult: true);
    }

    // Step 4: stream old tracks into indexed_files + (selectively)
    // tracks. We do this in one pass per row — it's already O(n) on
    // disk stats, batching DB writes won't change the slowest step.
    final oldTrackRows = await db.query('tracks_v4_backup');
    debugPrint(
      '[db] migrating ${oldTrackRows.length} legacy tracks '
      '(${folderRows.length} sources)',
    );

    var promotedCount = 0;
    var missingCount = 0;
    final fingerprintToIntelUid = <String, String>{};

    final indexBatch = db.batch();
    final tracksBatch = db.batch();

    for (final row in oldTrackRows) {
      final path = row['path'] as String;
      final folderPath = row['folder_path'] as String;
      final sourceId = folderToSourceId[folderPath];
      if (sourceId == null) {
        // Orphan row in legacy data — skip (would have been hidden by
        // the old FK anyway).
        continue;
      }

      final durationMs = (row['duration_ms'] as int?) ?? 0;
      int filesize = 0;
      int modifiedAt = 0;
      bool isAvailable = true;
      try {
        final stat = File(path).statSync();
        filesize = stat.size;
        modifiedAt = stat.modified.millisecondsSinceEpoch;
      } on FileSystemException {
        isAvailable = false;
        missingCount++;
      } catch (_) {
        isAvailable = false;
        missingCount++;
      }

      final ids = computeTrackUid(
        basename: _basenameOf(path),
        filesize: filesize,
        durationMs: durationMs,
        mtimeMs: modifiedAt,
      );

      final favorite = ((row['favorite'] as int?) ?? 0) != 0;
      final cumulativeMs = (row['cumulative_ms'] as int?) ?? 0;
      final playCount = (row['play_count'] as int?) ?? 0;
      final lastPlayedAt = row['last_played_at'] as int?;
      final firstSeenAt = (row['first_seen_at'] as int?) ?? now;

      final hasIntelligence =
          favorite || cumulativeMs > 0 || playCount > 0;

      String? intelUid;
      if (hasIntelligence) {
        // Promote: each first-seen-with-intelligence in a fingerprint
        // cluster owns the tracks row. Subsequent siblings sharing the
        // same fingerprint reuse that intel_uid.
        intelUid = fingerprintToIntelUid[ids.fingerprint];
        if (intelUid == null) {
          intelUid = ids.uid;
          fingerprintToIntelUid[ids.fingerprint] = intelUid;
          tracksBatch.insert('tracks', {
            'uid': intelUid,
            'fingerprint': ids.fingerprint,
            'created_at': firstSeenAt,
            'favorite': favorite ? 1 : 0,
            'play_count': playCount,
            'cumulative_ms': cumulativeMs,
            'last_played_at': lastPlayedAt,
          });
          promotedCount++;
        } else {
          // Merge: prefer the row with stronger interaction. SQLite
          // doesn't support easy upsert merges in a batch, so we'll
          // post-process this minor case in step 5 if needed. For now
          // the existing tracks row stays as-is; this row's data is
          // attached via intel_uid.
        }
      }

      indexBatch.insert('indexed_files', {
        'path': path,
        'source_id': sourceId,
        'filename': _basenameOf(path),
        'filesize': filesize,
        'modified_at': modifiedAt,
        'duration_ms': durationMs,
        'fingerprint': ids.fingerprint,
        'uid': ids.uid,
        'intel_uid': intelUid,
        'is_available': isAvailable ? 1 : 0,
        'last_seen_at': now,
        'title': (row['title'] as String?) ?? _basenameOf(path),
        'artist': (row['artist'] as String?) ?? '',
        'album': (row['album'] as String?) ?? '',
        'genre': (row['genre'] as String?) ?? '',
        'musical_key': (row['musical_key'] as String?) ?? '',
        'bpm': row['bpm'],
        'has_artwork': ((row['has_artwork'] as int?) ?? 0),
        'metadata_read_at': ((row['metadata_read_at'] as int?) ?? 0),
      });
    }

    await tracksBatch.commit(noResult: true);
    await indexBatch.commit(noResult: true);

    // Step 5: refresh source.track_count to reflect indexed_files.
    if (folderToSourceId.isNotEmpty) {
      for (final sid in folderToSourceId.values) {
        final countRow = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM indexed_files WHERE source_id = ?',
          [sid],
        );
        final count = (countRow.first['c'] as int?) ?? 0;
        await db.update(
          'sources',
          {'track_count': count},
          where: 'id = ?',
          whereArgs: [sid],
        );
      }
    }

    debugPrint(
      '[db] v4 → v5 done in ${stopwatch.elapsedMilliseconds}ms '
      '(indexed=${oldTrackRows.length}, promoted=$promotedCount, missing=$missingCount, '
      'sources=${folderToSourceId.length}). '
      'Old tables preserved as tracks_v4_backup / watched_folders_v4_backup.',
    );
  }
}

String _basenameOf(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  return sep < 0 ? path : path.substring(sep + 1);
}

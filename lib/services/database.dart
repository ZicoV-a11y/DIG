import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AppDatabase {
  static const _schemaVersion = 4;

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
    batch.execute('''
      CREATE TABLE watched_folders (
        path TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        added_at INTEGER NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE tracks (
        path TEXT PRIMARY KEY,
        folder_path TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        genre TEXT NOT NULL DEFAULT '',
        musical_key TEXT NOT NULL DEFAULT '',
        bpm REAL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        has_artwork INTEGER NOT NULL DEFAULT 0,
        favorite INTEGER NOT NULL DEFAULT 0,
        cumulative_ms INTEGER NOT NULL DEFAULT 0,
        play_count INTEGER NOT NULL DEFAULT 0,
        first_seen_at INTEGER NOT NULL,
        last_played_at INTEGER,
        metadata_read_at INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (folder_path) REFERENCES watched_folders(path) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_tracks_folder ON tracks(folder_path)');
    batch.execute(
      'CREATE INDEX idx_tracks_metadata_read ON tracks(metadata_read_at)',
    );
    batch.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
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
      // Recover from a v2 bug that stamped metadata_read_at for tracks whose
      // extraction silently failed. Reset every track so they re-enter the
      // metadata queue on next hydrate.
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
  }
}

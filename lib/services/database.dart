import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AppDatabase {
  static const _schemaVersion = 1;

  late final Database _db;

  Database get db => _db;

  Future<void> open() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final dir = await getApplicationSupportDirectory();
    final dbPath = '${dir.path}/music_tracker.db';
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
        duration_ms INTEGER NOT NULL DEFAULT 0,
        favorite INTEGER NOT NULL DEFAULT 0,
        cumulative_ms INTEGER NOT NULL DEFAULT 0,
        play_count INTEGER NOT NULL DEFAULT 0,
        first_seen_at INTEGER NOT NULL,
        last_played_at INTEGER,
        FOREIGN KEY (folder_path) REFERENCES watched_folders(path) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_tracks_folder ON tracks(folder_path)');
    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // future schema migrations land here
  }
}

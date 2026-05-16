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
  static const _schemaVersion = 14;

  late final Database _db;

  Database get db => _db;

  /// Open the database at [dbPath]. The caller is responsible for
  /// ensuring the parent directory exists and for handling any
  /// LibraryRoot-level migration (copy-first auto-migrate from the
  /// legacy Application Support location lives in `main.dart`, not
  /// here — keeps this class focused on schema concerns only).
  ///
  /// When [dbPath] is omitted, falls back to the legacy
  /// Application Support location so tests and one-off tools keep
  /// working. Production startup always passes a path.
  Future<void> open({String? dbPath}) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    String path;
    if (dbPath != null) {
      path = dbPath;
    } else {
      final dir = await getApplicationSupportDirectory();
      path = '${dir.path}/music_tracker.db';
    }
    await _migrateFromSandboxedContainer(path);
    await Directory(path).parent.create(recursive: true);
    _db = await databaseFactory.openDatabase(
      path,
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
        content_hash TEXT,
        uid TEXT NOT NULL,
        intel_uid TEXT,
        identity_override TEXT,
        is_available INTEGER NOT NULL DEFAULT 1,
        availability_state TEXT NOT NULL DEFAULT 'available',
        last_seen_at INTEGER NOT NULL,
        first_seen_at INTEGER NOT NULL DEFAULT 0,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        genre TEXT NOT NULL DEFAULT '',
        musical_key TEXT NOT NULL DEFAULT '',
        bpm REAL,
        has_artwork INTEGER NOT NULL DEFAULT 0,
        metadata_read_at INTEGER NOT NULL DEFAULT 0,
        enrichment_state TEXT NOT NULL DEFAULT 'discovered',
        FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_idx_fingerprint ON indexed_files(fingerprint)');
    batch.execute('CREATE INDEX idx_idx_content_hash ON indexed_files(content_hash)');
    batch.execute('CREATE INDEX idx_idx_uid ON indexed_files(uid)');
    batch.execute('CREATE INDEX idx_idx_intel ON indexed_files(intel_uid)');
    batch.execute('CREATE INDEX idx_idx_source ON indexed_files(source_id)');
    batch.execute('CREATE INDEX idx_idx_avail ON indexed_files(is_available)');
    batch.execute('CREATE INDEX idx_idx_meta_read ON indexed_files(metadata_read_at)');
    batch.execute(
      'CREATE INDEX idx_idx_enrichment_state ON indexed_files(enrichment_state)',
    );

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

    // Append-only activity log. Every lifecycle decision the
    // system makes (mark missing, auto-supersede, purge, manual
    // relink, etc.) records a row here, so the UI can narrate
    // *why* a track ended up in its current state. Cross-cutting
    // concern — not its own domain layer, just the readout
    // surface over the file-lifecycle + identity layers.
    //
    // event_type is a stable string constant; payload is
    // type-specific JSON so we can extend without schema churn.
    batch.execute('''
      CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recorded_at INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        path TEXT,
        source_id TEXT,
        payload TEXT
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_events_recorded_at ON events(recorded_at)',
    );
    batch.execute('CREATE INDEX idx_events_type ON events(event_type)');
    batch.execute('CREATE INDEX idx_events_path ON events(path)');
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
    if (oldVersion < 8) {
      await _migrateV7toV8(db);
    }
    if (oldVersion < 9) {
      await _migrateV8toV9(db);
    }
    if (oldVersion < 10) {
      await _migrateV9toV10(db);
    }
    if (oldVersion < 11) {
      await _migrateV10toV11(db);
    }
    if (oldVersion < 12) {
      await _migrateV11toV12(db);
    }
    if (oldVersion < 13) {
      await _migrateV12toV13(db);
    }
    if (oldVersion < 14) {
      await _migrateV13toV14(db);
    }
  }

  /// Add `indexed_files.enrichment_state` — the formal lifecycle
  /// column for the metadata pipeline. Replaces the implicit "is
  /// `metadata_read_at` zero?" check with explicit states so the
  /// UI can distinguish "never tried" from "tried and failed" and
  /// the ontology can grow (deferred, blocked-on-cloud) without
  /// schema churn.
  ///
  /// Backfill rule:
  ///   - `metadata_read_at > 0`  → `ready`  (tags landed previously)
  ///   - `metadata_read_at = 0`  → `discovered` (default)
  ///
  /// We do NOT carry forward any "enriching" state across the
  /// migration — at boot the in-memory enrichment queue is empty,
  /// so any pre-migration in-flight work would have been
  /// effectively cancelled by the previous shutdown. Treating
  /// those rows as `discovered` lets the regular enrichment pass
  /// pick them up cleanly.
  ///
  /// Idempotent — safe to retry after a partial migration.
  static Future<void> _migrateV13toV14(Database db) async {
    debugPrint(
      '[db] starting v13 → v14 migration (indexed_files.enrichment_state)',
    );
    final stopwatch = Stopwatch()..start();

    final columns = await db.rawQuery('PRAGMA table_info(indexed_files)');
    final hasColumn =
        columns.any((c) => c['name'] == 'enrichment_state');
    if (!hasColumn) {
      await db.execute(
        "ALTER TABLE indexed_files "
        "ADD COLUMN enrichment_state TEXT NOT NULL DEFAULT 'discovered'",
      );
    }
    // Index is cheap, idempotent, and turns the boot-time "find
    // every row not yet ready" sweep from a full table scan into
    // an index range read.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_idx_enrichment_state '
      'ON indexed_files(enrichment_state)',
    );
    final backfilled = await db.rawUpdate(
      "UPDATE indexed_files "
      "SET enrichment_state = 'ready' "
      "WHERE metadata_read_at > 0 "
      "  AND enrichment_state = 'discovered'",
    );

    debugPrint(
      '[db] v13 → v14 done in ${stopwatch.elapsedMilliseconds}ms '
      '($backfilled rows backfilled to ready).',
    );
  }

  /// Add `indexed_files.first_seen_at` — the temporal anchor for
  /// every File Instance. Records when the row was first observed
  /// at its current path. Future supersession (Phase 2) uses this
  /// for the temporal-after check: a successor's `first_seen_at`
  /// must be ≥ the missing row's `last_seen_at` for an auto-
  /// supersession decision to be safe.
  ///
  /// This slice ships the column only. No behavioral consumer
  /// lands until Phase 2 — keeping the temporal infrastructure
  /// stable in isolation, debuggable independently from
  /// supersession heuristics.
  ///
  /// Idempotent — safe to retry after a partial migration.
  /// Backfill rule: pre-existing rows have `first_seen_at = 0`
  /// from the default; we bring them forward to `last_seen_at`
  /// as a conservative "we don't know any earlier than the last
  /// observation." This is intentionally weak — the temporal-
  /// after check will tighten naturally as new INSERT-time
  /// values accumulate over real-world use.
  static Future<void> _migrateV12toV13(Database db) async {
    debugPrint(
      '[db] starting v12 → v13 migration (indexed_files.first_seen_at)',
    );
    final stopwatch = Stopwatch()..start();

    final columns = await db.rawQuery('PRAGMA table_info(indexed_files)');
    final hasColumn =
        columns.any((c) => c['name'] == 'first_seen_at');
    if (!hasColumn) {
      await db.execute(
        'ALTER TABLE indexed_files '
        'ADD COLUMN first_seen_at INTEGER NOT NULL DEFAULT 0',
      );
    }
    final backfilled = await db.rawUpdate(
      'UPDATE indexed_files '
      'SET first_seen_at = last_seen_at '
      'WHERE first_seen_at = 0',
    );

    debugPrint(
      '[db] v12 → v13 done in ${stopwatch.elapsedMilliseconds}ms '
      '($backfilled rows backfilled).',
    );
  }

  /// Data-only migration: dedupe `indexed_files.uid` collisions
  /// caused by the pre-fix `copyTrackFile` implementation.
  ///
  /// Before the fix, app-initiated Copy used Dart's `File.copySync`
  /// which on macOS preserves the source's mtime via `copyfile`.
  /// Because `computeTrackUid` hashes mtime, the destination row
  /// ended up with the SAME uid as the source. That broke
  /// `LibraryController._trackByUid` (a `Map<String, Track>` — two
  /// rows racing for one slot), and click-to-play on the visible
  /// row would dispatch to whichever Track instance was inserted
  /// last by `loadTracks`, often the wrong path.
  ///
  /// The implementation fix (set mtime to `DateTime.now()` after
  /// copySync) prevents NEW collisions. This migration cleans up
  /// any rows already in the DB carrying a duplicate uid: for
  /// each cluster sharing a uid, the rows in 'superseded' or
  /// 'missing' state get a `_dup<rowid>` suffix appended so each
  /// row has a unique uid. The 'available' row keeps the original
  /// uid — that's the one playback should resolve to.
  ///
  /// No row data is lost; just uids on non-available rows are
  /// disambiguated. The Review-removed-&-moved dialog still
  /// surfaces those rows; their intel_uid still points at the
  /// shared song's tracks row.
  ///
  /// Idempotent — re-running it on a DB with no collisions is a
  /// no-op (the WHERE clause filters to uids appearing more than
  /// once).
  static Future<void> _migrateV11toV12(Database db) async {
    debugPrint('[db] starting v11 → v12 migration (uid collision dedupe)');
    final stopwatch = Stopwatch()..start();
    final affected = await db.rawUpdate('''
      UPDATE indexed_files
      SET uid = uid || '_dup' || rowid
      WHERE availability_state IN ('superseded', 'missing')
        AND uid IN (
          SELECT uid FROM indexed_files
          GROUP BY uid
          HAVING COUNT(*) > 1
        )
    ''');
    debugPrint(
      '[db] v11 → v12 done in ${stopwatch.elapsedMilliseconds}ms '
      '($affected uid collision(s) deduped).',
    );
  }

  /// Add the `events` activity log. Append-only audit table —
  /// every lifecycle decision the system makes (mark missing,
  /// auto-supersede, purge, etc.) records here so the user
  /// can see *why* a row ended up in its current state.
  ///
  /// Idempotent — safe to retry after a partial migration.
  static Future<void> _migrateV10toV11(Database db) async {
    debugPrint('[db] starting v10 → v11 migration (events activity log)');
    final stopwatch = Stopwatch()..start();
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'events'",
    );
    if (tables.isEmpty) {
      await db.execute('''
        CREATE TABLE events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          recorded_at INTEGER NOT NULL,
          event_type TEXT NOT NULL,
          path TEXT,
          source_id TEXT,
          payload TEXT
        )
      ''');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_recorded_at '
      'ON events(recorded_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_path ON events(path)',
    );
    debugPrint(
      '[db] v10 → v11 done in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  /// Add `indexed_files.content_hash` (nullable TEXT) + an index on
  /// the column. content_hash is true physical-file identity — sha256
  /// of the first 256KB plus the last 256KB of audio bytes. Survives
  /// rename / Cmd+D / folder move; distinguishes re-encodes /
  /// transcodes / different masters.
  ///
  /// Migration adds the column only; existing rows are left with
  /// `content_hash = NULL`. They are filled in two ways post-migration:
  ///   1. Any rescan touches them (filesize/mtime change → recompute,
  ///      filesize/mtime unchanged + null → backfill on next upsert).
  ///   2. A background backfill worker (Slice 3) trickles through
  ///      every NULL row at idle time.
  ///
  /// content_hash is NOT yet consumed by any state-mutation path in
  /// this slice; Slice 5 swaps cross-source supersession over from
  /// fingerprint → content_hash once enough rows are populated for
  /// the swap to be safe.
  ///
  /// Idempotent — safe to retry after a partial migration.
  static Future<void> _migrateV9toV10(Database db) async {
    debugPrint(
      '[db] starting v9 → v10 migration (indexed_files.content_hash)',
    );
    final stopwatch = Stopwatch()..start();
    final columns = await db.rawQuery('PRAGMA table_info(indexed_files)');
    final hasContentHash =
        columns.any((c) => c['name'] == 'content_hash');
    if (!hasContentHash) {
      await db.execute(
        'ALTER TABLE indexed_files ADD COLUMN content_hash TEXT',
      );
    }
    // Index creation is also idempotent via IF NOT EXISTS.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_idx_content_hash '
      'ON indexed_files(content_hash)',
    );
    debugPrint(
      '[db] v9 → v10 done in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  /// Add `indexed_files.availability_state` (TEXT) — a finer-grained
  /// availability state machine than the boolean `is_available`.
  /// Values: 'available' (file on disk), 'missing' (was indexed, gone
  /// from disk, no successor known), 'superseded' (auto-detected as
  /// moved — another row in the same source shares the fingerprint
  /// and is available). Existing rows are backfilled: `is_available=0`
  /// becomes 'missing', everything else 'available'.
  /// Idempotent — safe to retry after a partial migration.
  static Future<void> _migrateV8toV9(Database db) async {
    debugPrint(
      '[db] starting v8 → v9 migration (indexed_files.availability_state)',
    );
    final stopwatch = Stopwatch()..start();
    final columns = await db.rawQuery('PRAGMA table_info(indexed_files)');
    final hasState =
        columns.any((c) => c['name'] == 'availability_state');
    if (!hasState) {
      await db.execute(
        "ALTER TABLE indexed_files ADD COLUMN availability_state TEXT "
        "NOT NULL DEFAULT 'available'",
      );
      // Backfill missing state from the legacy boolean.
      await db.rawUpdate(
        "UPDATE indexed_files SET availability_state = 'missing' "
        "WHERE is_available = 0",
      );
    }
    debugPrint(
      '[db] v8 → v9 done in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  /// Add `indexed_files.identity_override` — a nullable user-set
  /// string that overrides the computed song-identity key. Lets the
  /// user manually pair two files the strict 4-field matcher missed
  /// (renamed-between-encodes, tag drift, etc). Idempotent so a
  /// retry after an interrupted migration is safe.
  static Future<void> _migrateV7toV8(Database db) async {
    debugPrint(
      '[db] starting v7 → v8 migration (indexed_files.identity_override)',
    );
    final stopwatch = Stopwatch()..start();
    final columns = await db.rawQuery('PRAGMA table_info(indexed_files)');
    final hasOverride =
        columns.any((c) => c['name'] == 'identity_override');
    if (!hasOverride) {
      await db.execute(
        'ALTER TABLE indexed_files ADD COLUMN identity_override TEXT',
      );
    }
    debugPrint(
      '[db] v7 → v8 done in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  /// Add sub-view columns to `sources`. Purely additive; existing
  /// rows become top-level sources by default (NULL parent / prefix).
  static Future<void> _migrateV6toV7(Database db) async {
    debugPrint('[db] starting v6 → v7 migration (sub-view columns)');
    final stopwatch = Stopwatch()..start();
    final columns = await db.rawQuery('PRAGMA table_info(sources)');
    final names = columns.map((c) => c['name']).toSet();
    if (!names.contains('parent_source_id')) {
      await db.execute(
        'ALTER TABLE sources ADD COLUMN parent_source_id TEXT '
        'REFERENCES sources(id) ON DELETE CASCADE',
      );
    }
    if (!names.contains('path_prefix')) {
      await db.execute(
        'ALTER TABLE sources ADD COLUMN path_prefix TEXT',
      );
    }
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
    final columns = await db.rawQuery('PRAGMA table_info(tracks)');
    final hasFingerprint = columns.any((c) => c['name'] == 'fingerprint');
    if (!hasFingerprint) {
      await db.execute(
        "ALTER TABLE tracks ADD COLUMN fingerprint TEXT NOT NULL DEFAULT ''",
      );
    }
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

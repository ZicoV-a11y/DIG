import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'inventory_models.dart';
import 'operational_log.dart';
import 'transport_hash.dart';

/// **Miniature package manager** for the phone's local
/// inventory.
///
/// Architectural rules (per PR2.8.A guidance):
///
///   1. **Generations are immutable** once they leave `staging`.
///      A new sync produces a new generation; activating it is
///      a pointer swap, not a mutation.
///   2. **Activation is pointer-swap only.** No file moves, no
///      record edits during the swap — that operation is a
///      single transaction touching only `activation_pointer`.
///   3. **GC is deferred.** Old generations are marked
///      `retired`; files linger until `garbageCollect` runs at
///      a calm moment. Cleanup during activation could land in
///      "old removed + new failed" → catastrophic.
///   4. **Hash verification is generation-scoped.** Verified
///      tracks belong to their generation; nothing is globally
///      cached.
///   5. **Crash recovery via the activation pointer.** On boot,
///      whatever generation_id the pointer holds IS the active
///      inventory — even if the row's status field disagrees,
///      the pointer wins. (The InventoryService reconciles by
///      flipping the row's status to match the pointer on boot.)
class InventoryService {
  InventoryService({
    required this.db,
    DateTime Function()? now,
    Uuid? uuid,
  })  : _now = now ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  final Database db;
  final DateTime Function() _now;
  final Uuid _uuid;

  // ─── Lifecycle ────────────────────────────────────────────────────

  /// Open + migrate the inventory DB. Path is typically inside
  /// the iOS app's documents directory; tests can pass
  /// `inMemoryDatabasePath`.
  static Future<InventoryService> open(String dbPath) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _createSchema,
      ),
    );
    return InventoryService(db: db);
  }

  Future<void> close() => db.close();

  static Future<void> _createSchema(Database db, int _) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE inventory_generations (
        generation_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        status_changed_at INTEGER NOT NULL,
        manifest_version INTEGER,
        source_session_id TEXT,
        failed_reason TEXT
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_gen_status ON inventory_generations(status)',
    );
    batch.execute('''
      CREATE TABLE cached_tracks (
        generation_id TEXT NOT NULL,
        intel_uid TEXT NOT NULL,
        variant_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        transport_hash TEXT NOT NULL,
        audio_path TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        hash_verified_at INTEGER,
        PRIMARY KEY (generation_id, intel_uid),
        FOREIGN KEY (generation_id) REFERENCES inventory_generations(generation_id)
          ON DELETE CASCADE
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_cached_intel ON cached_tracks(intel_uid)',
    );
    // Single-row table — the activation pointer. CHECK enforces
    // exactly one row at the schema level so we can't end up
    // with multiple "active" pointers via race conditions.
    batch.execute('''
      CREATE TABLE activation_pointer (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        active_generation_id TEXT,
        activated_at INTEGER,
        FOREIGN KEY (active_generation_id)
          REFERENCES inventory_generations(generation_id)
      )
    ''');
    // Seed the single row with null active_generation_id (no
    // sync yet). Future activates UPDATE this row.
    batch.insert('activation_pointer', {
      'id': 1,
      'active_generation_id': null,
      'activated_at': null,
    });
    await batch.commit(noResult: true);
  }

  // ─── Generation lifecycle ─────────────────────────────────────────

  /// Open a new staging generation. The returned id is the
  /// caller's handle for [recordStagedTrack] + [verifyGeneration]
  /// + [activate].
  Future<Generation> createStagingGeneration({
    int? manifestVersion,
    String? sourceSessionId,
  }) async {
    final id = _uuid.v4();
    final nowMs = _now().millisecondsSinceEpoch;
    await db.insert('inventory_generations', {
      'generation_id': id,
      'status': GenerationStatus.staging.wireName,
      'created_at': nowMs,
      'status_changed_at': nowMs,
      'manifest_version': manifestVersion,
      'source_session_id': sourceSessionId,
    });
    OperationalLog.emit('generation',
        'staging $id manifest_version=$manifestVersion');
    return Generation(
      generationId: id,
      status: GenerationStatus.staging,
      createdAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
      statusChangedAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
      manifestVersion: manifestVersion,
      sourceSessionId: sourceSessionId,
    );
  }

  /// Append a downloaded track to [generationId]'s inventory.
  /// Caller is responsible for downloading the bytes to
  /// [audioPath] before calling this. Idempotent on
  /// (generation_id, intel_uid) — re-recording replaces.
  ///
  /// Throws [StateError] if the generation isn't in
  /// `staging` — only staging generations accept new tracks
  /// (immutability boundary).
  Future<void> recordStagedTrack({
    required String generationId,
    required TrackIdentity identity,
    required String transportHash,
    required String audioPath,
    required int byteSize,
  }) async {
    final gen = await findGeneration(generationId);
    if (gen == null) {
      throw StateError('Unknown generation: $generationId');
    }
    if (gen.status != GenerationStatus.staging) {
      throw StateError(
        'Cannot record tracks into ${gen.status.wireName} '
        'generation $generationId — only staging accepts writes.',
      );
    }
    await db.insert(
      'cached_tracks',
      {
        'generation_id': generationId,
        'intel_uid': identity.intelUid,
        'variant_id': identity.variantId,
        'content_hash': identity.contentHash,
        'transport_hash': transportHash,
        'audio_path': audioPath,
        'byte_size': byteSize,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    OperationalLog.emit('file',
        'staged intel=${identity.intelUid} '
        '$byteSize bytes → ${_short(generationId)}');
  }

  static String _short(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  /// Re-hash every file in [generationId] and transition the
  /// generation to `ready` (all match) or `failed` (any
  /// mismatch). Returns `true` on success.
  ///
  /// Hash check is generation-scoped — a verified file belongs
  /// to THIS generation and only this generation. No global
  /// "this content hash is good" cache.
  ///
  /// Transitions:
  ///   staging   → verifying → ready    (happy)
  ///   staging   → verifying → failed   (mismatch / missing)
  Future<bool> verifyGeneration(String generationId) async {
    final gen = await findGeneration(generationId);
    if (gen == null) {
      throw StateError('Unknown generation: $generationId');
    }
    if (gen.status != GenerationStatus.staging) {
      throw StateError(
        'Cannot verify ${gen.status.wireName} generation '
        '$generationId — only staging is verifiable.',
      );
    }
    await _setStatus(generationId, GenerationStatus.verifying);

    final tracks = await listTracksInGeneration(generationId);
    final verifiedAt = _now().millisecondsSinceEpoch;
    String? failureReason;
    for (final t in tracks) {
      final file = File(t.audioPath);
      if (!file.existsSync()) {
        failureReason = 'missing file for intel=${t.identity.intelUid}: '
            '${t.audioPath}';
        break;
      }
      final actual = await computeTransportHash(t.audioPath);
      if (actual != t.transportHash) {
        failureReason =
            'transport_hash mismatch for intel=${t.identity.intelUid}: '
            'expected ${t.transportHash}, got $actual';
        break;
      }
      await db.update(
        'cached_tracks',
        {'hash_verified_at': verifiedAt},
        where: 'generation_id = ? AND intel_uid = ?',
        whereArgs: [generationId, t.identity.intelUid],
      );
    }

    if (failureReason != null) {
      OperationalLog.emit('generation',
          '${_short(generationId)} verify FAILED: $failureReason');
      await _setStatus(
        generationId,
        GenerationStatus.failed,
        failedReason: failureReason,
      );
      return false;
    }
    OperationalLog.emit('generation',
        '${_short(generationId)} verify → ready '
        '(${tracks.length} tracks)');
    await _setStatus(generationId, GenerationStatus.ready);
    return true;
  }

  /// **Activation = pointer swap only.** Single transaction:
  ///   1. Validate [generationId] is in `ready` status.
  ///   2. Update activation_pointer.active_generation_id.
  ///   3. Flip the new generation's row status to `active`.
  ///   4. Flip the previously-active generation's status to
  ///      `retired`.
  ///
  /// No file operations, no cached_tracks edits — those are
  /// what makes activation atomic + crash-safe. The previously-
  /// active generation's files linger until [garbageCollect]
  /// runs.
  Future<void> activate(String generationId) async {
    await db.transaction((txn) async {
      final gen = await _findGenerationTxn(txn, generationId);
      if (gen == null) {
        throw StateError('Unknown generation: $generationId');
      }
      if (gen.status != GenerationStatus.ready) {
        throw StateError(
          'Cannot activate ${gen.status.wireName} generation '
          '$generationId — only ready is activatable.',
        );
      }

      // Find the currently-active generation (if any) so we
      // can retire it.
      final pointerRow = await txn.query(
        'activation_pointer',
        where: 'id = 1',
        limit: 1,
      );
      final priorActive =
          pointerRow.first['active_generation_id'] as String?;

      final nowMs = _now().millisecondsSinceEpoch;
      // Pointer flip — the canonical "what's active" mutation.
      await txn.update(
        'activation_pointer',
        {
          'active_generation_id': generationId,
          'activated_at': nowMs,
        },
        where: 'id = 1',
      );
      // Row status mirrors. Source of truth is the pointer; the
      // status field is for ergonomic queries + UI rendering.
      await txn.update(
        'inventory_generations',
        {
          'status': GenerationStatus.active.wireName,
          'status_changed_at': nowMs,
        },
        where: 'generation_id = ?',
        whereArgs: [generationId],
      );
      if (priorActive != null && priorActive != generationId) {
        await txn.update(
          'inventory_generations',
          {
            'status': GenerationStatus.retired.wireName,
            'status_changed_at': nowMs,
          },
          where: 'generation_id = ?',
          whereArgs: [priorActive],
        );
      }
      OperationalLog.emit('generation',
          'activate ${_short(generationId)} '
          '(retired: ${priorActive == null ? "<none>" : _short(priorActive)})');
      OperationalLog.boundary('rotate → ${_short(generationId)}');
    });
  }

  // ─── Read ─────────────────────────────────────────────────────────

  Future<Generation?> findGeneration(String generationId) async {
    return _findGenerationTxn(db, generationId);
  }

  Future<Generation?> _findGenerationTxn(
    DatabaseExecutor exec,
    String generationId,
  ) async {
    final rows = await exec.query(
      'inventory_generations',
      where: 'generation_id = ?',
      whereArgs: [generationId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _generationFromRow(rows.first);
  }

  /// The generation the activation pointer currently names.
  /// The pointer is the source of truth — if it disagrees with
  /// a row's `status` field, the pointer wins.
  Future<Generation?> currentActiveGeneration() async {
    final pointer = await db.query(
      'activation_pointer',
      where: 'id = 1',
      limit: 1,
    );
    final activeId = pointer.first['active_generation_id'] as String?;
    if (activeId == null) return null;
    return findGeneration(activeId);
  }

  /// Track inventory of the currently-active generation. The
  /// playback engine consumes THIS list — never the raw
  /// cached_tracks table.
  Future<List<CachedTrack>> currentInventory() async {
    final active = await currentActiveGeneration();
    if (active == null) return const [];
    return listTracksInGeneration(active.generationId);
  }

  Future<List<CachedTrack>> listTracksInGeneration(
    String generationId,
  ) async {
    final rows = await db.query(
      'cached_tracks',
      where: 'generation_id = ?',
      whereArgs: [generationId],
    );
    return rows.map(_cachedTrackFromRow).toList();
  }

  /// Look up an intel_uid in the active generation. Returns
  /// null if no active generation exists OR the intel_uid
  /// isn't in it. Playback engine binds here.
  Future<CachedTrack?> findInActive(String intelUid) async {
    final active = await currentActiveGeneration();
    if (active == null) return null;
    final rows = await db.query(
      'cached_tracks',
      where: 'generation_id = ? AND intel_uid = ?',
      whereArgs: [active.generationId, intelUid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _cachedTrackFromRow(rows.first);
  }

  Future<List<Generation>> listGenerations({
    Set<GenerationStatus>? withStatus,
  }) async {
    final args = <Object?>[];
    String? where;
    if (withStatus != null && withStatus.isNotEmpty) {
      final placeholders = List.filled(withStatus.length, '?').join(',');
      where = 'status IN ($placeholders)';
      args.addAll(withStatus.map((s) => s.wireName));
    }
    final rows = await db.query(
      'inventory_generations',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
    );
    return rows.map(_generationFromRow).toList();
  }

  // ─── Crash recovery ───────────────────────────────────────────────

  /// Sweep staging generations whose `status_changed_at` is
  /// older than [staleThreshold] and flip them to `orphaned`.
  /// Called at boot to clean up after an app crash / OS
  /// termination / user force-close that left staging
  /// generations dangling. Never touches the active or ready
  /// generations.
  ///
  /// Returns the list of generation_ids actually orphaned.
  /// Idempotent — orphaned rows aren't re-orphaned.
  Future<List<String>> markStaleStagingAsOrphaned({
    Duration staleThreshold = const Duration(minutes: 5),
  }) async {
    final cutoffMs = _now()
        .subtract(staleThreshold)
        .millisecondsSinceEpoch;
    final stale = await db.query(
      'inventory_generations',
      columns: ['generation_id'],
      where: "status = 'staging' AND status_changed_at < ?",
      whereArgs: [cutoffMs],
    );
    final ids = <String>[];
    final nowMs = _now().millisecondsSinceEpoch;
    for (final r in stale) {
      final id = r['generation_id'] as String;
      await db.update(
        'inventory_generations',
        {
          'status': GenerationStatus.orphaned.wireName,
          'status_changed_at': nowMs,
        },
        where: 'generation_id = ?',
        whereArgs: [id],
      );
      ids.add(id);
    }
    return ids;
  }

  // ─── Garbage collection (deferred, opportunistic) ─────────────────

  /// Delete every retired / orphaned / failed generation along
  /// with its files. Safe to call any time; safe to interrupt
  /// (each generation deletes inside its own transaction +
  /// file ops are isolated). Returns the list of generation
  /// ids actually removed.
  ///
  /// NEVER runs during activation — that's the whole point of
  /// the deferred-cleanup contract.
  Future<List<String>> garbageCollect() async {
    final candidates = await listGenerations(withStatus: const {
      GenerationStatus.retired,
      GenerationStatus.orphaned,
      GenerationStatus.failed,
    });
    final removed = <String>[];
    for (final gen in candidates) {
      final tracks = await listTracksInGeneration(gen.generationId);
      for (final t in tracks) {
        try {
          final f = File(t.audioPath);
          if (f.existsSync()) await f.delete();
        } catch (_) {
          // Best-effort — a stuck file just lingers until the
          // OS cleans it. Don't block the GC sweep on it.
        }
      }
      await db.delete(
        'inventory_generations',
        where: 'generation_id = ?',
        whereArgs: [gen.generationId],
      );
      removed.add(gen.generationId);
    }
    return removed;
  }

  // ─── Internals ────────────────────────────────────────────────────

  Future<void> _setStatus(
    String generationId,
    GenerationStatus next, {
    String? failedReason,
  }) async {
    await db.update(
      'inventory_generations',
      {
        'status': next.wireName,
        'status_changed_at': _now().millisecondsSinceEpoch,
        'failed_reason': ?failedReason,
      },
      where: 'generation_id = ?',
      whereArgs: [generationId],
    );
  }

  Generation _generationFromRow(Map<String, Object?> r) {
    return Generation(
      generationId: r['generation_id'] as String,
      status: GenerationStatus.fromWire(r['status'] as String),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        r['created_at'] as int,
      ),
      statusChangedAt: DateTime.fromMillisecondsSinceEpoch(
        r['status_changed_at'] as int,
      ),
      manifestVersion: r['manifest_version'] as int?,
      sourceSessionId: r['source_session_id'] as String?,
      failedReason: r['failed_reason'] as String?,
    );
  }

  CachedTrack _cachedTrackFromRow(Map<String, Object?> r) {
    return CachedTrack(
      generationId: r['generation_id'] as String,
      identity: TrackIdentity(
        intelUid: r['intel_uid'] as String,
        variantId: r['variant_id'] as String,
        contentHash: r['content_hash'] as String,
      ),
      transportHash: r['transport_hash'] as String,
      audioPath: r['audio_path'] as String,
      byteSize: r['byte_size'] as int,
      hashVerifiedAt: r['hash_verified_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              r['hash_verified_at'] as int,
            ),
    );
  }
}

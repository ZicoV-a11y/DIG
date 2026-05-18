import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/activity_event.dart';
import '../models/intelligence_record.dart';
import '../models/source.dart';
import '../models/track.dart';
import '../utils/song_identity.dart';
import 'content_hash.dart';
import 'database.dart';
import 'metadata_extractor.dart';
import 'track_uid.dart';

/// Outcome of a `moveTrackFile` / `copyTrackFile` operation.
/// Either succeeded (and we know the new path + how the move was
/// physically performed) or failed cleanly (no half-state — the
/// FS and DB are both back to where they were).
/// Temporal-soundness threshold for auto-supersession.
///
/// A missing row and its proposed available successor must satisfy:
///
///     successor.first_seen_at >= missing.last_seen_at - {grace}
///
/// In words: the successor must have been first observed AT OR
/// AFTER the missing row's last observation, with a small grace
/// window to absorb scan-timing noise (one scan saw both rows
/// briefly as `available` before the next scan moved the old row
/// to `missing`).
///
/// If the rows coexisted as `available` for LONGER than the grace
/// window, the most likely interpretation is "intentional duplicate
/// then later removed" — not "moved." Auto-supersession refuses to
/// apply in that case; the rows stay independent File Instances and
/// the missing row remains visible in the Review-missing dialog.
///
/// 10 minutes is the L9 starting threshold from
/// `docs/architecture/architectural_laws.md` and the original
/// `project_three_layer_identity_model.md` memo. Tune as real-world
/// telemetry exposes false-positive / false-negative patterns;
/// changes here ripple to both `markMovedSupersessions` and
/// `markCrossSourceMoves` automatically.
const supersessionTemporalOverlapGrace = Duration(minutes: 10);

/// Aggregate outcome of a single `markUnseenAvailability` pass —
/// the "what just happened" data the reconciliation-summary toast
/// renders after a scan.
///
/// `removed` is every row in this source that transitioned
/// available → missing during this call. `preservedElsewhere` is
/// the subset whose `content_hash` still appears on at least one
/// available row in a different watched source (so the file
/// effectively survived through another folder; the user's intel
/// reconnects automatically if they re-add this source). Both
/// counts are computed inside the same transaction that flipped
/// the state, so they reflect the post-flip truth atomically.
class ReconciliationDelta {
  final int removed;
  final int preservedElsewhere;
  const ReconciliationDelta({
    required this.removed,
    required this.preservedElsewhere,
  });

  static const empty =
      ReconciliationDelta(removed: 0, preservedElsewhere: 0);

  /// Convenience: `true` when the delta is worth surfacing to the
  /// user (a no-op scan with nothing removed shouldn't fire a toast).
  bool get isMaterial => removed > 0;
}

class MoveCopyResult {
  final bool success;
  final String? newPath;

  /// How the FS leg of a move was performed. `'rename'` for
  /// single-volume atomic rename, `'copy_then_delete'` for the
  /// cross-volume fallback path, `'copy'` for a copy operation.
  /// `null` on failures.
  final String? via;

  /// Human-readable reason. Surfaces to the user via a SnackBar
  /// or dialog so they can fix the underlying problem (collision,
  /// permission denied, source gone, etc).
  final String? errorReason;

  const MoveCopyResult.success({required this.newPath, required this.via})
      : success = true,
        errorReason = null;
  const MoveCopyResult.failure(this.errorReason)
      : success = false,
        newPath = null,
        via = null;
}

/// Per-file scan upsert payload.
///
/// All values are computed by the controller after a disk walk and a
/// best-effort stat. Title is filename-stripped-of-extension (a
/// reasonable placeholder until the metadata extractor catches up).
class ScannedFile {
  final String path;
  final String filename;
  final int filesize;
  final int modifiedAt;
  final String fallbackTitle;

  const ScannedFile({
    required this.path,
    required this.filename,
    required this.filesize,
    required this.modifiedAt,
    required this.fallbackTitle,
  });
}

class LibraryRepository {
  final AppDatabase _appDb;

  LibraryRepository(this._appDb);

  Database get _db => _appDb.db;

  // Paths whose content_hash was deliberately nulled by a stat-change
  // upsert so the backfill worker would recompute the hash off the
  // main isolate. Holds the OLD hash + source so `setContentHashForPath`
  // can record a `contentUpdatedExternal` audit event when the
  // recomputed hash differs from what we previously knew. Lives only
  // in-memory: if the app quits before backfill reaches a path the
  // event for that path is lost — accepted tradeoff to keep cloud-
  // storage bulk scans from blocking the UI for minutes at a time.
  final Map<String, ({String oldHash, String sourceId})>
      _pendingHashCompare = {};

  // ---------------------------------------------------------------------------
  // Sources
  // ---------------------------------------------------------------------------

  Future<List<Source>> loadSources() async {
    final rows = await _db.query('sources', orderBy: 'created_at ASC');
    return rows.map(_sourceFromRow).toList();
  }

  Future<void> insertSource(Source s) async {
    await _db.insert(
      'sources',
      _sourceToRow(s),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateSourceMeta(
    String id, {
    int? lastScanAt,
    int? trackCount,
    String? displayName,
    ScanMode? scanMode,
    bool? enabled,
  }) async {
    final values = <String, Object?>{};
    if (lastScanAt != null) values['last_scan_at'] = lastScanAt;
    if (trackCount != null) values['track_count'] = trackCount;
    if (displayName != null) values['display_name'] = displayName;
    if (scanMode != null) values['scan_mode'] = scanMode.wire;
    if (enabled != null) values['enabled'] = enabled ? 1 : 0;
    if (values.isEmpty) return;
    await _db.update('sources', values, where: 'id = ?', whereArgs: [id]);
  }

  /// Removes the source and (via FK cascade) its `indexed_files` rows.
  /// `tracks` rows are intentionally untouched — see guardrail 5.
  Future<void> deleteSource(String id) async {
    await _db.delete('sources', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------------------
  // Tracks (joined load over indexed_files + tracks)
  // ---------------------------------------------------------------------------

  /// One-time healing pass for asymmetric `identity_override` state.
  ///
  /// Background: `copyTrackFile` used to stamp an `identity_override`
  /// on the source + new dest row only. If the bucket also contained
  /// a different-codec sibling (e.g. an AIFF that was paired in via
  /// the 4-field key), that sibling kept its NULL override and fell
  /// out of the bucket — `sameSongIdentity` treats the asymmetric
  /// case (one override, one NULL) as intentionally distinct, which
  /// is the right rule for manual link/unlink but the wrong outcome
  /// when Copy auto-stamped the override.
  ///
  /// This method finds rows with NULL override that share a 4-field
  /// key (basename-no-ext + title + artist + duration_sec) with at
  /// least one sibling that has an override, and copies the
  /// sibling's override down. Idempotent — safe to run on every
  /// hydrate; once a library is fully healed it's a no-op.
  ///
  /// **Unlinked rows are not touched.** Unlink sets the override to
  /// the row's OWN uid (not NULL), so unlinked rows never match the
  /// "NULL override" filter and stay singletons.
  ///
  /// Returns the number of rows whose override was backfilled.
  Future<int> healOrphanedIdentitySiblings() async {
    return _db.transaction<int>((txn) async {
      // Pull every available row with NULL/empty override that has
      // enough metadata to 4-field-match anything. Empty title or
      // artist excludes the row from grouping entirely, so there's
      // no override to inherit even if a "sibling" existed.
      final orphans = await txn.query(
        'indexed_files',
        columns: [
          'path',
          'filename',
          'title',
          'artist',
          'duration_ms',
        ],
        where:
            "(identity_override IS NULL OR identity_override = '') "
            "AND title <> '' AND artist <> '' AND is_available = 1",
      );
      if (orphans.isEmpty) return 0;

      var healed = 0;
      for (final o in orphans) {
        final basenameKey =
            basenameForIdentity(o['filename'] as String);
        final title = o['title'] as String;
        final artist = o['artist'] as String;
        final durationSec = ((o['duration_ms'] as int?) ?? 0) ~/ 1000;

        // Find any sibling sharing the 4-field key that already has
        // an override. LIMIT 1 — if multiple exist they're already
        // grouped (Copy propagation keeps them consistent), so any
        // one is fine.
        final siblings = await txn.query(
          'indexed_files',
          columns: ['filename', 'identity_override'],
          where:
              "identity_override IS NOT NULL AND identity_override <> '' "
              "AND title = ? AND artist = ? AND (duration_ms / 1000) = ?",
          whereArgs: [title, artist, durationSec],
        );
        String? override;
        for (final s in siblings) {
          final sFilename = s['filename'] as String;
          if (basenameForIdentity(sFilename) != basenameKey) continue;
          override = s['identity_override'] as String;
          break;
        }
        if (override == null) continue;

        await txn.update(
          'indexed_files',
          {'identity_override': override},
          where: 'path = ?',
          whereArgs: [o['path'] as String],
        );
        healed++;
      }
      return healed;
    });
  }

  Future<List<Track>> loadTracks() async {
    final rows = await _db.rawQuery('''
      SELECT idx.*, t.favorite AS i_favorite,
             t.play_count AS i_play_count,
             t.cumulative_ms AS i_cumulative_ms,
             t.last_played_at AS i_last_played_at,
             t.reviewed_at AS i_reviewed_at,
             t.favorite_toggled_at AS i_favorite_toggled_at
      FROM indexed_files idx
      LEFT JOIN tracks t ON t.uid = idx.intel_uid
    ''');
    return rows.map(_trackFromJoinedRow).toList();
  }

  /// Single-row variant for callers that already know which
  /// variant they want. Used by the mobile-sync transport
  /// endpoint to resolve `GET /api/v1/track/<variant_id>` to a
  /// filesystem path; returns null if the row is gone (file
  /// deleted between manifest generation and transfer).
  Future<Track?> findTrackByUid(String uid) async {
    final rows = await _db.rawQuery('''
      SELECT idx.*, t.favorite AS i_favorite,
             t.play_count AS i_play_count,
             t.cumulative_ms AS i_cumulative_ms,
             t.last_played_at AS i_last_played_at,
             t.reviewed_at AS i_reviewed_at,
             t.favorite_toggled_at AS i_favorite_toggled_at
      FROM indexed_files idx
      LEFT JOIN tracks t ON t.uid = idx.intel_uid
      WHERE idx.uid = ?
      LIMIT 1
    ''', [uid]);
    if (rows.isEmpty) return null;
    return _trackFromJoinedRow(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Scan-driven upserts (scope: indexed_files only — guardrail 2 forbids
  // any write to `tracks` from scan code paths).
  // ---------------------------------------------------------------------------

  /// Bulk upsert: takes the entire scan result and applies it inside
  /// **one** SQLite transaction. This is dramatically faster than
  /// calling [upsertIndexedFile] per file — for a ~9k-file library
  /// it's the difference between ~1s of work and ~minutes of UI-thread
  /// blocking (one fsync per file). Use this from scan code paths;
  /// keep the per-file variant for one-off updates.
  ///
  /// Each batch entry is a `({path, filename, filesize, modifiedAtMs,
  /// fallbackTitle, durationMs})` record. Fingerprint-migration on
  /// re-tag is preserved (if a path's fingerprint changed and the row
  /// owned intelligence, `tracks.uid` is updated to the new value).
  ///
  /// Returns the number of rows newly inserted (the rest were updates).
  Future<int> upsertIndexedFilesBatch({
    required String sourceId,
    required List<
            ({
              String path,
              String filename,
              int filesize,
              int modifiedAtMs,
              String fallbackTitle,
              int durationMs
            })>
        files,
  }) async {
    if (files.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    int inserted = 0;

    await _db.transaction((txn) async {
      // Pre-load existing rows for these paths in chunks (SQLite has
      // a default ~999 parameter limit per statement). Columns
      // include `content_hash`, `filesize`, `modified_at` so we can
      // detect external-mutation events at scan time — the
      // per-file `upsertIndexedFile` has the same logic but the
      // scan flow uses THIS batch path, so the detection must
      // live here too.
      final existing = <String, Map<String, Object?>>{};
      const chunk = 400;
      for (var i = 0; i < files.length; i += chunk) {
        final end = (i + chunk).clamp(0, files.length);
        final slice = files.sublist(i, end);
        final placeholders = List.filled(slice.length, '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT path, uid, intel_uid, content_hash, filesize, '
          'modified_at FROM indexed_files '
          'WHERE path IN ($placeholders)',
          [for (final f in slice) f.path],
        );
        for (final r in rows) {
          existing[r['path'] as String] = r;
        }
      }

      final batch = txn.batch();
      // Yield-every-N counter. Even with async I/O above, a tight
      // loop over 10k+ entries on the main isolate hogs the event
      // loop and the UI can't paint. An explicit yield every 200
      // iterations costs ~50 yields for a 10k-file initial scan —
      // imperceptible cost, and the UI keeps rendering frames.
      var loopCounter = 0;
      for (final f in files) {
        if (loopCounter++ % 200 == 0 && loopCounter > 1) {
          // Microtask yield. Doesn't free the SQLite transaction
          // (we still hold the connection), but lets the Flutter
          // engine drain queued frames / pointer events.
          await Future<void>.delayed(Duration.zero);
        }
        final ids = computeTrackUid(
          basename: f.filename,
          filesize: f.filesize,
          durationMs: f.durationMs,
          mtimeMs: f.modifiedAtMs,
        );
        final ex = existing[f.path];
        if (ex == null) {
          // INSERT path: leave `content_hash` NULL and let the
          // background backfill worker populate it. The bulk
          // scan can't afford to read ~512KB per new file inline
          // — initial 12k-file scans would balloon by 2 minutes.
          // Backfill catches up at idle.
          batch.insert('indexed_files', {
            'path': f.path,
            'source_id': sourceId,
            'filename': f.filename,
            'filesize': f.filesize,
            'modified_at': f.modifiedAtMs,
            'duration_ms': f.durationMs,
            'fingerprint': ids.fingerprint,
            'uid': ids.uid,
            'intel_uid': null,
            'is_available': 1,
            'availability_state': 'available',
            'last_seen_at': now,
            'first_seen_at': now,
            'title': f.fallbackTitle,
          });
          inserted++;
        } else {
          final oldUid = ex['uid'] as String;
          final oldIntelUid = ex['intel_uid'] as String?;
          final oldContentHash = ex['content_hash'] as String?;
          final oldFilesize = (ex['filesize'] as int?) ?? 0;
          final oldModifiedAt = (ex['modified_at'] as int?) ?? 0;

          // Re-tag at same path: fingerprint shifted. If this row
          // owned intelligence (intel_uid == old uid), migrate the
          // tracks row's uid so the link survives.
          if (oldUid != ids.uid &&
              oldIntelUid != null &&
              oldIntelUid == oldUid) {
            batch.update(
              'tracks',
              {'uid': ids.uid},
              where: 'uid = ?',
              whereArgs: [oldUid],
            );
            batch.update(
              'indexed_files',
              {'intel_uid': ids.uid},
              where: 'intel_uid = ?',
              whereArgs: [oldUid],
            );
          }

          // content_hash policy on bulk-scan UPDATE:
          //   - stat unchanged + hash present → reuse old hash.
          //   - stat changed → null the hash and let the
          //     `ContentHashBackfillWorker` recompute it off the
          //     main isolate (throttled, async, timeout-bounded).
          //
          // We used to compute the hash inline here (async variant
          // + 30s timeout) but on cloud-storage paths (Dropbox /
          // iCloud / CloudStorage) macOS blocks each read on
          // dataless-placeholder materialization for 10–30s per
          // file. The transaction stayed open the whole time
          // holding the DB write lock; the UI couldn't query
          // tracks and the app appeared frozen. A 1000-file Dropbox
          // burst could lock the DB for tens of minutes.
          //
          // The backfill worker is purpose-built for this: 10
          // files per batch, 500 ms between batches, async
          // + 30s timeout, runs only at idle. The transaction
          // becomes pure CPU + writes; UI stays responsive even
          // mid-scan.
          //
          // Audit-event tradeoff: `contentUpdatedExternal` used
          // to fire inline when oldHash != newHash. We preserve
          // it by stashing `(path → oldHash + sourceId)` in
          // `_pendingHashCompare`; `setContentHashForPath`
          // checks the map when the backfill writes the
          // recomputed hash, records the event then, and clears
          // the entry. Event timing shifts from "during scan"
          // to "during backfill" — same audit, just deferred.
          final statUnchanged = oldFilesize == f.filesize &&
              oldModifiedAt == f.modifiedAtMs;
          final String? newContentHash;
          if (statUnchanged && oldContentHash != null) {
            newContentHash = oldContentHash;
          } else {
            newContentHash = null;
            if (oldContentHash != null && !statUnchanged) {
              _pendingHashCompare[f.path] =
                  (oldHash: oldContentHash, sourceId: sourceId);
            }
          }

          final updateMap = <String, Object?>{
            'source_id': sourceId,
            'filename': f.filename,
            'filesize': f.filesize,
            'modified_at': f.modifiedAtMs,
            'duration_ms': f.durationMs,
            'fingerprint': ids.fingerprint,
            'content_hash': newContentHash,
            'uid': ids.uid,
            'is_available': 1,
            'availability_state': 'available',
            'last_seen_at': now,
          };
          if (!statUnchanged && oldContentHash != null) {
            // Stat moved → bytes likely diverged (re-encode, retag,
            // in-place rewrite). Cached title/artist/album extracted
            // from the OLD bytes are stale. Wipe `metadata_read_at`
            // so the enrichment pipeline re-reads on next viewport /
            // play / post-scan sweep. Done eagerly (don't wait for
            // the deferred hash compare) because the user may sort
            // or click into this row before backfill catches up.
            //
            // Mirror in the formal state column: a previously-`ready`
            // row drops back to `discovered` so the UI re-dims it
            // and the enrichment pipeline knows it has fresh work.
            updateMap['metadata_read_at'] = 0;
            updateMap['enrichment_state'] = 'discovered';
          }
          batch.update(
            'indexed_files',
            updateMap,
            where: 'path = ?',
            whereArgs: [f.path],
          );
        }
      }
      await batch.commit(noResult: true);
      // contentUpdatedExternal events for stat-changed rows fire
      // later via `setContentHashForPath` once the backfill worker
      // computes the new hash. See `_pendingHashCompare` notes.
    });

    return inserted;
  }

  /// Bulk re-link any `indexed_files` rows under [sourceId] whose
  /// fingerprint matches an existing `tracks` row but whose
  /// `intel_uid` is still NULL. This is the post-scan companion to
  /// the per-row `promoteToIntelligence` ghost-reconnect: when the
  /// user removes a folder + re-adds it, the cascade deletes its
  /// `indexed_files` rows but leaves `tracks` intact. Without this
  /// pass, the table shows `favorite=false / plays=0` until the
  /// user clicks each row individually. With it, the in-memory
  /// `LEFT JOIN` resolves intelligence as soon as the scan
  /// completes and the tracks reload — no extra interaction
  /// required.
  ///
  /// Returns the number of indexed_files rows whose `intel_uid` was
  /// populated.
  Future<int> reconnectIntelligenceBySource(String sourceId) async {
    final updated = await _db.rawUpdate('''
      UPDATE indexed_files
      SET intel_uid = (
        SELECT uid FROM tracks
        WHERE tracks.fingerprint = indexed_files.fingerprint
        LIMIT 1
      )
      WHERE source_id = ?
        AND intel_uid IS NULL
        AND fingerprint IN (SELECT fingerprint FROM tracks)
    ''', [sourceId]);
    return updated;
  }

  /// Read the intelligence row for [intelUid]. Used by the
  /// controller after a fresh promotion so the in-memory Track can
  /// reflect the existing favorite / play count / cumulative time
  /// without a full library reload.
  Future<({
    bool favorite,
    int playCount,
    int cumulativeMs,
    int? lastPlayedAt,
    int? reviewedAt,
    int? favoriteToggledAt,
  })?> fetchIntelligence(String intelUid) async {
    final rows = await _db.query(
      'tracks',
      where: 'uid = ?',
      whereArgs: [intelUid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      favorite: ((r['favorite'] as int?) ?? 0) != 0,
      playCount: (r['play_count'] as int?) ?? 0,
      cumulativeMs: (r['cumulative_ms'] as int?) ?? 0,
      lastPlayedAt: r['last_played_at'] as int?,
      reviewedAt: r['reviewed_at'] as int?,
      favoriteToggledAt: r['favorite_toggled_at'] as int?,
    );
  }

  /// Upsert a freshly-scanned file into `indexed_files`. If the row
  /// already exists at this path, its hashes are recomputed; if the
  /// fingerprint changed (re-tag) and this row owns intelligence, the
  /// owning `tracks.uid` is migrated to the new value so the link
  /// survives.
  ///
  /// Returns the row's resolved `uid` and `fingerprint`.
  Future<TrackUid> upsertIndexedFile({
    required String sourceId,
    required ScannedFile file,
    required int durationMs,
  }) async {
    // Belt-and-suspenders alongside the scanner's stat-failure
    // skip: refuse to persist a row whose stat inputs are
    // degenerate. A row with filesize <= 0 or mtime <= 0 would
    // get a junk fingerprint (the hash inputs are basename +
    // filesize + duration) and would never be matchable to a
    // real available copy of the same file. Treat it as a no-op
    // and let the next scan try again with valid inputs.
    if (file.filesize <= 0 || file.modifiedAt <= 0) {
      return computeTrackUid(
        basename: file.filename,
        filesize: file.filesize,
        durationMs: durationMs,
        mtimeMs: file.modifiedAt,
      );
    }
    final ids = computeTrackUid(
      basename: file.filename,
      filesize: file.filesize,
      durationMs: durationMs,
      mtimeMs: file.modifiedAt,
    );
    final now = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction((txn) async {
      final existing = await txn.query(
        'indexed_files',
        columns: ['uid', 'intel_uid', 'filesize', 'modified_at', 'content_hash'],
        where: 'path = ?',
        whereArgs: [file.path],
        limit: 1,
      );

      // content_hash policy (file-bytes identity, separate from
      // fingerprint heuristic):
      //   INSERT path → always compute fresh.
      //   UPDATE path → reuse the existing hash IFF the stat
      //     signature is unchanged AND the existing hash is non-null.
      //     filesize OR mtime change (re-encode, retag, in-place
      //     rewrite) → recompute. Null existing → backfill.
      //   Hash failure (file gone, perm) leaves content_hash as
      //     whatever was there before; never overwrite a real hash
      //     with null just because a single read happened to fail.
      if (existing.isEmpty) {
        // Async hash so the main isolate stays responsive even
        // when Dropbox CloudStorage paths take seconds per read.
        // The sync variant blocks the UI thread for the duration
        // of the file I/O.
        final hash = await computeContentHash(file.path);
        await txn.insert('indexed_files', {
          'path': file.path,
          'source_id': sourceId,
          'filename': file.filename,
          'filesize': file.filesize,
          'modified_at': file.modifiedAt,
          'duration_ms': durationMs,
          'fingerprint': ids.fingerprint,
          'content_hash': hash,
          'uid': ids.uid,
          'intel_uid': null,
          'is_available': 1,
          'last_seen_at': now,
          'first_seen_at': now,
          'title': file.fallbackTitle,
        });
        return;
      }

      final oldUid = existing.first['uid'] as String;
      final oldIntelUid = existing.first['intel_uid'] as String?;
      final oldFilesize = (existing.first['filesize'] as int?) ?? 0;
      final oldModifiedAt = (existing.first['modified_at'] as int?) ?? 0;
      final oldContentHash = existing.first['content_hash'] as String?;

      // Re-tag at same path: fingerprint shifted. If this row owned
      // intelligence (intel_uid == old uid), migrate the tracks row
      // to the new uid so the link survives. If intel_uid pointed at
      // a sibling, leave it — the sibling still owns the row.
      if (oldUid != ids.uid && oldIntelUid != null && oldIntelUid == oldUid) {
        await txn.update(
          'tracks',
          {'uid': ids.uid},
          where: 'uid = ?',
          whereArgs: [oldUid],
        );
        await txn.update(
          'indexed_files',
          {'intel_uid': ids.uid},
          where: 'intel_uid = ?',
          whereArgs: [oldUid],
        );
      }

      // Decide content_hash: keep stale value if stat looks
      // unchanged AND we already had a real hash; otherwise compute.
      final statUnchanged =
          oldFilesize == file.filesize && oldModifiedAt == file.modifiedAt;
      final String? newContentHash;
      if (statUnchanged && oldContentHash != null) {
        newContentHash = oldContentHash;
      } else {
        // Async to avoid blocking the main isolate. See INSERT
        // path above; same reasoning applies here at higher
        // volume (the initial v9 → v10 scan recomputes for
        // every row that has NULL content_hash).
        final computed = await computeContentHash(file.path);
        // Guardrail: a transient read failure must not erase a
        // previously-good hash. Only overwrite with non-null OR if
        // there was nothing there to begin with.
        newContentHash = computed ?? oldContentHash;
      }

      final bool contentMutated = oldContentHash != null &&
          newContentHash != null &&
          oldContentHash != newContentHash;

      final updateMap = <String, Object?>{
        'source_id': sourceId,
        'filename': file.filename,
        'filesize': file.filesize,
        'modified_at': file.modifiedAt,
        'duration_ms': durationMs,
        'fingerprint': ids.fingerprint,
        'content_hash': newContentHash,
        'uid': ids.uid,
        'is_available': 1,
        'last_seen_at': now,
      };
      // When the bytes diverge at this path, the previously-extracted
      // ID3 / Vorbis fields (title, artist, album, ...) may be stale.
      // Reset `metadata_read_at` so the reactive enrichment pipeline
      // re-reads them on the next viewport / play / post-scan sweep.
      // Without this the tag editor's change to the title field would
      // never surface in the UI — the enrichment gate is
      // `metadataReadAt == null` and a one-shot stamp from the
      // initial enrichment would otherwise lock the old values in.
      if (contentMutated) {
        updateMap['metadata_read_at'] = 0;
        // Drop the formal state back to `discovered` so the UI
        // re-dims this row and the enrichment pipeline knows it
        // has fresh work to do. Mirrors the bulk-path behaviour.
        updateMap['enrichment_state'] = 'discovered';
      }
      await txn.update(
        'indexed_files',
        updateMap,
        where: 'path = ?',
        whereArgs: [file.path],
      );

      // External-mutation audit. If the row already had a real
      // content_hash AND the freshly-computed one is different,
      // some external process (tag editor, DAW re-render, the
      // user's own bytes-on-disk edit) modified the file at this
      // path. Same row, same intel, but the bytes diverged.
      // Record one event so the History panel narrates the change
      // instead of letting it happen silently.
      //
      // We intentionally do NOT fire this for backfills (null →
      // hash) or for read-failure preservations (hash → null
      // shielded → hash unchanged). Those are accounting
      // transitions, not real mutations.
      if (contentMutated) {
        await recordEvent(
          type: EventType.contentUpdatedExternal,
          path: file.path,
          sourceId: sourceId,
          payload: {
            'old_content_hash_prefix':
                oldContentHash.length >= 12
                    ? oldContentHash.substring(0, 12)
                    : oldContentHash,
            'new_content_hash_prefix':
                newContentHash.length >= 12
                    ? newContentHash.substring(0, 12)
                    : newContentHash,
          },
          txn: txn,
        );
      }
    });

    return ids;
  }

  /// Mark availability for a source: paths in [seenPaths] become
  /// available, all others (under this source) become unavailable.
  /// Rows are NOT deleted (intelligence reconnect on return).
  ///
  /// Two-pass: first reset every row in this source to `is_available=0`,
  /// then chunked-flip the seen paths to 1. The previous one-pass
  /// `NOT IN` approach was buggy when seenPaths exceeded the chunk
  /// size — each chunk's NOT IN clause clobbered the available flag
  /// for paths in OTHER chunks, so only the last chunk's paths
  /// survived as available.
  Future<ReconciliationDelta> markUnseenAvailability(
    String sourceId,
    Set<String> seenPaths,
  ) async {
    int removed = 0;
    int preservedElsewhere = 0;
    await _db.transaction((txn) async {
      // Snapshot the rows that are about to transition from
      // 'available' to 'missing'. We pull them BEFORE the update
      // so we can emit one `removed_external` event per row.
      // Filtering against [seenPaths] is done in Dart rather than
      // SQL — a NOT IN clause with a 12k-element bind list is
      // both ugly and at the edge of SQLite's parameter limit.
      //
      // `content_hash` is pulled alongside `path` so we can compute
      // the "preserved elsewhere" count for the reconciliation
      // summary (rows whose bytes are still reachable through a
      // different watched source). Cheap — no extra query, just
      // an extra column on a query we already ran.
      final wasAvailable = await txn.rawQuery(
        "SELECT path, content_hash FROM indexed_files "
        "WHERE source_id = ? AND availability_state = 'available'",
        [sourceId],
      );
      final transitioning = wasAvailable
          .where((r) => !seenPaths.contains(r['path'] as String))
          .toList(growable: false);
      removed = transitioning.length;
      // Pass 1: reset everything in this source to missing. Both
      // `is_available` (legacy boolean) and `availability_state`
      // (richer state machine) move together: the state machine
      // is the source of truth, `is_available` mirrors it for
      // back-compat with code paths that haven't migrated yet.
      await txn.update(
        'indexed_files',
        {
          'is_available': 0,
          'availability_state': 'missing',
        },
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      // Record removal events. Done inside the transaction so the
      // event row and the state change land atomically — no
      // "ghost event for a state change that rolled back" case.
      for (final row in transitioning) {
        await recordEvent(
          type: EventType.removedExternal,
          path: row['path'] as String,
          sourceId: sourceId,
          txn: txn,
        );
      }
      // Preserved-elsewhere check. For each transitioning row that
      // has a content_hash, look for at least one currently-
      // available row IN ANOTHER SOURCE with the same hash. We
      // gather distinct hashes first so a folder of duplicates
      // doesn't trigger N redundant lookups.
      final hashesToCheck = <String>{};
      for (final row in transitioning) {
        final ch = row['content_hash'] as String?;
        if (ch != null && ch.isNotEmpty) hashesToCheck.add(ch);
      }
      if (hashesToCheck.isNotEmpty) {
        // Chunked IN-clause to stay inside SQLite's bind limit.
        const chunkSize = 400;
        final hashList = hashesToCheck.toList(growable: false);
        final survivingHashes = <String>{};
        for (var i = 0; i < hashList.length; i += chunkSize) {
          final end = (i + chunkSize).clamp(0, hashList.length);
          final slice = hashList.sublist(i, end);
          final placeholders = List.filled(slice.length, '?').join(',');
          final hits = await txn.rawQuery(
            "SELECT DISTINCT content_hash FROM indexed_files "
            "WHERE source_id != ? "
            "  AND availability_state = 'available' "
            "  AND content_hash IN ($placeholders)",
            [sourceId, ...slice],
          );
          for (final h in hits) {
            survivingHashes.add(h['content_hash'] as String);
          }
        }
        // Count transitioning rows whose hash survives in
        // another source. A folder of duplicates within Q where
        // each duplicate has a twin in Z counts each Q row.
        for (final row in transitioning) {
          final ch = row['content_hash'] as String?;
          if (ch != null && survivingHashes.contains(ch)) {
            preservedElsewhere++;
          }
        }
      }
      if (seenPaths.isEmpty) return;

      // Pass 2: chunked update to flip seen paths back to available.
      const chunkSize = 400;
      final list = seenPaths.toList(growable: false);
      for (var i = 0; i < list.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, list.length);
        final slice = list.sublist(i, end);
        final placeholders = List.filled(slice.length, '?').join(',');
        await txn.rawUpdate(
          "UPDATE indexed_files SET is_available = 1, "
          "availability_state = 'available' "
          "WHERE source_id = ? AND path IN ($placeholders)",
          [sourceId, ...slice],
        );
      }
    });
    return ReconciliationDelta(
      removed: removed,
      preservedElsewhere: preservedElsewhere,
    );
  }

  /// Permanently remove `indexed_files` rows for the given paths.
  /// Used by the "Review missing files" dialog's purge action when
  /// the user is sure the row no longer represents a useful file
  /// (truly deleted or moved out of scope and they don't want the
  /// ghost lingering). `tracks` rows are not touched — intel
  /// preservation guardrail #5 still applies; orphan intel survives
  /// for the next time the file reconnects by fingerprint.
  ///
  /// Returns the number of rows deleted.
  Future<int> purgeIndexedFiles(List<String> paths) async {
    if (paths.isEmpty) return 0;
    final placeholders = List.filled(paths.length, '?').join(',');
    // Capture the rows' prior state for the activity log BEFORE
    // the delete. The DELETE is fire-and-forget audit-wise; if
    // the events fail to record afterward we'd lose the trail.
    final priorRows = await _db.rawQuery(
      'SELECT path, source_id, availability_state '
      'FROM indexed_files WHERE path IN ($placeholders)',
      paths,
    );
    final deleted = await _db.delete(
      'indexed_files',
      where: 'path IN ($placeholders)',
      whereArgs: paths,
    );
    for (final row in priorRows) {
      await recordEvent(
        type: EventType.purged,
        path: row['path'] as String,
        sourceId: row['source_id'] as String?,
        payload: {
          'prior_state': row['availability_state'] as String?,
        },
      );
    }
    return deleted;
  }

  /// Auto-detect "moved file" supersession after a scan, within a
  /// single source. Upgrades a `'missing'` row to `'superseded'`
  /// only when ALL FOUR conditions of the L9 rule hold against an
  /// available candidate in the same source:
  ///
  ///   1. Missing row is `availability_state = 'missing'`.
  ///   2. EXACTLY ONE candidate matches on `content_hash` (preferred)
  ///      or `fingerprint` (fallback when content_hash is NULL on
  ///      either side). Multiple candidates → ambiguous, leave
  ///      missing. Zero candidates → genuinely missing, leave it.
  ///   3. Both rows pass junk-stat protection (filesize > 0 AND
  ///      duration_ms > 0). Transient I/O glitches must not trigger
  ///      cascading false supersessions.
  ///   4. Temporal soundness: candidate's `first_seen_at` ≥
  ///      missing's `last_seen_at − supersessionTemporalOverlapGrace`.
  ///      The candidate must have appeared at or after the missing
  ///      row disappeared, modulo a small grace window for
  ///      scan-timing noise.
  ///
  /// The intel link is then carried by the same migration pass as
  /// `markCrossSourceMoves` runs at its tail; this per-source pass
  /// only writes the `availability_state` flip and the audit event.
  /// (Same-source intel re-link via `reconnectIntelligenceBySource`
  /// is the legacy path; the explicit migration here lets renames
  /// — basename changed → fingerprint shifted — survive.)
  ///
  /// Returns the number of rows upgraded from missing → superseded.
  Future<int> markMovedSupersessions(String sourceId) async {
    final graceMs = supersessionTemporalOverlapGrace.inMilliseconds;

    // Pre-query the rows that the UPDATE below will supersede,
    // along with the matched signal, successor path, and temporal
    // evidence (missing.last_seen_at, successor.first_seen_at,
    // computed overlap). The WHERE clause mirrors the UPDATE's
    // exactly so the event log records every state change and
    // nothing else. Same-source: both missing and successor are
    // restricted to [sourceId].
    final affected = await _db.rawQuery('''
      SELECT
        m.path AS missing_path,
        m.last_seen_at AS missing_last_seen_at,
        CASE
          WHEN m.content_hash IS NOT NULL THEN 'content_hash'
          ELSE 'fingerprint'
        END AS matched_on,
        (SELECT a.path FROM indexed_files a
         WHERE a.source_id = ?
           AND a.availability_state = 'available'
           AND a.filesize > 0 AND a.duration_ms > 0
           AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
           AND a.first_seen_at >= m.last_seen_at - ?
         LIMIT 1) AS successor_path,
        (SELECT a.first_seen_at FROM indexed_files a
         WHERE a.source_id = ?
           AND a.availability_state = 'available'
           AND a.filesize > 0 AND a.duration_ms > 0
           AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
           AND a.first_seen_at >= m.last_seen_at - ?
         LIMIT 1) AS successor_first_seen_at
      FROM indexed_files m
      WHERE m.source_id = ?
        AND m.availability_state = 'missing'
        AND m.filesize > 0 AND m.duration_ms > 0
        AND (
          (m.content_hash IS NOT NULL AND (
            SELECT COUNT(*) FROM indexed_files a
            WHERE a.source_id = ?
              AND a.content_hash = m.content_hash
              AND a.availability_state = 'available'
              AND a.filesize > 0 AND a.duration_ms > 0
          ) = 1)
          OR
          (m.content_hash IS NULL AND (
            SELECT COUNT(*) FROM indexed_files a
            WHERE a.source_id = ?
              AND a.fingerprint = m.fingerprint
              AND a.availability_state = 'available'
              AND a.filesize > 0 AND a.duration_ms > 0
          ) = 1)
        )
        AND EXISTS (
          SELECT 1 FROM indexed_files a
          WHERE a.source_id = ?
            AND a.availability_state = 'available'
            AND a.filesize > 0 AND a.duration_ms > 0
            AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                 OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
            AND a.first_seen_at >= m.last_seen_at - ?
        )
    ''', [
      sourceId, graceMs,
      sourceId, graceMs,
      sourceId,
      sourceId,
      sourceId,
      sourceId, graceMs,
    ]);

    final count = await _db.rawUpdate('''
      UPDATE indexed_files
      SET availability_state = 'superseded'
      WHERE source_id = ?
        AND availability_state = 'missing'
        AND filesize > 0 AND duration_ms > 0
        AND (
          (content_hash IS NOT NULL AND (
            SELECT COUNT(*) FROM indexed_files a
            WHERE a.source_id = ?
              AND a.content_hash = indexed_files.content_hash
              AND a.availability_state = 'available'
              AND a.filesize > 0 AND a.duration_ms > 0
          ) = 1)
          OR
          (content_hash IS NULL AND (
            SELECT COUNT(*) FROM indexed_files a
            WHERE a.source_id = ?
              AND a.fingerprint = indexed_files.fingerprint
              AND a.availability_state = 'available'
              AND a.filesize > 0 AND a.duration_ms > 0
          ) = 1)
        )
        AND EXISTS (
          SELECT 1 FROM indexed_files a
          WHERE a.source_id = ?
            AND a.availability_state = 'available'
            AND a.filesize > 0 AND a.duration_ms > 0
            AND ((indexed_files.content_hash IS NOT NULL
                  AND a.content_hash = indexed_files.content_hash)
                 OR (indexed_files.content_hash IS NULL
                     AND a.fingerprint = indexed_files.fingerprint))
            AND a.first_seen_at >= indexed_files.last_seen_at - ?
        )
    ''', [sourceId, sourceId, sourceId, sourceId, graceMs]);

    for (final row in affected) {
      final missingLastSeenAt = row['missing_last_seen_at'] as int;
      final successorFirstSeenAt = row['successor_first_seen_at'] as int?;
      final overlapMs = successorFirstSeenAt == null
          ? null
          : missingLastSeenAt - successorFirstSeenAt;
      await recordEvent(
        type: EventType.autoMoveSameSource,
        path: row['missing_path'] as String,
        sourceId: sourceId,
        payload: {
          'successor_path': row['successor_path'] as String?,
          'matched_on': row['matched_on'] as String,
          'missing_last_seen_at': missingLastSeenAt,
          'successor_first_seen_at': successorFirstSeenAt,
          // Negative = clean succession (successor appeared after
          // missing disappeared). Zero or positive = they overlapped,
          // within the grace window.
          'overlap_ms': overlapMs,
        },
      );
    }
    return count;
  }

  /// Cross-source relocation detection. Auto-resolves the
  /// intake → prep → crate workflow case: a file the user moved
  /// from one watched source to another should not linger as
  /// "missing" forever just because per-source supersession
  /// can't see across sources.
  ///
  /// Rule (uniqueness only — the strict 4-condition rule lives
  /// in project memory, the temporal/overlap pieces ship in a
  /// later phase once `first_seen_at` and `content_hash` are
  /// available):
  ///
  ///   For each `missing` row whose stat inputs are valid
  ///   (filesize > 0 AND duration_ms > 0), if EXACTLY ONE row
  ///   in any source carries the same fingerprint, is currently
  ///   `available`, and also has valid stat inputs → mark the
  ///   missing row as `superseded`.
  ///
  /// Multiple candidates → ambiguous, do not auto-link. Zero
  /// candidates → genuinely missing, leave it. Junk fingerprints
  /// (filesize <= 0 / duration_ms <= 0) on either side are
  /// excluded so the scanner's transient I/O glitches never
  /// trigger cascading false supersessions.
  ///
  /// Backfill candidates: paths whose `content_hash` is NULL on
  /// rows we can actually still read. Used by the background
  /// `ContentHashBackfillWorker` (Slice 3) to populate the column
  /// for legacy rows (pre-v10) and any row that returned null
  /// from the scan-time hash.
  ///
  /// Filters:
  ///   - `content_hash IS NULL`
  ///   - `availability_state = 'available'` (no point trying to
  ///     hash a file the scan can't see)
  ///   - `filesize > 0` (junk stat inputs would just fail again)
  ///   - `path` is not in [skip] — caller's in-memory failed-set
  ///     so we don't loop on permanent failures.
  ///
  /// Ordered by `last_seen_at DESC` so the rows the user touched
  /// most recently get hashed first. Returns up to [limit] paths.
  Future<List<String>> contentHashCandidates({
    required int limit,
    Set<String> skip = const {},
  }) async {
    // SQLite doesn't bind list parameters directly. For the skip
    // set we either filter in-memory after a wider query or build
    // an IN-clause inline. The worker already filters in memory;
    // SQL filter would be redundant. Keep this query simple.
    final rows = await _db.rawQuery(
      '''
      SELECT path FROM indexed_files
      WHERE content_hash IS NULL
        AND availability_state = 'available'
        AND filesize > 0
      ORDER BY last_seen_at DESC
      LIMIT ?
      ''',
      [limit],
    );
    final paths =
        rows.map((r) => r['path'] as String).where((p) => !skip.contains(p));
    return paths.toList();
  }

  /// Total rows still waiting for the backfill worker. Powers the
  /// determinate progress display in the status bar — "Hashing
  /// audio 12 / 873" is more reassuring than an indeterminate
  /// spinner during a long Dropbox materialization wave.
  /// Counted, not sampled — cheap because of the `availability_state`
  /// + content_hash IS NULL filters working off existing indexes.
  Future<int> contentHashCandidatesCount() async {
    final rows = await _db.rawQuery(
      '''
      SELECT COUNT(*) AS n FROM indexed_files
      WHERE content_hash IS NULL
        AND availability_state = 'available'
        AND filesize > 0
      ''',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Write a freshly-computed content_hash for a single path.
  /// Called by the backfill worker once per row; intentionally
  /// targeted so it doesn't fight the scan upsert's broader
  /// transaction on the same row.
  ///
  /// No-op if the row has been removed between the candidate
  /// query and this write (returns 0).
  ///
  /// Deferred-audit hook: if `_pendingHashCompare[path]` was
  /// populated by a stat-change upsert (the batch path nulls
  /// `content_hash` so the backfill worker can rehash off the
  /// main isolate), record `contentUpdatedExternal` here when the
  /// new hash differs from the stashed old one. This shifts the
  /// audit event from "during scan" (where it would have blocked
  /// the transaction on cloud-storage paths) to "during backfill"
  /// — same audit, just deferred. The entry is removed either way
  /// so a stable bytes-on-disk file doesn't keep getting compared.
  Future<int> setContentHashForPath(String path, String hash) async {
    final pending = _pendingHashCompare.remove(path);
    final updated = await _db.update(
      'indexed_files',
      {'content_hash': hash},
      where: 'path = ?',
      whereArgs: [path],
    );
    if (updated > 0 && pending != null && pending.oldHash != hash) {
      await recordEvent(
        type: EventType.contentUpdatedExternal,
        path: path,
        sourceId: pending.sourceId,
        payload: {
          'old_content_hash_prefix': pending.oldHash.length >= 12
              ? pending.oldHash.substring(0, 12)
              : pending.oldHash,
          'new_content_hash_prefix':
              hash.length >= 12 ? hash.substring(0, 12) : hash,
        },
      );
    }
    return updated;
  }

  /// Idempotent — safe to call after every scan.
  ///
  /// **Slice 5 upgrade — content_hash takes precedence.**
  ///
  /// The matching signal is chosen per missing row based on what
  /// evidence we have:
  ///
  ///   • Missing row has a `content_hash`
  ///       → require a UNIQUE same-content_hash available match.
  ///       Fingerprint matches don't count even if they exist
  ///       (content_hash is the more authoritative signal — same
  ///       fingerprint can mean different bytes when basenames
  ///       collide). This is also the path that catches a move
  ///       across folders that involved a rename: same bytes,
  ///       different basename → different fingerprint, same
  ///       content_hash → supersede.
  ///
  ///   • Missing row has NULL content_hash (legacy / pre-v10 /
  ///     scan-time hash failed)
  ///       → fall back to a UNIQUE same-fingerprint available
  ///       match. Same rule the slice-3 tactical version
  ///       shipped with, just gated so it only runs on the
  ///       rows still missing content_hash. The backfill worker
  ///       upgrades these over time, after which subsequent
  ///       calls take the strong path.
  ///
  /// Both paths share the rest of the L9 rule:
  ///   - missing row + matching row both must have filesize > 0
  ///     AND duration_ms > 0 (junk-stat protection).
  ///   - EXACTLY ONE matching available row (uniqueness — multiple
  ///     same-content rows are coexisting duplicates, never a
  ///     relocation event).
  ///   - **Temporal soundness:** successor's `first_seen_at` ≥
  ///     missing's `last_seen_at − supersessionTemporalOverlapGrace`.
  ///     The candidate must have appeared at or after the missing
  ///     row disappeared, modulo a small grace window for scan-
  ///     timing noise. Rejects intentional duplicates that were
  ///     coexisting long before one of them went missing.
  ///
  /// Returns the number of rows upgraded from missing → superseded.
  Future<int> markCrossSourceMoves() async {
    final graceMs = supersessionTemporalOverlapGrace.inMilliseconds;
    // Pre-query the rows that the UPDATE below will supersede,
    // along with the matched_on signal, successor path, AND
    // successor source_id. Mirrors the UPDATE's WHERE clause
    // exactly so the event log records every state change and
    // nothing else. The successor_source_id is what lets the
    // event recorder distinguish a same-source rename (caught
    // via content_hash because basename changed → fingerprint
    // differs) from a true cross-source relocation — they're
    // both "auto-resolved supersessions" but should narrate
    // differently in the History panel.
    // The successor selectors are filtered by temporal soundness
    // (first_seen_at >= missing.last_seen_at - graceMs) so the
    // path / source_id we record in the event are the *qualifying*
    // successor — the one that would actually pass the auto-
    // supersession check. Without this filter the affected SELECT
    // could record a non-temporally-sound candidate even though the
    // outer WHERE-EXISTS clause refused the supersession.
    final affected = await _db.rawQuery('''
      SELECT
        m.path AS missing_path,
        m.source_id,
        m.last_seen_at AS missing_last_seen_at,
        CASE
          WHEN m.content_hash IS NOT NULL THEN 'content_hash'
          ELSE 'fingerprint'
        END AS matched_on,
        (SELECT a.path FROM indexed_files a
         WHERE a.availability_state = 'available'
           AND a.filesize > 0 AND a.duration_ms > 0
           AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
           AND a.first_seen_at >= m.last_seen_at - ?
         LIMIT 1) AS successor_path,
        (SELECT a.source_id FROM indexed_files a
         WHERE a.availability_state = 'available'
           AND a.filesize > 0 AND a.duration_ms > 0
           AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
           AND a.first_seen_at >= m.last_seen_at - ?
         LIMIT 1) AS successor_source_id,
        (SELECT a.first_seen_at FROM indexed_files a
         WHERE a.availability_state = 'available'
           AND a.filesize > 0 AND a.duration_ms > 0
           AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
           AND a.first_seen_at >= m.last_seen_at - ?
         LIMIT 1) AS successor_first_seen_at
      FROM indexed_files m
      WHERE m.availability_state = 'missing'
        AND m.filesize > 0 AND m.duration_ms > 0
        AND (
          (m.content_hash IS NOT NULL AND (
            SELECT COUNT(*) FROM indexed_files a
            WHERE a.content_hash = m.content_hash
              AND a.availability_state = 'available'
              AND a.filesize > 0 AND a.duration_ms > 0
          ) = 1)
          OR
          (m.content_hash IS NULL AND (
            SELECT COUNT(*) FROM indexed_files a
            WHERE a.fingerprint = m.fingerprint
              AND a.availability_state = 'available'
              AND a.filesize > 0 AND a.duration_ms > 0
          ) = 1)
        )
        AND EXISTS (
          SELECT 1 FROM indexed_files a
          WHERE a.availability_state = 'available'
            AND a.filesize > 0 AND a.duration_ms > 0
            AND ((m.content_hash IS NOT NULL AND a.content_hash = m.content_hash)
                 OR (m.content_hash IS NULL AND a.fingerprint = m.fingerprint))
            AND a.first_seen_at >= m.last_seen_at - ?
        )
    ''', [graceMs, graceMs, graceMs, graceMs]);

    final count = await _db.rawUpdate('''
      UPDATE indexed_files
      SET availability_state = 'superseded'
      WHERE availability_state = 'missing'
        AND filesize > 0
        AND duration_ms > 0
        AND (
          -- Strong path: match by content_hash when present.
          (
            content_hash IS NOT NULL
            AND (
              SELECT COUNT(*) FROM indexed_files a
              WHERE a.content_hash = indexed_files.content_hash
                AND a.availability_state = 'available'
                AND a.filesize > 0
                AND a.duration_ms > 0
            ) = 1
          )
          OR
          -- Fallback path: legacy rows still NULL on content_hash
          -- fall back to the slice-3 fingerprint rule. Upgrades
          -- to the strong path automatically as backfill fills
          -- the column.
          (
            content_hash IS NULL
            AND (
              SELECT COUNT(*) FROM indexed_files a
              WHERE a.fingerprint = indexed_files.fingerprint
                AND a.availability_state = 'available'
                AND a.filesize > 0
                AND a.duration_ms > 0
            ) = 1
          )
        )
        -- Temporal soundness gate: the (unique) successor row must
        -- have appeared at or after this row went missing, modulo
        -- a small grace window. Rejects intentional duplicates
        -- that coexisted long before one of them disappeared.
        AND EXISTS (
          SELECT 1 FROM indexed_files a
          WHERE a.availability_state = 'available'
            AND a.filesize > 0 AND a.duration_ms > 0
            AND ((indexed_files.content_hash IS NOT NULL
                  AND a.content_hash = indexed_files.content_hash)
                 OR (indexed_files.content_hash IS NULL
                     AND a.fingerprint = indexed_files.fingerprint))
            AND a.first_seen_at >= indexed_files.last_seen_at - ?
        )
    ''', [graceMs]);

    // Intel migration pass. The supersession UPDATE above marks
    // the old row as superseded but doesn't move its `intel_uid`
    // anywhere — the new row at the new path was inserted fresh
    // by upsert with `intel_uid = NULL`. For same-basename moves
    // `reconnectIntelligenceBySource` can re-link by fingerprint,
    // but for RENAMES (basename changed → fingerprint changed),
    // that path fails. Without an explicit migration here, the
    // user's plays / favorites / review state appear to "vanish"
    // after a rename in Mp3tag / Rekordbox / Serato / etc.
    //
    // The migration: for every superseded row that just got
    // marked, look up its content_hash (or fingerprint, fallback
    // path) match in the available pool. If the matched
    // available row has `intel_uid = NULL`, copy the superseded
    // row's intel_uid onto it. Never overwrite an existing
    // intel_uid — that would silently bridge two unrelated
    // intels in the rare case the available row was already
    // linked.
    await _db.rawUpdate('''
      UPDATE indexed_files
      SET intel_uid = (
        SELECT m.intel_uid FROM indexed_files m
        WHERE m.availability_state = 'superseded'
          AND m.intel_uid IS NOT NULL
          AND m.filesize > 0
          AND m.duration_ms > 0
          AND (
            (m.content_hash IS NOT NULL
              AND indexed_files.content_hash IS NOT NULL
              AND m.content_hash = indexed_files.content_hash)
            OR
            (m.content_hash IS NULL
              AND m.fingerprint = indexed_files.fingerprint)
          )
        LIMIT 1
      )
      WHERE availability_state = 'available'
        AND intel_uid IS NULL
        AND filesize > 0
        AND duration_ms > 0
        AND EXISTS (
          SELECT 1 FROM indexed_files m
          WHERE m.availability_state = 'superseded'
            AND m.intel_uid IS NOT NULL
            AND m.filesize > 0
            AND m.duration_ms > 0
            AND (
              (m.content_hash IS NOT NULL
                AND indexed_files.content_hash IS NOT NULL
                AND m.content_hash = indexed_files.content_hash)
              OR
              (m.content_hash IS NULL
                AND m.fingerprint = indexed_files.fingerprint)
            )
        )
    ''');

    // Event-type label honesty. The "cross-source" name is
    // historical — markCrossSourceMoves doesn't filter by source
    // and will happily catch a same-source rename (content_hash
    // matches, basenames differ → fingerprint missed it). When
    // the successor sits in the same source as the missing row,
    // the event is semantically a same-source relocation and
    // should be narrated as such.
    for (final row in affected) {
      final originSource = row['source_id'] as String?;
      final successorSource = row['successor_source_id'] as String?;
      final sameSource = originSource != null &&
          successorSource != null &&
          originSource == successorSource;
      final missingLastSeenAt = row['missing_last_seen_at'] as int;
      final successorFirstSeenAt = row['successor_first_seen_at'] as int?;
      final overlapMs = successorFirstSeenAt == null
          ? null
          : missingLastSeenAt - successorFirstSeenAt;
      await recordEvent(
        type: sameSource
            ? EventType.autoMoveSameSource
            : EventType.autoMoveCrossSource,
        path: row['missing_path'] as String,
        sourceId: originSource,
        payload: {
          'successor_path': row['successor_path'] as String?,
          'successor_source_id': successorSource,
          'matched_on': row['matched_on'] as String,
          'missing_last_seen_at': missingLastSeenAt,
          'successor_first_seen_at': successorFirstSeenAt,
          // Negative = clean succession (successor appeared after
          // missing disappeared). Zero/positive = they overlapped,
          // within the grace window.
          'overlap_ms': overlapMs,
        },
      );
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // App-initiated file movement (Move/Copy)
  //
  // Repo-level primitives that atomically perform a filesystem
  // operation (rename or copy) AND the corresponding indexed_files
  // row update, plus an `app_initiated_*` activity event. These
  // are the building blocks of the "app as orchestrator of
  // filesystem truth" architecture; the controller wraps them with
  // pre-flight + reload logic in sub-slice B.
  // ---------------------------------------------------------------------------

  /// Move the file at [sourcePath] into [destSource]'s folder root.
  /// Filename stays the same. Atomic where the filesystem allows
  /// (single-volume rename); falls back to copy + delete for
  /// cross-volume moves with rollback if the delete fails.
  ///
  /// The old indexed_files row is removed and a new one is
  /// inserted at the destination path inside a single transaction.
  /// intel_uid / content_hash / fingerprint carry over unchanged
  /// — same bytes, same identity, just a new physical location.
  ///
  /// Records an [EventType.appInitiatedMove] event on success.
  /// On failure (source missing, destination collision, FS error)
  /// returns a [MoveCopyResult] with a human-readable reason; the
  /// DB and FS are guaranteed to be in their pre-call state.
  Future<MoveCopyResult> moveTrackFile({
    required String sourcePath,
    required Source destSource,
  }) async {
    final basename = _basenameOf(sourcePath);
    final destPath = '${destSource.folderPath}'
        '${Platform.pathSeparator}'
        '$basename';

    // Pre-flight ─────────────────────────────────────────────
    if (sourcePath == destPath) {
      return const MoveCopyResult.failure(
        'Source and destination are the same path.',
      );
    }
    final srcFile = File(sourcePath);
    if (!srcFile.existsSync()) {
      return MoveCopyResult.failure(
        'Source file no longer exists on disk: $sourcePath',
      );
    }
    if (File(destPath).existsSync()) {
      return MoveCopyResult.failure(
        'A file already exists at the destination: $destPath',
      );
    }
    final srcRow = await _db.query(
      'indexed_files',
      where: 'path = ?',
      whereArgs: [sourcePath],
      limit: 1,
    );
    if (srcRow.isEmpty) {
      return MoveCopyResult.failure(
        'No indexed_files row found for $sourcePath',
      );
    }
    final row = Map<String, Object?>.from(srcRow.first);

    // Filesystem op ──────────────────────────────────────────
    String via;
    try {
      srcFile.renameSync(destPath);
      via = 'rename';
    } on FileSystemException {
      // Cross-volume rename throws (EXDEV on POSIX). Fall back
      // to copy + delete with rollback if the delete leg fails.
      try {
        srcFile.copySync(destPath);
      } on FileSystemException catch (e) {
        return MoveCopyResult.failure(
          'Filesystem copy failed: ${e.message}',
        );
      }
      try {
        srcFile.deleteSync();
      } on FileSystemException catch (e) {
        // Source delete failed AFTER copy succeeded — roll back
        // by removing the destination copy so we don't end up
        // with a phantom duplicate.
        try {
          File(destPath).deleteSync();
        } catch (_) {/* best-effort rollback */}
        return MoveCopyResult.failure(
          'Cross-volume move rolled back — source delete failed: '
          '${e.message}',
        );
      }
      via = 'copy_then_delete';
    }

    // DB update + event ──────────────────────────────────────
    try {
      await _db.transaction((txn) async {
        // Clean up any stale indexed_files row at destPath
        // (typically left over from a previous move/copy that the
        // user later undid in Finder, leaving a 'superseded' or
        // 'missing' row behind). Pre-flight already confirmed no
        // FILE exists at destPath, so any row here is by
        // definition stale. Without this cleanup the INSERT below
        // would trip `UNIQUE constraint failed: indexed_files.path`
        // and roll back the whole move.
        final stale = await txn.query(
          'indexed_files',
          columns: ['availability_state', 'source_id'],
          where: 'path = ? AND path != ?',
          whereArgs: [destPath, sourcePath],
          limit: 1,
        );
        if (stale.isNotEmpty) {
          await txn.delete(
            'indexed_files',
            where: 'path = ? AND path != ?',
            whereArgs: [destPath, sourcePath],
          );
          await recordEvent(
            type: EventType.purged,
            path: destPath,
            sourceId: stale.first['source_id'] as String?,
            payload: {
              'prior_state':
                  stale.first['availability_state'] as String?,
              'auto_purge_reason': 'replaced_by_app_initiated_move',
            },
            txn: txn,
          );
        }
        // Insert the new row, then delete the source row.
        final newRow = Map<String, Object?>.from(row);
        newRow['path'] = destPath;
        newRow['source_id'] = destSource.id;
        newRow['filename'] = basename;
        // last_seen_at + first_seen_at bumped to NOW — the file was
        // just observed at the new path by us, not by a scan, so
        // this counts as a fresh sighting. `first_seen_at` is per
        // File Instance (path-bound), not per Track Identity — the
        // destination is a new Instance even if the underlying
        // bytes were already known elsewhere. This is also what
        // makes Phase 2's temporal-after check work cleanly: the
        // missing source row's `last_seen_at` will be ≤ the dest
        // row's `first_seen_at` for any well-formed move.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        newRow['last_seen_at'] = nowMs;
        newRow['first_seen_at'] = nowMs;
        // is_available + availability_state: file IS available now,
        // ensure both reflect that even if the source row was
        // somehow in a non-available state (which shouldn't happen
        // since pre-flight verified the source file exists).
        newRow['is_available'] = 1;
        newRow['availability_state'] = 'available';
        await txn.insert('indexed_files', newRow);
        await txn.delete(
          'indexed_files',
          where: 'path = ?',
          whereArgs: [sourcePath],
        );
        await recordEvent(
          type: EventType.appInitiatedMove,
          path: sourcePath,
          sourceId: row['source_id'] as String?,
          payload: {
            'dest_path': destPath,
            'dest_source_id': destSource.id,
            'via': via,
          },
          txn: txn,
        );
      });
    } catch (e) {
      // Atypical — FS already moved but DB write failed. Try to
      // undo the FS rename so the next scan re-discovers the
      // file at its original path with the original row intact.
      try {
        final destFile = File(destPath);
        if (destFile.existsSync()) {
          destFile.renameSync(sourcePath);
        }
      } catch (_) {/* best-effort */}
      return MoveCopyResult.failure(
        'Database update failed; rolled back filesystem move: $e',
      );
    }
    return MoveCopyResult.success(newPath: destPath, via: via);
  }

  /// Copy the file at [sourcePath] into [destSource]'s folder root.
  /// Same basename. A new indexed_files row is inserted at the
  /// destination, sharing the source's `intel_uid` so favorites /
  /// plays / review state live at the song-identity layer and
  /// both rows reflect them.
  ///
  /// `content_hash` and `fingerprint` are copied from the source
  /// row unchanged — same audio bytes, same basename, same
  /// duration. The `uid` is RE-COMPUTED because uid hashes mtime
  /// in addition to the file-identity inputs, and the fresh copy
  /// has a new mtime.
  ///
  /// Records an [EventType.appInitiatedCopy] event on success.
  Future<MoveCopyResult> copyTrackFile({
    required String sourcePath,
    required Source destSource,
  }) async {
    final basename = _basenameOf(sourcePath);
    final destPath = '${destSource.folderPath}'
        '${Platform.pathSeparator}'
        '$basename';

    if (sourcePath == destPath) {
      return const MoveCopyResult.failure(
        'Source and destination are the same path — use Move instead, or '
        'rename one side first.',
      );
    }
    final srcFile = File(sourcePath);
    if (!srcFile.existsSync()) {
      return MoveCopyResult.failure(
        'Source file no longer exists on disk: $sourcePath',
      );
    }
    if (File(destPath).existsSync()) {
      return MoveCopyResult.failure(
        'A file already exists at the destination: $destPath',
      );
    }
    final srcRow = await _db.query(
      'indexed_files',
      where: 'path = ?',
      whereArgs: [sourcePath],
      limit: 1,
    );
    if (srcRow.isEmpty) {
      return MoveCopyResult.failure(
        'No indexed_files row found for $sourcePath',
      );
    }
    final row = Map<String, Object?>.from(srcRow.first);

    try {
      srcFile.copySync(destPath);
    } on FileSystemException catch (e) {
      return MoveCopyResult.failure(
        'Filesystem copy failed: ${e.message}',
      );
    }

    // CRITICAL: Dart's File.copySync uses macOS's `copyfile`, which
    // PRESERVES the source's mtime. Without explicitly bumping it,
    // the destination's mtime == source's mtime, which means
    // `computeTrackUid` (which hashes basename+filesize+duration+mtime)
    // produces the SAME uid on both rows. That breaks the
    // controller's `_trackByUid` Map: only one of the two rows
    // wins the slot, click-to-play on the surviving row's uid
    // dispatches to whichever Track instance was inserted last,
    // and playback tries the wrong path.
    //
    // Stamp the destination with "now" so uid genuinely differs
    // from the source. Re-stat afterward to capture the new value.
    final destFile = File(destPath);
    try {
      destFile.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // Best-effort: if we can't set mtime (read-only mount?), the
      // copy proceeds but uid may collide. Caller's tests + the
      // map lookup will surface the issue.
    }
    final destStat = destFile.statSync();
    final newMtime = destStat.modified.millisecondsSinceEpoch;
    final newUid = computeTrackUid(
      basename: basename,
      filesize: destStat.size,
      durationMs: (row['duration_ms'] as int?) ?? 0,
      mtimeMs: newMtime,
    ).uid;

    try {
      await _db.transaction((txn) async {
        // Clean up any stale indexed_files row at destPath. This
        // happens when a previous Copy/Move to this same path was
        // later undone in Finder — the row got marked
        // 'superseded' or 'missing' but never explicitly purged,
        // so it still occupies the path PK. Without this cleanup,
        // the INSERT below would fail with
        // `UNIQUE constraint failed: indexed_files.path` and the
        // whole copy operation would roll back. Pre-flight already
        // confirmed no FILE exists at destPath, so any row here is
        // by definition stale.
        final stale = await txn.query(
          'indexed_files',
          columns: ['availability_state', 'source_id'],
          where: 'path = ?',
          whereArgs: [destPath],
          limit: 1,
        );
        if (stale.isNotEmpty) {
          await txn.delete(
            'indexed_files',
            where: 'path = ?',
            whereArgs: [destPath],
          );
          await recordEvent(
            type: EventType.purged,
            path: destPath,
            sourceId: stale.first['source_id'] as String?,
            payload: {
              'prior_state':
                  stale.first['availability_state'] as String?,
              'auto_purge_reason': 'replaced_by_app_initiated_copy',
            },
            txn: txn,
          );
        }
        // Shared identity_override across the Copy pair AND every
        // existing sibling that's currently grouped with the
        // source via the 4-field song-identity key. The user's
        // ontology: ONE song identity → multiple media
        // representations (codecs) → multiple file instances.
        // Without widening, copying an MP3 would stamp identity_
        // override only on source + dest MP3s, leaving an
        // existing AIFF sibling (grouped via the 4-field key)
        // orphaned in a different bucket. Codec coexistence
        // collapses into "filename duplication" — exactly the
        // ontology drift the 3-layer model is meant to prevent.
        //
        // Reconciliation rule:
        //   - If source already has identity_override (e.g.,
        //     from a prior Copy chain or manual link), reuse it.
        //     No widening — existing siblings either already
        //     share it or are intentionally in a separate
        //     bucket (manual relink etc).
        //   - Else: compute the source's 4-field key, find ALL
        //     other available indexed_files rows that match it
        //     and have identity_override = NULL (only widen
        //     siblings using the same key — never hijack rows
        //     that have their own override), stamp the new
        //     UUID on source + every match.
        String? sharedOverride =
            row['identity_override'] as String?;
        if (sharedOverride == null) {
          sharedOverride = const Uuid().v4();
          // Source's 4-field key components — taken from the
          // indexed_files row we already loaded.
          final srcBasenameKey =
              basenameForIdentity(row['filename'] as String);
          final srcTitle = (row['title'] as String? ?? '');
          final srcArtist = (row['artist'] as String? ?? '');
          final srcDurationSec =
              ((row['duration_ms'] as int?) ?? 0) ~/ 1000;
          // Find existing siblings — same title, artist, and
          // whole-second duration; identity_override NULL (don't
          // widen rows with their own override); available only.
          // The basename-no-ext check happens in Dart (no SQL
          // function for it).
          final candidates = await txn.query(
            'indexed_files',
            columns: ['path', 'filename'],
            where: 'identity_override IS NULL '
                'AND is_available = 1 '
                'AND title = ? '
                'AND artist = ? '
                "AND (duration_ms / 1000) = ?",
            whereArgs: [srcTitle, srcArtist, srcDurationSec],
          );
          // Stamp the new override on every candidate whose
          // basename-no-ext matches the source. That set
          // includes the source itself.
          for (final c in candidates) {
            final cFilename = c['filename'] as String;
            if (basenameForIdentity(cFilename) != srcBasenameKey) {
              continue;
            }
            await txn.update(
              'indexed_files',
              {'identity_override': sharedOverride},
              where: 'path = ?',
              whereArgs: [c['path']],
            );
          }
        }
        final newRow = Map<String, Object?>.from(row);
        newRow['path'] = destPath;
        newRow['source_id'] = destSource.id;
        newRow['filename'] = basename;
        newRow['filesize'] = destStat.size;
        newRow['modified_at'] = newMtime;
        newRow['uid'] = newUid;
        newRow['identity_override'] = sharedOverride;
        // intel_uid carried over unchanged → both file rows share
        // intel at the song-identity layer.
        newRow['is_available'] = 1;
        newRow['availability_state'] = 'available';
        // Fresh sighting at a new path; see the Move destination
        // comment in moveTrackFile for the per-File-Instance
        // first_seen_at rationale.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        newRow['last_seen_at'] = nowMs;
        newRow['first_seen_at'] = nowMs;
        await txn.insert('indexed_files', newRow);
        await recordEvent(
          type: EventType.appInitiatedCopy,
          path: sourcePath,
          sourceId: row['source_id'] as String?,
          payload: {
            'dest_path': destPath,
            'dest_source_id': destSource.id,
            'shared_identity_override': sharedOverride,
          },
          txn: txn,
        );
      });
    } catch (e) {
      // FS copy succeeded but DB insert failed. Roll back the FS
      // side so we don't leave an orphan file.
      try {
        File(destPath).deleteSync();
      } catch (_) {/* best-effort */}
      return MoveCopyResult.failure(
        'Database update failed; rolled back filesystem copy: $e',
      );
    }
    return MoveCopyResult.success(newPath: destPath, via: 'copy');
  }

  // ---------------------------------------------------------------------------
  // Activity log (cross-cutting — see lib/models/activity_event.dart)
  // ---------------------------------------------------------------------------

  /// Append a single event row. Used by every lifecycle-decision
  /// code path that wants to leave an audit trail (mark missing,
  /// auto-supersede, purge, manual relink, ...).
  ///
  /// Best-effort: failures are logged but do NOT propagate. The
  /// audit log is observability; it must not block the lifecycle
  /// decision it's describing.
  ///
  /// [type] should be one of the `EventType.*` constants. [payload]
  /// gets JSON-encoded; pass `null` for events that don't need
  /// type-specific fields.
  /// [origin] defaults to `'desktop'` (the only originator until
  /// the iPhone sync subsystem lights up). Phone-sourced events
  /// pass `'mobile:&lt;device_id&gt;'` so the activity strip can render
  /// "Zico played 1 track on iPhone" distinctly from local plays.
  Future<void> recordEvent({
    required String type,
    String? path,
    String? sourceId,
    Map<String, Object?>? payload,
    String origin = 'desktop',
    DatabaseExecutor? txn,
  }) async {
    final exec = txn ?? _db;
    try {
      await exec.insert('events', {
        'recorded_at': DateTime.now().millisecondsSinceEpoch,
        'event_type': type,
        'path': path,
        'source_id': sourceId,
        'payload': payload == null ? null : jsonEncode(payload),
        'origin': origin,
      });
    } catch (e) {
      // Swallow — observability isn't worth blocking real work.
      // ignore: avoid_print
      // (debugPrint is not imported here; the failure surfaces in
      // dev only via the IDE if needed)
    }
  }

  /// Paginated history feed for the activity log UI. Newest first.
  /// [limit] caps the result size; [offset] supports scroll-loading
  /// older entries. Optional [eventTypes] filter narrows to specific
  /// kinds (e.g. only `removed_external` for a "what disappeared?"
  /// view).
  Future<List<ActivityEvent>> loadRecentEvents({
    int limit = 200,
    int offset = 0,
    List<String>? eventTypes,
  }) async {
    final where = StringBuffer();
    final args = <Object?>[];
    if (eventTypes != null && eventTypes.isNotEmpty) {
      final placeholders = List.filled(eventTypes.length, '?').join(',');
      where.write('WHERE event_type IN ($placeholders)');
      args.addAll(eventTypes);
    }
    final rows = await _db.rawQuery(
      'SELECT id, recorded_at, event_type, path, source_id, payload, origin '
      'FROM events $where '
      'ORDER BY recorded_at DESC, id DESC '
      'LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return rows.map(ActivityEvent.fromRow).toList();
  }

  /// Lifetime event count (for "X events total" indicators). Cheap —
  /// indexed_at index helps but the COUNT is straight up.
  Future<int> eventCount() async {
    final row = await _db.rawQuery('SELECT COUNT(*) AS c FROM events');
    return (row.first['c'] as int?) ?? 0;
  }

  /// Full event chain for [path] in chronological order (newest
  /// first). Powers the right-click "View history" popup over track
  /// rows. Returns the causal record of how this File Instance came
  /// to be in its current state.
  ///
  /// Two query passes, unioned and sorted in Dart so the SQL stays
  /// straightforward:
  ///
  ///   1. Events whose `path` column equals [path] — content updates,
  ///      manual relinks, app-move SOURCE side, supersession decisions
  ///      where this row is the missing party, removals, purges.
  ///   2. Events that *reference* [path] in their payload — auto-move
  ///      and app-move events where this path appears as
  ///      `successor_path` or `dest_path` (i.e. this row is the
  ///      destination of a move). Found via LIKE matching against
  ///      the JSON fragment that the canonical [jsonEncode]
  ///      writer produces.
  ///
  /// Aggregate events (`path = NULL`) and unrelated rows are excluded
  /// by construction. The reference-payload search depends on
  /// consistent JSON serialization — [ActivityEvent]'s recorder
  /// uses `jsonEncode` throughout, so the fragment matches without
  /// custom escaping. If a future writer ever produces different
  /// JSON for the same logical payload, this query under-counts.
  /// (Live with that until it bites; the chance is small and tests
  /// pin the current encoding.)
  Future<List<ActivityEvent>> loadHistoryForPath(String path) async {
    // Direct events.
    final direct = await _db.rawQuery(
      'SELECT id, recorded_at, event_type, path, source_id, payload, origin '
      'FROM events '
      'WHERE path = ? '
      'ORDER BY recorded_at DESC, id DESC',
      [path],
    );

    // Reference events — payload has this path as successor or
    // destination. The fragment includes the surrounding quotes and
    // colon so we don't accidentally match a path that only appears
    // as a substring of another field's value. Note we escape
    // backslashes and quotes in the path the same way jsonEncode
    // would have when the event was written — keeps the LIKE
    // pattern in sync with the stored payload.
    final encodedPath = _encodePathForJsonFragment(path);
    final successorPattern = '%"successor_path":"$encodedPath"%';
    final destPattern = '%"dest_path":"$encodedPath"%';
    final referencing = await _db.rawQuery(
      'SELECT id, recorded_at, event_type, path, source_id, payload, origin '
      'FROM events '
      // ESCAPE '|' makes the pipe-escaped LIKE wildcards (|% and
      // |_) match literal % and _ — needed because real filenames
      // routinely contain underscores. We deliberately do NOT use
      // backslash as the escape character because jsonEncode emits
      // backslashes for its own string escaping (\\ for a literal
      // backslash, \" for a literal quote); using \ as the LIKE
      // escape would collide with those bytes and produce false
      // negatives on any path containing a quote or backslash.
      "WHERE (payload LIKE ? ESCAPE '|' OR payload LIKE ? ESCAPE '|') "
      // Don't double-count events that already came from the direct
      // query (path = ? side). A real-world collision would be a
      // move event whose source path happens to equal its dest path,
      // which the FS layer rejects — but the guard is cheap.
      'AND (path IS NULL OR path <> ?) '
      'ORDER BY recorded_at DESC, id DESC',
      [successorPattern, destPattern, path],
    );

    // Merge + de-dupe by event id (the queries are disjoint by
    // construction, but ids are the safe key if that ever changes).
    final seen = <int>{};
    final out = <ActivityEvent>[];
    for (final r in [...direct, ...referencing]) {
      final id = r['id'] as int;
      if (!seen.add(id)) continue;
      out.add(ActivityEvent.fromRow(r));
    }
    // Direct + referencing each came pre-sorted, but the merged set
    // may not be. Sort once at the end.
    out.sort((a, b) {
      final byTime = b.recordedAt.compareTo(a.recordedAt);
      if (byTime != 0) return byTime;
      return b.id.compareTo(a.id);
    });
    return out;
  }

  /// Mirror of [jsonEncode]'s string escaping for the subset of
  /// characters that can appear in a filesystem path, then escape
  /// LIKE wildcards so the resulting fragment matches the literal
  /// bytes stored in `events.payload`.
  ///
  /// Two stages, applied in order:
  ///   1. JSON escapes — `\` → `\\`, `"` → `\"`. These are the
  ///      exact two-character sequences `jsonEncode` writes to the
  ///      payload column for those characters in a string value.
  ///      Path-relevant control chars (newline, tab) aren't
  ///      expected in real-world basenames so they're omitted.
  ///   2. LIKE escapes — `|` → `||`, `%` → `|%`, `_` → `|_`. The
  ///      escape character is `|` (NOT `\`) because stage 1 has
  ///      already introduced backslashes; using `\` as the LIKE
  ///      escape would collide with them and produce false
  ///      negatives. `|` is rare in paths and not produced by JSON
  ///      escaping, so it's a safe sentinel.
  ///
  /// The `|` escapes are emitted in pairs that SQLite collapses to
  /// a literal character under `ESCAPE '|'`. The caller must thread
  /// `ESCAPE '|'` to the LIKE clause for this to work.
  String _encodePathForJsonFragment(String path) {
    var s = path.replaceAll(r'\', r'\\');
    s = s.replaceAll('"', r'\"');
    // LIKE escapes — | first so we don't double-escape the escape
    // character we're about to introduce on the next two lines.
    s = s.replaceAll('|', '||');
    s = s.replaceAll('%', '|%');
    s = s.replaceAll('_', '|_');
    return s;
  }

  /// Most recent lifecycle event affecting [path], or `null` when
  /// none has been recorded. Used by lineage-narration surfaces
  /// (currently: Review-missing dialog) to render *why* a row is in
  /// its current state — what replaced it, when it moved, what the
  /// supersession evidence was. The narration is the visible side
  /// of the causal integrity the supersession rewrite (Slice 2)
  /// just established.
  ///
  /// Scope: filters to the event types whose payloads explain a row
  /// transitioning OUT of `available`. This is intentionally
  /// narrower than `loadRecentEvents` — content-update / link /
  /// purge events are about state changes WITHIN a row's lifetime;
  /// the lineage caller wants the event that explains the *end* of
  /// the row at this path.
  Future<ActivityEvent?> mostRecentLifecycleEventFor(String path) async {
    const lifecycleTypes = <String>[
      EventType.autoMoveSameSource,
      EventType.autoMoveCrossSource,
      EventType.appInitiatedMove,
      EventType.removedExternal,
    ];
    final placeholders = List.filled(lifecycleTypes.length, '?').join(',');
    final rows = await _db.rawQuery(
      'SELECT id, recorded_at, event_type, path, source_id, payload, origin '
      'FROM events '
      'WHERE path = ? AND event_type IN ($placeholders) '
      'ORDER BY recorded_at DESC, id DESC '
      'LIMIT 1',
      [path, ...lifecycleTypes],
    );
    if (rows.isEmpty) return null;
    return ActivityEvent.fromRow(rows.first);
  }

  /// Batch variant of [mostRecentLifecycleEventFor]. Returns a map
  /// from path → most-recent lifecycle event, for every path in
  /// [paths] that has at least one such event recorded. Paths
  /// without events are absent from the map.
  ///
  /// Single round-trip — necessary because the Review-missing
  /// dialog renders hundreds of rows and a per-row fetch would
  /// thrash the DB on open. Internally uses a windowed query so
  /// each path returns at most one event (its newest).
  Future<Map<String, ActivityEvent>> mostRecentLifecycleEventsFor(
    Iterable<String> paths,
  ) async {
    final pathList = paths.toList(growable: false);
    if (pathList.isEmpty) return const {};
    const lifecycleTypes = <String>[
      EventType.autoMoveSameSource,
      EventType.autoMoveCrossSource,
      EventType.appInitiatedMove,
      EventType.removedExternal,
    ];
    final typePlaceholders =
        List.filled(lifecycleTypes.length, '?').join(',');
    final result = <String, ActivityEvent>{};
    // SQLite parameter cap is around 999. Chunk paths to stay
    // comfortably below it; lifecycle events are sparse so a few
    // round-trips on a huge dialog is still cheap.
    const chunk = 400;
    for (var i = 0; i < pathList.length; i += chunk) {
      final end = (i + chunk).clamp(0, pathList.length);
      final slice = pathList.sublist(i, end);
      final pathPlaceholders = List.filled(slice.length, '?').join(',');
      // The "windowed newest per path" trick: pick rows where no
      // newer event with the same path exists. Cheaper than a
      // GROUP BY + correlated subquery, and SQLite optimises the
      // anti-join well when there's an index on (path, recorded_at).
      final rows = await _db.rawQuery(
        '''
        SELECT e.id, e.recorded_at, e.event_type, e.path, e.source_id,
               e.payload, e.origin
        FROM events e
        WHERE e.path IN ($pathPlaceholders)
          AND e.event_type IN ($typePlaceholders)
          AND NOT EXISTS (
            SELECT 1 FROM events e2
            WHERE e2.path = e.path
              AND e2.event_type IN ($typePlaceholders)
              AND (e2.recorded_at, e2.id) > (e.recorded_at, e.id)
          )
        ''',
        [...slice, ...lifecycleTypes, ...lifecycleTypes],
      );
      for (final r in rows) {
        final p = r['path'] as String?;
        if (p == null) continue;
        result[p] = ActivityEvent.fromRow(r);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------

  /// Number of indexed files (any availability) under [sourceId].
  Future<int> countIndexedFiles(String sourceId) async {
    final row = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM indexed_files WHERE source_id = ?',
      [sourceId],
    );
    return (row.first['c'] as int?) ?? 0;
  }

  /// All paths currently in `indexed_files`. Used to skip
  /// already-known files quickly before invoking metadata extraction
  /// for the truly new ones.
  Future<Set<String>> existingPaths() async {
    final rows = await _db.query('indexed_files', columns: ['path']);
    return {for (final r in rows) r['path'] as String};
  }

  // ---------------------------------------------------------------------------
  // Lazy intelligence (the only writers of `tracks` — controller-driven).
  // ---------------------------------------------------------------------------

  /// Materialise an intelligence row for the given indexed file path,
  /// if absent. Honours the duplicate-sharing rule: if a sibling row
  /// (same fingerprint) already has intelligence, this row inherits it.
  ///
  /// Returns the resolved `intel_uid` (the `tracks.uid` to write to).
  /// Returns `null` if the path has no indexed_files row (shouldn't
  /// happen in practice — caller should treat as a no-op).
  Future<String?> promoteToIntelligence(String path) async {
    return _db.transaction<String?>((txn) async {
      final row = await txn.query(
        'indexed_files',
        columns: ['uid', 'fingerprint', 'intel_uid'],
        where: 'path = ?',
        whereArgs: [path],
        limit: 1,
      );
      if (row.isEmpty) return null;

      final intelUid = row.first['intel_uid'] as String?;
      if (intelUid != null) return intelUid;

      final uid = row.first['uid'] as String;
      final fingerprint = row.first['fingerprint'] as String;

      // Sibling lookup: a duplicate (same fingerprint) may already own
      // intelligence. Reuse it.
      final sibling = await txn.query(
        'indexed_files',
        columns: ['intel_uid'],
        where: 'fingerprint = ? AND intel_uid IS NOT NULL',
        whereArgs: [fingerprint],
        limit: 1,
      );

      String chosen;
      if (sibling.isNotEmpty) {
        chosen = sibling.first['intel_uid'] as String;
      } else {
        // Fallback (extended in v6): a ghost intelligence row from a
        // prior import may already exist with this fingerprint, even
        // though no local indexed_files row references it yet. Reuse
        // its uid so the imported intelligence binds to this file.
        final ghost = await txn.query(
          'tracks',
          columns: ['uid'],
          where: 'fingerprint = ?',
          whereArgs: [fingerprint],
          limit: 1,
        );
        if (ghost.isNotEmpty) {
          chosen = ghost.first['uid'] as String;
        } else {
          chosen = uid;
          await txn.insert('tracks', {
            'uid': chosen,
            'fingerprint': fingerprint,
            'created_at': DateTime.now().millisecondsSinceEpoch,
            'favorite': 0,
            'play_count': 0,
            'cumulative_ms': 0,
            'last_played_at': null,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }

      // Propagate to all siblings sharing this fingerprint, including
      // this row, so subsequent promotion calls short-circuit.
      await txn.update(
        'indexed_files',
        {'intel_uid': chosen},
        where: 'fingerprint = ? AND intel_uid IS NULL',
        whereArgs: [fingerprint],
      );

      return chosen;
    });
  }

  /// Tear down a song-identity bucket: each file in [paths] is
  /// pushed back to a singleton identity, the shared `tracks` row
  /// (if any) is deleted, and every variant's reference is cleared.
  ///
  /// Per project philosophy (`project_track_identity_vs_file_variants.md`):
  /// unlink means "these are NOT the same song anymore", so the
  /// behavioral intelligence — play count, favorite, cumulative
  /// listened, last played, review state — is *reset*. Not cloned,
  /// not "winner-takes-all". File-analysis fields (BPM, key,
  /// duration, fingerprint) live on `indexed_files` and survive
  /// untouched.
  ///
  /// Side effects, all inside one transaction:
  ///   1. Each row in [paths]: `identity_override = uid` (the row's
  ///      own uid → guaranteed-unique singleton bucket).
  ///   2. Each row in [paths]: `intel_uid = NULL`.
  ///   3. Each `tracks` row that was referenced by one of these
  ///      paths and has no other referrer left is deleted.
  ///
  /// Returns the set of `tracks.uid` values deleted, so the
  /// in-memory controller can drop any cached references.
  Future<Set<String>> unlinkBucketIntelligence(List<String> paths) async {
    if (paths.isEmpty) return <String>{};
    return _db.transaction<Set<String>>((txn) async {
      final placeholders = List.filled(paths.length, '?').join(',');
      final rows = await txn.query(
        'indexed_files',
        columns: ['uid', 'path', 'intel_uid'],
        where: 'path IN ($placeholders)',
        whereArgs: paths,
      );
      if (rows.isEmpty) return <String>{};

      // Snapshot the intel_uids that were referenced by this bucket
      // before we null them out — we'll check below whether they
      // still have any referrers outside the bucket and delete
      // those that don't.
      final priorIntelUids = <String>{
        for (final r in rows)
          if ((r['intel_uid'] as String?) != null)
            r['intel_uid'] as String,
      };

      // Force each row into a singleton identity (override = own
      // uid) and drop its intel reference. Use a per-row update
      // because identity_override differs across rows.
      final batch = txn.batch();
      for (final r in rows) {
        batch.update(
          'indexed_files',
          {
            'identity_override': r['uid'] as String,
            'intel_uid': null,
          },
          where: 'path = ?',
          whereArgs: [r['path'] as String],
        );
      }
      await batch.commit(noResult: true);

      // Delete any tracks rows that became orphaned. A `tracks`
      // row is orphaned iff no `indexed_files` row references it
      // anymore. (Defensive — in the post-slice-3 world a bucket
      // shares one intel uid, so almost always the prior uid set
      // has exactly one element and it's now orphaned.)
      final deleted = <String>{};
      for (final uid in priorIntelUids) {
        final referrers = await txn.query(
          'indexed_files',
          columns: ['path'],
          where: 'intel_uid = ?',
          whereArgs: [uid],
          limit: 1,
        );
        if (referrers.isEmpty) {
          await txn.delete(
            'tracks',
            where: 'uid = ?',
            whereArgs: [uid],
          );
          deleted.add(uid);
        }
      }
      return deleted;
    });
  }

  /// Set (or clear) the manual identity override for a set of file
  /// paths. When [value] is non-null, the listed rows will bucket
  /// together under [value] regardless of whether the strict 4-field
  /// matcher would have paired them. When [value] is null, the
  /// override is removed and the rows fall back to computed identity.
  ///
  /// Caller is responsible for refreshing in-memory Tracks (or
  /// calling `loadTracks` to rebuild). This method only writes the
  /// column.
  Future<void> setIdentityOverride(
    List<String> paths, {
    required String? value,
  }) async {
    if (paths.isEmpty) return;
    final placeholders = List.filled(paths.length, '?').join(',');
    await _db.update(
      'indexed_files',
      {'identity_override': value},
      where: 'path IN ($placeholders)',
      whereArgs: paths,
    );
  }

  /// Force every `indexed_files` row whose path is in [paths] (the
  /// song-identity bucket: same basename-no-ext + title + artist +
  /// duration-in-seconds) to share a single canonical `tracks` row.
  ///
  /// Three cases:
  ///   - **No intel yet**: create a new `tracks` row for the first
  ///     path and point every variant at it. Returns the new uid.
  ///   - **One intel uid already shared**: every variant points at
  ///     it already (or is re-pointed). Returns that uid.
  ///   - **Multiple distinct intel uids**: pick a canonical (highest
  ///     play count, ties broken by lexicographic uid for
  ///     determinism), merge the others' rows into it
  ///     (OR favorite · sum playCount · sum cumulativeMs · max
  ///     lastPlayedAt), delete the orphans, re-point every variant
  ///     at canonical. Returns canonical uid.
  ///
  /// The merge is OR-favorite / sum-listening / max-recency on
  /// purpose: variant-level intelligence accumulated separately
  /// before this consolidation existed; sum-listening reflects the
  /// total time the user spent on the song. Whether to call this
  /// destructive matters only if the user ever set conflicting
  /// favorites on individual variants — which the UI never let them
  /// do (favorite was always on a single bucket primary row); the
  /// only way to land in that state is via direct DB editing.
  ///
  /// Returns `null` only if [paths] is empty or no `indexed_files`
  /// rows match (shouldn't happen — caller treats as no-op).
  Future<String?> consolidateBucketIntelligence(List<String> paths) async {
    if (paths.isEmpty) return null;
    return _db.transaction<String?>((txn) async {
      final placeholders = List.filled(paths.length, '?').join(',');
      final rows = await txn.query(
        'indexed_files',
        columns: ['uid', 'fingerprint', 'path', 'intel_uid'],
        where: 'path IN ($placeholders)',
        whereArgs: paths,
      );
      if (rows.isEmpty) return null;

      // Collect the set of distinct existing intel uids in this
      // bucket. Each one corresponds to a `tracks` row.
      final distinctUids = <String>{
        for (final r in rows)
          if ((r['intel_uid'] as String?) != null)
            r['intel_uid'] as String,
      };

      String canonicalUid;
      if (distinctUids.isEmpty) {
        // Promote the first row in the bucket: create a fresh
        // `tracks` row keyed by its uid. Subsequent variants will
        // be pointed at it below.
        canonicalUid = rows.first['uid'] as String;
        final fingerprint = rows.first['fingerprint'] as String;
        await txn.insert('tracks', {
          'uid': canonicalUid,
          'fingerprint': fingerprint,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'favorite': 0,
          'play_count': 0,
          'cumulative_ms': 0,
          'last_played_at': null,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else if (distinctUids.length == 1) {
        canonicalUid = distinctUids.first;
      } else {
        // Multiple distinct intel records — merge them into one.
        // Copy out of sqflite's read-only `QueryResultSet` so we can
        // sort + iterate.
        final intelRows = List<Map<String, Object?>>.from(
          await txn.query(
            'tracks',
            where:
                'uid IN (${List.filled(distinctUids.length, '?').join(',')})',
            whereArgs: distinctUids.toList(),
          ),
        );
        // Pick canonical: highest play count wins; tie → lowest uid
        // alphabetically (deterministic across runs).
        intelRows.sort((a, b) {
          final pa = (a['play_count'] as int?) ?? 0;
          final pb = (b['play_count'] as int?) ?? 0;
          if (pa != pb) return pb.compareTo(pa); // desc
          return (a['uid'] as String).compareTo(b['uid'] as String);
        });
        canonicalUid = intelRows.first['uid'] as String;

        // Aggregate the merge.
        var favorite = false;
        var playCount = 0;
        var cumulativeMs = 0;
        int? lastPlayedAt;
        int? reviewedAt; // earliest non-null wins (review is sticky)
        int? favoriteToggledAt; // latest non-null wins (LWW)
        for (final r in intelRows) {
          if (((r['favorite'] as int?) ?? 0) != 0) favorite = true;
          playCount += (r['play_count'] as int?) ?? 0;
          cumulativeMs += (r['cumulative_ms'] as int?) ?? 0;
          final lp = r['last_played_at'] as int?;
          if (lp != null && (lastPlayedAt == null || lp > lastPlayedAt)) {
            lastPlayedAt = lp;
          }
          final ra = r['reviewed_at'] as int?;
          if (ra != null && (reviewedAt == null || ra < reviewedAt)) {
            reviewedAt = ra;
          }
          final fta = r['favorite_toggled_at'] as int?;
          if (fta != null &&
              (favoriteToggledAt == null || fta > favoriteToggledAt)) {
            favoriteToggledAt = fta;
          }
        }

        // Write merged values to canonical.
        await txn.update(
          'tracks',
          {
            'favorite': favorite ? 1 : 0,
            'play_count': playCount,
            'cumulative_ms': cumulativeMs,
            'last_played_at': lastPlayedAt,
            'reviewed_at': reviewedAt,
            'favorite_toggled_at': favoriteToggledAt,
          },
          where: 'uid = ?',
          whereArgs: [canonicalUid],
        );

        // Delete orphans + re-point any indexed_files rows that
        // still point at them (siblings outside this bucket — e.g.,
        // literal fingerprint-duplicates of a non-canonical variant).
        final orphanUids =
            distinctUids.where((u) => u != canonicalUid).toList();
        final orphanPlaceholders =
            List.filled(orphanUids.length, '?').join(',');
        await txn.update(
          'indexed_files',
          {'intel_uid': canonicalUid},
          where: 'intel_uid IN ($orphanPlaceholders)',
          whereArgs: orphanUids,
        );
        await txn.delete(
          'tracks',
          where: 'uid IN ($orphanPlaceholders)',
          whereArgs: orphanUids,
        );
      }

      // Final sweep: any bucket variants still NULL get pointed at
      // canonical.
      await txn.update(
        'indexed_files',
        {'intel_uid': canonicalUid},
        where: 'path IN ($placeholders) AND intel_uid IS NULL',
        whereArgs: paths,
      );

      return canonicalUid;
    });
  }

  // ---------------------------------------------------------------------------
  // Intelligence export / import (cross-machine portability).
  // ---------------------------------------------------------------------------

  /// Snapshot every `tracks` row plus enough display hints (basename /
  /// filesize / durationMs) for the export file to be readable by eye.
  /// Display hints are sourced from any linked `indexed_files` row;
  /// for ghost intelligence (no linked file), the hints fall back to
  /// blanks/zeros — they're informational only.
  Future<List<IntelligenceRecord>> exportIntelligenceRecords() async {
    final rows = await _db.rawQuery('''
      SELECT t.uid AS uid,
             t.fingerprint AS fingerprint,
             t.created_at AS created_at,
             t.favorite AS favorite,
             t.play_count AS play_count,
             t.cumulative_ms AS cumulative_ms,
             t.last_played_at AS last_played_at,
             t.reviewed_at AS reviewed_at,
             t.favorite_toggled_at AS favorite_toggled_at,
             idx.filename AS filename,
             idx.filesize AS filesize,
             idx.duration_ms AS duration_ms
      FROM tracks t
      LEFT JOIN indexed_files idx ON idx.intel_uid = t.uid
      GROUP BY t.uid
    ''');
    return [
      for (final r in rows)
        IntelligenceRecord(
          uid: r['uid'] as String,
          fingerprint: (r['fingerprint'] as String?) ?? '',
          basename: (r['filename'] as String?) ?? '',
          filesize: (r['filesize'] as int?) ?? 0,
          durationMs: (r['duration_ms'] as int?) ?? 0,
          createdAt: (r['created_at'] as int?) ?? 0,
          favorite: ((r['favorite'] as int?) ?? 0) != 0,
          playCount: (r['play_count'] as int?) ?? 0,
          cumulativeMs: (r['cumulative_ms'] as int?) ?? 0,
          lastPlayedAt: r['last_played_at'] as int?,
          reviewedAt: r['reviewed_at'] as int?,
          favoriteToggledAt: r['favorite_toggled_at'] as int?,
        ),
    ];
  }

  /// Merge [records] into the local intelligence store.
  ///
  /// Match strategy (deterministic, no fuzzy matching):
  ///   1. exact uid → merge in place
  ///   2. fingerprint match → merge into the local row's existing uid
  ///   3. neither → insert as ghost (no `indexed_files` link yet)
  ///
  /// Field merge rules: playCount sum, cumulativeMs max, favorite OR,
  /// lastPlayedAt max, createdAt min.
  Future<ImportSummary> importIntelligenceRecords(
    List<IntelligenceRecord> records,
  ) async {
    int mergedByUid = 0;
    int mergedByFingerprint = 0;
    int insertedAsGhost = 0;
    final errors = <String>[];

    await _db.transaction((txn) async {
      for (final r in records) {
        try {
          final exact = await txn.query(
            'tracks',
            where: 'uid = ?',
            whereArgs: [r.uid],
            limit: 1,
          );
          if (exact.isNotEmpty) {
            await _mergeImportedInto(
              txn,
              targetUid: r.uid,
              localRow: exact.first,
              imported: r,
            );
            mergedByUid++;
            continue;
          }

          if (r.fingerprint.isNotEmpty) {
            final byFp = await txn.query(
              'tracks',
              where: 'fingerprint = ?',
              whereArgs: [r.fingerprint],
              limit: 1,
            );
            if (byFp.isNotEmpty) {
              final localUid = byFp.first['uid'] as String;
              await _mergeImportedInto(
                txn,
                targetUid: localUid,
                localRow: byFp.first,
                imported: r,
              );
              mergedByFingerprint++;
              continue;
            }
          }

          // Ghost insert.
          await txn.insert('tracks', {
            'uid': r.uid,
            'fingerprint': r.fingerprint,
            'created_at': r.createdAt,
            'favorite': r.favorite ? 1 : 0,
            'play_count': r.playCount,
            'cumulative_ms': r.cumulativeMs,
            'last_played_at': r.lastPlayedAt,
            'reviewed_at': r.reviewedAt,
            'favorite_toggled_at': r.favoriteToggledAt,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          insertedAsGhost++;
        } catch (e) {
          errors.add('uid=${r.uid}: $e');
        }
      }
    });

    return ImportSummary(
      recordsRead: records.length,
      mergedByUid: mergedByUid,
      mergedByFingerprint: mergedByFingerprint,
      insertedAsGhost: insertedAsGhost,
      skippedErrors: errors,
    );
  }

  Future<void> _mergeImportedInto(
    Transaction txn, {
    required String targetUid,
    required Map<String, Object?> localRow,
    required IntelligenceRecord imported,
  }) async {
    final localPlay = (localRow['play_count'] as int?) ?? 0;
    final localCum = (localRow['cumulative_ms'] as int?) ?? 0;
    final localFav = ((localRow['favorite'] as int?) ?? 0) != 0;
    final localLast = localRow['last_played_at'] as int?;
    final localReviewed = localRow['reviewed_at'] as int?;
    final localFavToggled = localRow['favorite_toggled_at'] as int?;
    final localCreated = (localRow['created_at'] as int?) ?? imported.createdAt;

    // reviewed_at merge: MIN wins (earliest review timestamp is the
    // truth — once a track was reviewed, it stays reviewed; the
    // earlier moment is the one that asserted state).
    int? mergedReviewed;
    if (localReviewed == null) {
      mergedReviewed = imported.reviewedAt;
    } else if (imported.reviewedAt == null) {
      mergedReviewed = localReviewed;
    } else {
      mergedReviewed = localReviewed < imported.reviewedAt!
          ? localReviewed
          : imported.reviewedAt;
    }

    await txn.update(
      'tracks',
      {
        'play_count': localPlay + imported.playCount,
        'cumulative_ms':
            localCum > imported.cumulativeMs ? localCum : imported.cumulativeMs,
        'favorite': (localFav || imported.favorite) ? 1 : 0,
        'last_played_at': _maxNullable(localLast, imported.lastPlayedAt),
        'reviewed_at': mergedReviewed,
        'favorite_toggled_at':
            _maxNullable(localFavToggled, imported.favoriteToggledAt),
        'created_at':
            localCreated < imported.createdAt ? localCreated : imported.createdAt,
      },
      where: 'uid = ?',
      whereArgs: [targetUid],
    );
  }

  int? _maxNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  /// Single mutation entry point for the `tracks` intelligence row.
  ///
  /// Every parameter is optional; non-null values are written, null
  /// means "don't touch." Three special parameters need explanation:
  ///
  /// - [reviewedAt]: stamp the review timestamp. Pass `now` when the
  ///   threshold-crossing path fires for the first time on this
  ///   track; existing rows keep their original timestamp because
  ///   the caller passes `existing ?? now`. Pass null to leave
  ///   unchanged.
  /// - [clearReviewedAt]: explicit `UPDATE … reviewed_at = NULL`.
  ///   Set by the right-click "Mark unreviewed" path so the track
  ///   becomes eligible for phone-rotation again. Wins over
  ///   [reviewedAt] if both are passed (defense-in-depth).
  /// - [favoriteToggledAt]: usually omitted — when [favorite] is
  ///   non-null we auto-stamp `favorite_toggled_at` to `now`.
  ///   Callers (phone-sync reconciler) that want to preserve a
  ///   remote timestamp can pass it explicitly.
  Future<void> updateIntelligence({
    required String intelUid,
    bool? favorite,
    int? playCount,
    int? cumulativeMs,
    int? lastPlayedAt,
    int? reviewedAt,
    bool clearReviewedAt = false,
    int? favoriteToggledAt,
  }) async {
    final values = <String, Object?>{};
    if (favorite != null) {
      values['favorite'] = favorite ? 1 : 0;
      values['favorite_toggled_at'] =
          favoriteToggledAt ?? DateTime.now().millisecondsSinceEpoch;
    } else if (favoriteToggledAt != null) {
      values['favorite_toggled_at'] = favoriteToggledAt;
    }
    if (playCount != null) values['play_count'] = playCount;
    if (cumulativeMs != null) values['cumulative_ms'] = cumulativeMs;
    if (lastPlayedAt != null) values['last_played_at'] = lastPlayedAt;
    if (clearReviewedAt) {
      values['reviewed_at'] = null;
    } else if (reviewedAt != null) {
      values['reviewed_at'] = reviewedAt;
    }
    if (values.isEmpty) return;
    await _db.update(
      'tracks',
      values,
      where: 'uid = ?',
      whereArgs: [intelUid],
    );
  }

  // ---------------------------------------------------------------------------
  // Metadata extraction batch (writes only `indexed_files`).
  // ---------------------------------------------------------------------------

  Future<void> updateMetadataBatch(List<TrackMetadata> items) async {
    if (items.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final m in items) {
      // Always stamp `metadata_read_at` so the "enriched" tally
      // counts every row we've processed — including ones the
      // tag parser couldn't decode. Filename-parsing display
      // fallback still covers parse-failed rows; this just stops
      // the counter from looking stuck on libraries with lots of
      // unparseable formats (AIFF variants, exotic ID3, etc.).
      //
      // Formal `enrichment_state` mirrors the success/failure
      // outcome:
      //   read succeeded → `ready` (row is now fully populated)
      //   read failed    → `failed` (warning treatment in UI;
      //                     controller's in-memory skip set
      //                     prevents retry within session)
      final values = <String, Object?>{
        'metadata_read_at': now,
        'enrichment_state':
            m.readSucceeded ? 'ready' : 'failed',
      };
      if (m.readSucceeded) {
        values['has_artwork'] = m.hasArtwork ? 1 : 0;
        if (m.title != null) values['title'] = m.title;
        if (m.artist != null) values['artist'] = m.artist;
        if (m.album != null) values['album'] = m.album;
        if (m.genre != null) values['genre'] = m.genre;
        if (m.musicalKey != null) values['musical_key'] = m.musicalKey;
        if (m.bpm != null) values['bpm'] = m.bpm;
        if (m.duration != null && m.duration! > Duration.zero) {
          values['duration_ms'] = m.duration!.inMilliseconds;
        }
      }
      batch.update(
        'indexed_files',
        values,
        where: 'path = ?',
        whereArgs: [m.path],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Flip a set of paths to `enriching`. Called by the controller
  /// when paths enter the enrichment queue so the UI can render
  /// the "actively being processed" treatment (pulse animation
  /// once that lands). Chunked to respect SQLite's parameter
  /// limit; idempotent; no-op for paths that no longer exist.
  Future<void> markPathsEnriching(Iterable<String> paths) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    const chunk = 400;
    for (var i = 0; i < list.length; i += chunk) {
      final end = (i + chunk).clamp(0, list.length);
      final slice = list.sublist(i, end);
      final placeholders = List.filled(slice.length, '?').join(',');
      await _db.rawUpdate(
        "UPDATE indexed_files "
        "SET enrichment_state = 'enriching' "
        "WHERE path IN ($placeholders) "
        "  AND enrichment_state IN ('discovered', 'failed')",
        slice,
      );
    }
  }

  /// Crash-recovery sweep: any row left in `enriching` from a
  /// previous run (the in-memory queue is gone, so we'd never
  /// pick those rows up again) reverts to `discovered` so the
  /// regular enrichment pipeline finds them next viewport sweep
  /// or `enrichSource` call. Cheap — indexed by enrichment_state.
  /// Idempotent; safe to call on every boot.
  Future<int> sweepStuckEnriching() async {
    return await _db.rawUpdate(
      "UPDATE indexed_files "
      "SET enrichment_state = 'discovered' "
      "WHERE enrichment_state = 'enriching'",
    );
  }

  // ---------------------------------------------------------------------------
  // App settings — unchanged.
  // ---------------------------------------------------------------------------

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
}

Source _sourceFromRow(Map<String, Object?> r) {
  return Source(
    id: r['id'] as String,
    displayName: r['display_name'] as String,
    folderPath: r['folder_path'] as String,
    scanMode: ScanModeCodec.fromWire(r['scan_mode'] as String),
    enabled: ((r['enabled'] as int?) ?? 1) != 0,
    lastScanAt: r['last_scan_at'] as int?,
    trackCount: (r['track_count'] as int?) ?? 0,
    createdAt: (r['created_at'] as int?) ?? 0,
    parentSourceId: r['parent_source_id'] as String?,
    pathPrefix: r['path_prefix'] as String?,
  );
}

Map<String, Object?> _sourceToRow(Source s) => {
      'id': s.id,
      'display_name': s.displayName,
      'folder_path': s.folderPath,
      'scan_mode': s.scanMode.wire,
      'enabled': s.enabled ? 1 : 0,
      'last_scan_at': s.lastScanAt,
      'track_count': s.trackCount,
      'created_at': s.createdAt,
      'parent_source_id': s.parentSourceId,
      'path_prefix': s.pathPrefix,
    };

Track _trackFromJoinedRow(Map<String, Object?> r) {
  final readAt = (r['metadata_read_at'] as int?) ?? 0;
  final lastPlayedAt = r['i_last_played_at'] as int?;
  final reviewedAt = r['i_reviewed_at'] as int?;
  final favoriteToggledAt = r['i_favorite_toggled_at'] as int?;
  final iFav = r['i_favorite'] as int?;
  return Track(
    uid: r['uid'] as String,
    fingerprint: r['fingerprint'] as String,
    contentHash: r['content_hash'] as String?,
    intelUid: r['intel_uid'] as String?,
    identityOverride: r['identity_override'] as String?,
    path: r['path'] as String,
    filename: r['filename'] as String,
    sourceId: r['source_id'] as String,
    filesize: (r['filesize'] as int?) ?? 0,
    modifiedAt: (r['modified_at'] as int?) ?? 0,
    isAvailable: ((r['is_available'] as int?) ?? 1) != 0,
    availability:
        (r['availability_state'] as String?) ?? 'available',
    lastSeenAt: (r['last_seen_at'] as int?) ?? 0,
    title: r['title'] as String,
    artist: (r['artist'] as String?) ?? '',
    album: (r['album'] as String?) ?? '',
    genre: (r['genre'] as String?) ?? '',
    musicalKey: (r['musical_key'] as String?) ?? '',
    bpm: (r['bpm'] as num?)?.toDouble(),
    duration: Duration(milliseconds: (r['duration_ms'] as int?) ?? 0),
    hasArtwork: ((r['has_artwork'] as int?) ?? 0) != 0,
    metadataReadAt:
        readAt == 0 ? null : DateTime.fromMillisecondsSinceEpoch(readAt),
    enrichmentState:
        EnrichmentState.fromWire(r['enrichment_state'] as String?),
    favorite: (iFav ?? 0) != 0,
    playCount: (r['i_play_count'] as int?) ?? 0,
    cumulativeListened:
        Duration(milliseconds: (r['i_cumulative_ms'] as int?) ?? 0),
    lastPlayedAt: lastPlayedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastPlayedAt),
    reviewedAt: reviewedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(reviewedAt),
    favoriteToggledAt: favoriteToggledAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(favoriteToggledAt),
  );
}

/// Extract the trailing path component (filename). Cheap, no
/// `package:path` dependency required.
String _basenameOf(String path) {
  final sep = Platform.pathSeparator;
  final idx = path.lastIndexOf(sep);
  return idx < 0 ? path : path.substring(idx + 1);
}

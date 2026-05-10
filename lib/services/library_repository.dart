import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/intelligence_record.dart';
import '../models/source.dart';
import '../models/track.dart';
import 'database.dart';
import 'metadata_extractor.dart';
import 'track_uid.dart';

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

  Future<List<Track>> loadTracks() async {
    final rows = await _db.rawQuery('''
      SELECT idx.*, t.favorite AS i_favorite,
             t.play_count AS i_play_count,
             t.cumulative_ms AS i_cumulative_ms,
             t.last_played_at AS i_last_played_at
      FROM indexed_files idx
      LEFT JOIN tracks t ON t.uid = idx.intel_uid
    ''');
    return rows.map(_trackFromJoinedRow).toList();
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
      // a default ~999 parameter limit per statement).
      final existing = <String, Map<String, Object?>>{};
      const chunk = 400;
      for (var i = 0; i < files.length; i += chunk) {
        final end = (i + chunk).clamp(0, files.length);
        final slice = files.sublist(i, end);
        final placeholders = List.filled(slice.length, '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT path, uid, intel_uid FROM indexed_files '
          'WHERE path IN ($placeholders)',
          [for (final f in slice) f.path],
        );
        for (final r in rows) {
          existing[r['path'] as String] = r;
        }
      }

      final batch = txn.batch();
      for (final f in files) {
        final ids = computeTrackUid(
          basename: f.filename,
          filesize: f.filesize,
          durationMs: f.durationMs,
          mtimeMs: f.modifiedAtMs,
        );
        final ex = existing[f.path];
        if (ex == null) {
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
            'last_seen_at': now,
            'title': f.fallbackTitle,
          });
          inserted++;
        } else {
          final oldUid = ex['uid'] as String;
          final oldIntelUid = ex['intel_uid'] as String?;
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
          batch.update(
            'indexed_files',
            {
              'source_id': sourceId,
              'filename': f.filename,
              'filesize': f.filesize,
              'modified_at': f.modifiedAtMs,
              'duration_ms': f.durationMs,
              'fingerprint': ids.fingerprint,
              'uid': ids.uid,
              'is_available': 1,
              'last_seen_at': now,
            },
            where: 'path = ?',
            whereArgs: [f.path],
          );
        }
      }
      await batch.commit(noResult: true);
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
    int? lastPlayedAt
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
        columns: ['uid', 'intel_uid'],
        where: 'path = ?',
        whereArgs: [file.path],
        limit: 1,
      );

      if (existing.isEmpty) {
        await txn.insert('indexed_files', {
          'path': file.path,
          'source_id': sourceId,
          'filename': file.filename,
          'filesize': file.filesize,
          'modified_at': file.modifiedAt,
          'duration_ms': durationMs,
          'fingerprint': ids.fingerprint,
          'uid': ids.uid,
          'intel_uid': null,
          'is_available': 1,
          'last_seen_at': now,
          'title': file.fallbackTitle,
        });
        return;
      }

      final oldUid = existing.first['uid'] as String;
      final oldIntelUid = existing.first['intel_uid'] as String?;

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

      await txn.update(
        'indexed_files',
        {
          'source_id': sourceId,
          'filename': file.filename,
          'filesize': file.filesize,
          'modified_at': file.modifiedAt,
          'duration_ms': durationMs,
          'fingerprint': ids.fingerprint,
          'uid': ids.uid,
          'is_available': 1,
          'last_seen_at': now,
        },
        where: 'path = ?',
        whereArgs: [file.path],
      );
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
  Future<void> markUnseenAvailability(
    String sourceId,
    Set<String> seenPaths,
  ) async {
    await _db.transaction((txn) async {
      // Pass 1: reset everything in this source to unavailable.
      await txn.update(
        'indexed_files',
        {'is_available': 0},
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      if (seenPaths.isEmpty) return;

      // Pass 2: chunked update to set is_available=1 for all seen
      // paths. Each chunk only flips its own slice — never touches
      // the other chunks.
      const chunkSize = 400;
      final list = seenPaths.toList(growable: false);
      for (var i = 0; i < list.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, list.length);
        final slice = list.sublist(i, end);
        final placeholders = List.filled(slice.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE indexed_files SET is_available = 1 '
          'WHERE source_id = ? AND path IN ($placeholders)',
          [sourceId, ...slice],
        );
      }
    });
  }

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
        for (final r in intelRows) {
          if (((r['favorite'] as int?) ?? 0) != 0) favorite = true;
          playCount += (r['play_count'] as int?) ?? 0;
          cumulativeMs += (r['cumulative_ms'] as int?) ?? 0;
          final lp = r['last_played_at'] as int?;
          if (lp != null && (lastPlayedAt == null || lp > lastPlayedAt)) {
            lastPlayedAt = lp;
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
    final localCreated = (localRow['created_at'] as int?) ?? imported.createdAt;

    await txn.update(
      'tracks',
      {
        'play_count': localPlay + imported.playCount,
        'cumulative_ms':
            localCum > imported.cumulativeMs ? localCum : imported.cumulativeMs,
        'favorite': (localFav || imported.favorite) ? 1 : 0,
        'last_played_at': _maxNullable(localLast, imported.lastPlayedAt),
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

  Future<void> updateIntelligence({
    required String intelUid,
    bool? favorite,
    int? playCount,
    int? cumulativeMs,
    int? lastPlayedAt,
  }) async {
    final values = <String, Object?>{};
    if (favorite != null) values['favorite'] = favorite ? 1 : 0;
    if (playCount != null) values['play_count'] = playCount;
    if (cumulativeMs != null) values['cumulative_ms'] = cumulativeMs;
    if (lastPlayedAt != null) values['last_played_at'] = lastPlayedAt;
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
      final values = <String, Object?>{
        'metadata_read_at': now,
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
  final iFav = r['i_favorite'] as int?;
  return Track(
    uid: r['uid'] as String,
    fingerprint: r['fingerprint'] as String,
    intelUid: r['intel_uid'] as String?,
    path: r['path'] as String,
    filename: r['filename'] as String,
    sourceId: r['source_id'] as String,
    filesize: (r['filesize'] as int?) ?? 0,
    modifiedAt: (r['modified_at'] as int?) ?? 0,
    isAvailable: ((r['is_available'] as int?) ?? 1) != 0,
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
    favorite: (iFav ?? 0) != 0,
    playCount: (r['i_play_count'] as int?) ?? 0,
    cumulativeListened:
        Duration(milliseconds: (r['i_cumulative_ms'] as int?) ?? 0),
    lastPlayedAt: lastPlayedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastPlayedAt),
  );
}

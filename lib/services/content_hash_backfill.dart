import 'dart:async';

import 'package:flutter/foundation.dart';

import 'content_hash.dart';
import 'library_repository.dart';

/// Background worker that fills in missing `content_hash` values
/// for indexed_files rows the scan-time write path hasn't reached
/// yet. Two scenarios it covers:
///
///   1. After the v9 → v10 migration, every existing row has
///      `content_hash = NULL`. Without a backfill, those rows
///      would only get populated when a scan happens to re-visit
///      them with a mtime/filesize change — for a stable library
///      that could be never.
///   2. Files that returned null from the sync hash on the scan
///      itself (transient FS hiccup) get a second chance here.
///
/// Throttled by design — chunks of [_batchSize] processed every
/// [_batchInterval], so it never competes hard for disk I/O or
/// SQLite contention with a foreground scan or user actions. The
/// worker pauses on `cancel()` and resumes on `start()`; the
/// controller calls cancel before kicking off a scan and start
/// after the scan completes.
///
/// Once a single batch produces zero progress (no candidates that
/// haven't already failed within this session), the worker exits
/// quietly. The next scan-end restart picks up any new NULL rows.
class ContentHashBackfillWorker {
  ContentHashBackfillWorker(this._repo, {this.onProgress});

  final LibraryRepository _repo;

  /// Optional progress hook fired after each batch. Receives
  /// `(rowsHashedThisBatch, totalRowsHashedThisSession)`. The
  /// controller uses it to surface status (Slice 4) without
  /// polling. Always called on the same isolate that called
  /// `start()`.
  final void Function(int batchSuccesses, int sessionSuccesses)? onProgress;

  /// Number of NULL-content_hash candidates pulled per batch.
  static const int _batchSize = 10;

  /// Pause between batches. Caps backfill throughput at ~20
  /// rows/sec sustained, which keeps disk + SQLite contention
  /// well under any reasonable foreground workload.
  static const Duration _batchInterval = Duration(milliseconds: 500);

  bool _running = false;
  bool _cancelled = false;
  Timer? _scheduler;
  int _sessionSuccesses = 0;

  /// In-memory record of paths whose hash failed during this
  /// run. Excluded from subsequent candidates so we don't spin
  /// on perma-failed rows (Dropbox placeholders, permission
  /// issues). Cleared on `cancel()` — a fresh session retries
  /// them.
  final Set<String> _failedThisSession = {};

  bool get isRunning => _running;

  /// Kick off (or resume) a backfill pass. Returns immediately;
  /// work happens via scheduled timers. Idempotent — calling
  /// while already running is a no-op.
  void start() {
    if (_running) return;
    _running = true;
    _cancelled = false;
    _scheduleNextBatch(immediate: true);
  }

  /// Stop the worker. Any in-flight batch finishes (one file at
  /// most), then no more batches are scheduled until `start()` is
  /// called again. Clears the in-session failed-path memo so the
  /// next session retries those paths fresh.
  void cancel() {
    _cancelled = true;
    _scheduler?.cancel();
    _scheduler = null;
    _running = false;
    _failedThisSession.clear();
  }

  void _scheduleNextBatch({bool immediate = false}) {
    if (_cancelled) return;
    _scheduler = Timer(
      immediate ? Duration.zero : _batchInterval,
      _processBatch,
    );
  }

  Future<void> _processBatch() async {
    if (_cancelled) return;
    // Ask for more than the batch size so we have headroom to
    // skip already-failed paths without an extra round-trip.
    final candidates = await _repo.contentHashCandidates(
      limit: _batchSize * 3,
    );
    final fresh = candidates
        .where((p) => !_failedThisSession.contains(p))
        .take(_batchSize)
        .toList();
    if (fresh.isEmpty) {
      // Two reasons we might be here:
      //  - genuinely no NULL rows left → done.
      //  - everything left in the candidate window has already
      //    failed this session → also done; controller will
      //    re-trigger us next scan-end with a fresh failed-set.
      _running = false;
      _scheduler = null;
      debugPrint(
        '[content_hash backfill] session complete: '
        '$_sessionSuccesses rows hashed, '
        '${_failedThisSession.length} skipped',
      );
      return;
    }

    var batchSuccesses = 0;
    for (final path in fresh) {
      if (_cancelled) return;
      final hash = computeContentHashSync(path);
      if (hash != null) {
        await _repo.setContentHashForPath(path, hash);
        batchSuccesses++;
        _sessionSuccesses++;
      } else {
        _failedThisSession.add(path);
      }
    }
    if (onProgress != null) {
      onProgress!(batchSuccesses, _sessionSuccesses);
    }
    _scheduleNextBatch();
  }
}

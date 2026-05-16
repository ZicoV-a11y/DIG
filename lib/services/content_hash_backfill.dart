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
  ContentHashBackfillWorker(
    this._repo, {
    this.onProgress,
    this.onHashStart,
    this.onHashEnd,
  });

  final LibraryRepository _repo;

  /// Optional progress hook fired after each batch. Receives
  /// `(rowsHashedThisBatch, totalRowsHashedThisSession,
  /// candidatesRemaining)`. `candidatesRemaining` is the live count
  /// of rows still waiting (sampled at the start of each batch);
  /// the controller uses it together with `sessionSuccesses` to
  /// render determinate progress like "Hashing audio 12 / 873"
  /// instead of an indeterminate spinner. Always called on the
  /// same isolate that called `start()`.
  final void Function(
      int batchSuccesses,
      int sessionSuccesses,
      int candidatesRemaining)? onProgress;

  /// Fires when a single-file hash starts. The controller uses this
  /// to know which path is in flight so it can swap the status-bar
  /// label to a cloud-waiting hint once elapsed exceeds the
  /// patience threshold (a Dropbox dataless placeholder commonly
  /// blocks the read for 10–30 seconds while macOS materialises
  /// the file; "Waiting on cloud · filename" reads as deliberate,
  /// "Hashing audio" sitting frozen reads as broken).
  final void Function(String path)? onHashStart;

  /// Paired with [onHashStart]. Fires after the await completes
  /// regardless of outcome (success, timeout, error). The controller
  /// uses this to clear its "currently hashing" state so the
  /// status bar drops the cloud-waiting hint promptly.
  final void Function(String path)? onHashEnd;

  /// Number of NULL-content_hash candidates pulled per batch.
  static const int _batchSize = 10;

  /// Pause between batches. Caps backfill throughput at ~20
  /// rows/sec sustained, which keeps disk + SQLite contention
  /// well under any reasonable foreground workload.
  static const Duration _batchInterval = Duration(milliseconds: 500);

  /// Per-file hash timeout. A Dropbox "online-only" placeholder
  /// or a stat hiccup that takes minutes to resolve would
  /// otherwise stall the whole backfill on one file. After the
  /// timeout the path is treated like any other read failure —
  /// added to the in-session skip list, retried next session.
  static const Duration _hashTimeout = Duration(seconds: 30);

  bool _running = false;
  bool _cancelled = false;
  bool _paused = false;
  Timer? _scheduler;
  int _sessionSuccesses = 0;

  /// In-memory record of paths whose hash failed during this
  /// run. Excluded from subsequent candidates so we don't spin
  /// on perma-failed rows (Dropbox placeholders, permission
  /// issues). Cleared on `cancel()` — a fresh session retries
  /// them.
  final Set<String> _failedThisSession = {};

  bool get isRunning => _running;

  /// `true` while the worker is suspended for higher-priority
  /// work (currently: active playback). Distinct from `!_running`
  /// (= no work to do or explicit `cancel()`). A paused worker
  /// still has scheduling state — `resume()` picks up where it
  /// left off without losing the in-session failed-path memo.
  bool get isPaused => _paused;

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
    _paused = false;
    _failedThisSession.clear();
  }

  /// Suspend the worker temporarily — the next-scheduled batch
  /// will tick, see `_paused`, and reschedule itself for later
  /// without doing any hashing work. Used to yield disk + IO
  /// thread pool to active playback.
  ///
  /// Distinct from `cancel()` in two ways:
  ///   - `_running` stays true → status bar can show
  ///     `Hashing audio · paused for playback`.
  ///   - The failed-path set survives → resume doesn't replay
  ///     the same dead Dropbox placeholders.
  void pause() {
    if (!_running) return;
    _paused = true;
  }

  /// Drop the pause flag so the next scheduled tick (or `resume`
  /// itself, when not already scheduled) does real work.
  /// Idempotent.
  void resume() {
    if (!_paused) return;
    _paused = false;
    // If the previously-scheduled tick already fired during the
    // pause and rescheduled itself with a slow interval, kick a
    // fresh immediate tick so work resumes without waiting on
    // the cool-down.
    if (_running && !_cancelled && _scheduler == null) {
      _scheduleNextBatch(immediate: true);
    }
  }

  void _scheduleNextBatch({bool immediate = false}) {
    if (_cancelled) return;
    _scheduler = Timer(
      immediate ? Duration.zero : _batchInterval,
      _processBatch,
    );
  }

  /// Cool-down between paused-batch reschedules. While playback is
  /// active the worker should be invisible — checking the pause
  /// flag every 500 ms (the normal batch interval) would waste CPU
  /// for hours during a DJ set. Two seconds is short enough that
  /// resumption feels prompt when playback stops, long enough that
  /// the idle worker uses ~zero resources.
  static const Duration _pausedRecheckInterval = Duration(seconds: 2);

  Future<void> _processBatch() async {
    if (_cancelled) return;
    if (_paused) {
      // Skip this batch — playback is active. Reschedule on the
      // slow cool-down so we recheck the flag periodically without
      // burning the event loop. `resume()` will kick an immediate
      // tick when playback stops, so this is just the fallback.
      _scheduler = Timer(_pausedRecheckInterval, _processBatch);
      return;
    }
    // Sample the live candidate count for determinate progress.
    // Cheap query (indexed COUNT) — runs once per batch (every
    // 500 ms) so the status bar's denominator stays current as
    // a scan inserts new NULL-hash rows mid-session.
    final remaining = await _repo.contentHashCandidatesCount();
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
      // One final progress tick with `remaining = 0` so the
      // status bar drops the backfill state cleanly instead of
      // freezing on the last-shown count.
      if (onProgress != null) {
        onProgress!(0, _sessionSuccesses, 0);
      }
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
      // ASYNC hash + per-file timeout. Two reasons:
      //   1. The sync variant blocks the main isolate on file
      //      I/O. With Dropbox CloudStorage paths that can stall
      //      the UI thread for seconds-to-minutes per file. The
      //      async variant uses Dart's IO thread pool; main
      //      stays responsive between awaits.
      //   2. The timeout caps the worst case at 30s/file so
      //      one truly-stuck file (Dropbox online-only
      //      placeholder pending download, dead mount) can't
      //      stall the whole backfill.
      String? hash;
      onHashStart?.call(path);
      try {
        hash = await computeContentHash(path).timeout(
          _hashTimeout,
          onTimeout: () {
            debugPrint('[content_hash backfill] timeout: $path');
            return null;
          },
        );
      } catch (e) {
        debugPrint('[content_hash backfill] error hashing $path: $e');
        hash = null;
      } finally {
        onHashEnd?.call(path);
      }
      if (_cancelled) return;
      if (hash != null) {
        await _repo.setContentHashForPath(path, hash);
        batchSuccesses++;
        _sessionSuccesses++;
      } else {
        _failedThisSession.add(path);
      }
    }
    if (onProgress != null) {
      // Subtract this batch's successes from the start-of-batch
      // snapshot so the denominator's monotonic-decreasing.
      // Floor at 0: a concurrent scan could insert new NULL-hash
      // rows mid-batch and push the live count higher — the next
      // batch's resample picks that up; here we just clamp.
      final live = (remaining - batchSuccesses).clamp(0, 1 << 30);
      onProgress!(batchSuccesses, _sessionSuccesses, live);
    }
    _scheduleNextBatch();
  }
}

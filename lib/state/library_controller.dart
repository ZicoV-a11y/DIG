import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show
    AppLifecycleState,
    WidgetsBinding,
    WidgetsBindingObserver;
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:uuid/uuid.dart';

import '../models/intelligence_record.dart';
import '../models/source.dart';
import '../models/activity_event.dart';
import '../models/track.dart';
import '../services/audio_scanner.dart';
import '../services/content_hash.dart';
import '../services/content_hash_backfill.dart';
import '../services/intelligence_export.dart';
import '../services/library_repository.dart';
import '../services/media_keys.dart';
import '../services/metadata_extractor.dart';
import '../services/playback_engine.dart';
import '../utils/aggregated_track_view.dart';
import '../utils/file_format.dart';
import '../utils/key_normalizer.dart';
import '../utils/song_identity.dart';

enum TrackSortColumn {
  favorite,
  reviewed,
  title,
  artist,
  bpm,
  key,
  duration,
  format,
  plays,
  lastPlayed,
}

enum PlaybackMode { sequential, shuffle, shuffleUnreviewed }

extension PlaybackModeView on PlaybackMode {
  String get label {
    switch (this) {
      case PlaybackMode.sequential:
        return 'SEQ';
      case PlaybackMode.shuffle:
        return 'SHUF';
      case PlaybackMode.shuffleUnreviewed:
        return 'UNREV';
    }
  }
}

class LibraryController extends ChangeNotifier {
  final PlaybackEngine engine;
  final LibraryRepository repo;
  final Uuid _uuid = const Uuid();

  static const _recentBufferCapacity = 8;
  static const _trailVisibleCount = 5;
  // Bigger batches when files are local — fewer `compute()`
  // spawn round-trips per file, more files per isolate. The
  // earlier 25 was sized for slow Dropbox cloud-only reads where
  // a single hung file would block 24 others; now that the
  // library is local, the per-file cost is small enough that
  // batching 50 cuts the scheduling overhead roughly in half.
  static const _metadataBatchSize = 50;

  final List<Source> _sources = [];
  final List<Track> _tracks = [];
  // O(1) lookups keyed by uid / path. Kept consistent with [_tracks]
  // by [_replaceTracks] / [_removeTracksWhere]. Without these,
  // `_trackByUid` / `_trackByPath` would do linear scans over ~12k
  // entries on every row click, every metadata batch, every
  // currentTrack getter — which adds up fast in the play/scan path.
  final Map<String, Track> _tracksByUid = {};
  final Map<String, Track> _tracksByPath = {};
  final List<String> _recentReviewedUids = [];
  // Viewport-driven enrichment queue. Per the reactive-first
  // architecture, scan completion and hydrate do NOT auto-populate
  // this queue — only intent-driven entry points do
  // (`reportViewportPaths`, `enrichOnDemand`). Untouched files
  // remain at filename-only display indefinitely; the
  // filename-parsing fallback covers them. The companion Set keeps
  // dedup O(1) so fast-scrolling viewport reports don't pile up
  // duplicate work.
  final List<String> _enrichmentQueue = [];
  final Set<String> _inEnrichmentQueue = {};
  bool _metadataProcessing = false;
  // Progress counters for the global status bar. Reset each time
  // the queue fully drains. `_metadataTotalThisRun` grows when more
  // paths are enqueued mid-processing.
  int _metadataDoneThisRun = 0;
  int _metadataTotalThisRun = 0;

  String? _selectedSourceId;
  String _searchQuery = '';
  bool _unreviewedOnly = false;
  bool _showArtwork = false;
  bool _isScanning = false;
  TrackSortColumn _sortColumn = TrackSortColumn.title;
  bool _sortAscending = true;
  // Index into `formatSortLeads` — which format leads the FORMAT
  // column's sort order. Cycles 0..N on each header click while
  // FORMAT is the active sort column. Other columns ignore it.
  int _sortFormatMode = 0;

  String? _currentTrackUid;
  // Path of the file the engine is actually playing. Held alongside
  // `_currentTrackUid` because a track-intelligence object can have
  // multiple physical instances behind one uid (true byte-identical
  // clones share a uid). Show-in-Finder uses this to reveal the exact
  // file being played, not just any sibling — see also the resolver
  // in `_revealInFinderWithFallback`.
  String? _currentTrackPath;
  String? _selectedTrackUid;
  PlaybackMode _playbackMode = PlaybackMode.sequential;
  final Random _rng = Random();
  bool _isPlaying = false;
  // True from the moment `play(uid)` calls `engine.setTrack(...)`
  // until that future resolves (or throws). Used by the playback
  // bar to swap the play icon for a spinner while a Dropbox-backed
  // file is materialising — without this, the user sees nothing
  // happen for several seconds on cloud-only files.
  bool _isLoadingTrack = false;
  Duration _lastTickPosition = Duration.zero;
  Duration _sessionListened = Duration.zero;
  bool _sessionPlayCounted = false;
  int _playThresholdSeconds = 10;
  double _volume = 1.0;
  final ValueNotifier<double> volumeListenable = ValueNotifier<double>(1.0);

  bool _sidebarVisible = true;
  double _sidebarWidth = 260;
  static const double sidebarMinWidth = 200;
  static const double sidebarMaxWidth = 360;

  final MediaKeysBridge _media = MediaKeysBridge();

  // Utility columns: locked widths.
  double _colFavWidth = 32;
  double _colRevWidth = 38;
  double _colBpmWidth = 38;
  double _colKeyWidth = 50;
  double _colTimeWidth = 50;
  // Wide enough to fit aggregated `MP3 · AIFF` style labels comfortably
  // when grouping is on, plus the expand-chevron prefix.
  double _colFormatWidth = 78;
  double _colPlaysWidth = 52;
  double _colLastPlayedWidth = 90;
  // Text columns: persisted absolute widths.
  double _colTitleWidth = 350;
  double _colArtistWidth = 240;

  static const List<String> _defaultColumnOrder = [
    'fav',
    'rev',
    'title',
    'artist',
    'bpm',
    'key',
    'time',
    'format',
    'plays',
    'lastPlayed',
  ];
  List<String> _columnOrder = List.of(_defaultColumnOrder);
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<int> _revealTick = ValueNotifier(0);

  int _libraryVersion = 0;
  List<Track>? _visibleCache;
  int _visibleCacheVersion = -1;
  int? _lockedCurrentIndex;

  // The visible-tracks pipeline always collapses each song-identity
  // bucket into a single primary row (lowest-quality format wins —
  // MP3 > FLAC > WAV > AIFF). Siblings never appear as their own
  // table rows; the user reaches them via the right-click "Show in
  // Finder" submenu (one item per variant) and via aggregated cell
  // values on the primary row.
  //
  // Side-table built each pipeline run: lookup from primary's uid
  // → the bucket's AggregatedTrackView so the table can render
  // aggregated cells (sum plays, blank-on-disagreement BPM/key,
  // FORMAT label) and the context-menu can enumerate variants
  // without re-grouping on every row build.
  Map<String, AggregatedTrackView> _bucketsByPrimaryUid =
      const <String, AggregatedTrackView>{};

  // Cached per-source counts. Sidebar build calls
  // `sourceTrackCount(sourceId)` once per tile; without this cache
  // each call walked all ~12k tracks (and for sub-views, also
  // string-prefixed every path). Now we recompute the whole map
  // once per `_libraryVersion` change and answer subsequent calls
  // in O(1).
  Map<String, int>? _sourceCountCache;
  int _sourceCountCacheVersion = -1;

  // Cached library-wide tallies for the always-on status bar:
  // enriched (any metadata extracted), missing (rows surviving the
  // last scan as `is_available=0`), song count (distinct song-
  // identities — same canonical bucket the variant collapse uses),
  // and reviewed song count (a song is reviewed if ANY variant
  // crossed the cumulative-listen threshold). Recomputed on
  // `_libraryVersion` change.
  int? _enrichedCountCache;
  int? _missingCountCache;
  int? _movedCountCache;
  // Paths of rows whose `availability_state == 'missing'` AND whose
  // content_hash is also present on at least one `available` row
  // anywhere in the library — i.e. the bytes survived elsewhere, the
  // missing row is just the trailing record at the old path. These
  // are NOT counted toward `missingCount` (would falsely alarm the
  // user that data was lost) and are folded into `movedCount` /
  // surfaced under the MOVED section of the Review dialog.
  //
  // Strict content_hash match — fingerprint coincidences don't
  // count. Computed in the same pass as the other stats in
  // `_ensureLibraryStats`.
  Set<String>? _coexistingMissingPathsCache;
  int? _songCountCache;
  int? _reviewedSongCountCache;
  int _libraryStatsVersion = -1;

  // Set while a metadata wave is in flight: a representative
  // filename from the current batch. Surfaced in the status bar so
  // the user can see exactly what file is being processed instead
  // of just an opaque counter.
  String? _currentEnrichmentLabel;

  // Files whose tag-parser failed (audio_metadata_reader threw, or
  // returned no parseable header). We remember them at session
  // scope so a fast viewport scroll over the same region doesn't
  // re-enqueue them on every scroll-end, which would otherwise
  // pile the queue forever and exaggerate "Enriching" totals.
  final Set<String> _failedEnrichmentPaths = {};

  // Per-source filesystem watchers. Each watcher fires on any
  // create / modify / delete inside the source folder (recursive
  // when the source's scan mode is recursive). Events are coalesced
  // through `_watcherDebounce` — a burst of events from a file save
  // or a folder move only triggers one rescan.
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final Map<String, Timer> _watcherDebounce = {};
  static const _watcherDebounceWindow = Duration(milliseconds: 500);

  // App-lifecycle observer. macOS sends `resumed` when the user
  // brings the app to foreground (e.g., Cmd+Tab back from Finder).
  // Belt-and-suspenders rescan covers the case where the per-source
  // filesystem watcher missed an event — Finder's "Move to Trash"
  // sometimes produces atypical FSEvents that `Directory.watch`
  // doesn't always surface reliably.
  late final _LifecycleObserver _lifecycleObserver = _LifecycleObserver(
    (state) {
      if (state == AppLifecycleState.resumed) _rescanAllOnFocus();
    },
  );
  bool _lifecycleObserverRegistered = false;
  bool _focusRescanInFlight = false;

  // Throttle notifyListeners() during phase-2 metadata enrichment.
  // Without this, each 100-file batch triggered a full UI rebuild +
  // visible-cache invalidation + 12k-element re-sort. With ~25
  // batches per large folder, that's ~25 sorts of the entire
  // library back-to-back. We coalesce to at most one notification
  // every 500ms so the UI stays responsive while the queue drains.
  Timer? _throttledNotifyTimer;
  DateTime _lastThrottledNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<ProcessingState>? _processingSub;

  Timer? _flushTimer;

  LibraryController({required this.engine, required this.repo}) {
    _backfillWorker = ContentHashBackfillWorker(
      repo,
      onProgress: _onBackfillProgress,
    );
    _positionSub = engine.positionStream.listen(_onPosition);
    _playingSub = engine.playingStream.listen(_onPlaying);
    _durationSub = engine.durationStream.listen(_onDuration);
    _processingSub = engine.processingStateStream.listen(_onProcessing);
    _wireMediaBridge();
  }

  /// content_hash backfill — see `services/content_hash_backfill.dart`.
  /// Owned here so the controller can pause it cleanly around
  /// foreground scans and surface its progress.
  late final ContentHashBackfillWorker _backfillWorker;

  /// Cumulative rows hashed in the most-recent (or in-flight)
  /// backfill session. Read by the status bar to show progress.
  int get backfillHashedThisSession => _backfillHashedThisSession;
  int _backfillHashedThisSession = 0;
  bool get isBackfillingContentHashes => _backfillWorker.isRunning;

  void _onBackfillProgress(int batch, int session) {
    _backfillHashedThisSession = session;
    notifyListeners();
  }

  void _wireMediaBridge() {
    _media.onPlay = () async {
      if (!_isPlaying) await togglePlayPause();
    };
    _media.onPause = () async {
      if (_isPlaying) await togglePlayPause();
    };
    _media.onTogglePlayPause = () => togglePlayPause();
    _media.onNext = () => next();
    _media.onPrevious = () => previous();
    _media.onSeek = (seconds) async {
      final track = currentTrack;
      if (track == null) return;
      final pos = Duration(milliseconds: (seconds * 1000).round());
      _positionNotifier.value = pos;
      _lastTickPosition = pos;
      await engine.seek(pos);
    };
  }

  void _pushNowPlaying() {
    final track = currentTrack;
    if (track == null) {
      _media.clearNowPlaying();
      return;
    }
    final shownTitle = track.displayTitle;
    final shownArtist = track.displayArtist;
    _media.updateNowPlaying(
      title: shownTitle.isEmpty ? null : shownTitle,
      artist: shownArtist.isEmpty ? null : shownArtist,
      durationSeconds: track.duration.inMilliseconds / 1000.0,
      positionSeconds: _positionNotifier.value.inMilliseconds / 1000.0,
      isPlaying: _isPlaying,
    );
  }

  DateTime _lastNowPlayingPushAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> hydrate() async {
    final settings = await repo.loadSettings();
    _playThresholdSeconds =
        int.tryParse(settings['play_threshold_seconds'] ?? '') ?? 10;
    final savedVolume = double.tryParse(settings['volume'] ?? '');
    if (savedVolume != null) {
      _volume = savedVolume.clamp(0.0, 1.0).toDouble();
      volumeListenable.value = _volume;
      await engine.setVolume(_volume);
    }
    final savedSidebar = settings['sidebar_visible'];
    if (savedSidebar != null) {
      _sidebarVisible = savedSidebar != '0';
    }
    final savedSidebarWidth = double.tryParse(settings['sidebar_width'] ?? '');
    if (savedSidebarWidth != null) {
      _sidebarWidth = savedSidebarWidth.clamp(
        sidebarMinWidth,
        sidebarMaxWidth,
      ).toDouble();
    }
    _colTitleWidth =
        double.tryParse(settings['col_title_width'] ?? '') ?? _colTitleWidth;
    _colArtistWidth =
        double.tryParse(settings['col_artist_width'] ?? '') ?? _colArtistWidth;
    _colFormatWidth =
        double.tryParse(settings['col_format_width'] ?? '') ?? _colFormatWidth;
    final orderStr = settings['column_order'];
    if (orderStr != null && orderStr.isNotEmpty) {
      final parsed = orderStr
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final defaults = _defaultColumnOrder.toSet();
      final stored = parsed.toSet();
      if (stored.containsAll(defaults) && parsed.length == stored.length) {
        // Stored order is exhaustive (covers every default + has no
        // duplicates) — adopt as-is. Allows users to keep custom
        // orderings across releases that add columns.
        _columnOrder = parsed;
      } else if (defaults.containsAll(stored)) {
        // Stored order is a subset of current defaults (e.g. it was
        // saved before we added `key` / `lastPlayed`). Keep the
        // user's relative order for known columns and append any
        // newly-introduced columns at the end so they're at least
        // visible.
        final tail = _defaultColumnOrder
            .where((c) => !parsed.contains(c))
            .toList();
        _columnOrder = [...parsed, ...tail];
      }
    }
    final srcOrderStr = settings['source_order'];
    if (srcOrderStr != null && srcOrderStr.isNotEmpty) {
      _sourceOrder = srcOrderStr
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    final sources = await repo.loadSources();
    final tracks = await repo.loadTracks();
    _sources
      ..clear()
      ..addAll(sources);
    _replaceTracks(tracks);
    _markLibraryDirty();
    notifyListeners();

    // Start a filesystem watcher per non-sub-view source so external
    // changes (deletes, renames, new drops) flow into the table
    // without a manual rescan. Best-effort: failures (unsupported
    // FS, missing path) are logged and the manual rescan path still
    // works.
    for (final source in sources) {
      // Don't await — watchers should come up in parallel; we
      // don't want to gate hydrate completion on per-source
      // watcher setup, especially over slow cloud volumes.
      unawaited(_startWatcher(source));
    }

    // Belt-and-suspenders: also rescan every source when the app
    // is brought back to foreground (Cmd+Tab from Finder, etc).
    // Catches the cases where `Directory.watch` missed an event —
    // especially Finder's "Move to Trash" flow, which sometimes
    // produces FSEvents that don't surface cleanly.
    if (!_lifecycleObserverRegistered) {
      WidgetsBinding.instance.addObserver(_lifecycleObserver);
      _lifecycleObserverRegistered = true;
    }

    final unenriched =
        tracks.where((t) => t.metadataReadAt == null).length;
    debugPrint(
      '[meta] hydrate loaded ${tracks.length} tracks '
      '($unenriched without metadata — viewport will enrich on demand)',
    );
    // NO auto-enqueue. Untouched rows stay at filename-only until
    // the user scrolls/selects/plays them.
  }

  /// The track table calls this with the paths currently on screen
  /// (plus a small lookahead) once scrolling settles. We push any
  /// path that lacks metadata and isn't already queued onto the
  /// enrichment queue. No-op if everything visible is already
  /// enriched or already in flight.
  void reportViewportPaths(Iterable<String> paths) {
    _enqueueIfNeeded(paths);
  }

  /// Single-path enrichment hook used by interaction code paths
  /// (`play`, `selectTrack`). Independent of the viewport — ensures
  /// the row the user is currently engaging with gets metadata.
  void enrichOnDemand(String path) {
    _enqueueIfNeeded([path]);
  }

  /// User-triggered: enrich every un-enriched track owned by
  /// [sourceId] (or contained by a sub-view's `pathPrefix`).
  /// Bypasses the viewport gate intentionally — this is the
  /// explicit opt-in to a long-running pass.
  void enrichSource(String sourceId) {
    final s = _sourceById(sourceId);
    if (s == null) return;
    final paths = <String>[];
    if (s.isSubView) {
      for (final t in _tracks) {
        if (t.sourceId == s.parentSourceId &&
            t.path.startsWith(s.pathPrefix!) &&
            t.metadataReadAt == null) {
          paths.add(t.path);
        }
      }
    } else {
      for (final t in _tracks) {
        if (t.sourceId == sourceId && t.metadataReadAt == null) {
          paths.add(t.path);
        }
      }
    }
    debugPrint('[meta] enrichSource(${s.displayName}) → ${paths.length} paths');
    _enqueueIfNeeded(paths);
  }

  /// User-triggered: enrich every un-enriched track in the
  /// library, regardless of source. The "show me flying numbers"
  /// command.
  void enrichAll() {
    final paths = [
      for (final t in _tracks)
        if (t.metadataReadAt == null) t.path,
    ];
    debugPrint('[meta] enrichAll → ${paths.length} paths');
    _enqueueIfNeeded(paths);
  }

  void _enqueueIfNeeded(Iterable<String> paths) {
    final fresh = <String>[];
    for (final p in paths) {
      if (_inEnrichmentQueue.contains(p)) continue;
      if (_failedEnrichmentPaths.contains(p)) continue;
      final t = _tracksByPath[p];
      if (t == null) continue;
      if (t.metadataReadAt != null) continue;
      _inEnrichmentQueue.add(p);
      fresh.add(p);
    }
    if (fresh.isEmpty) return;
    _enrichmentQueue.addAll(fresh);
    _metadataTotalThisRun += fresh.length;
    debugPrint(
      '[meta] queued +${fresh.length} '
      '(queue=${_enrichmentQueue.length}, processing=$_metadataProcessing)',
    );
    if (!_metadataProcessing) {
      _processMetadataQueue();
    } else {
      _notifyThrottled();
    }
  }

  Future<void> _processMetadataQueue() async {
    if (_metadataProcessing) return;
    _metadataProcessing = true;
    notifyListeners();
    debugPrint('[meta] processor starting (queue=${_enrichmentQueue.length})');
    try {
      // Process small files first. On Dropbox cloud-only libraries
      // a 50MB AIFF can take 7s to materialise but a 6MB MP3
      // returns in well under 1s — sorting size-asc means the user
      // sees thousands of fast files populate immediately while
      // the slow stragglers come in the background.
      _enrichmentQueue.sort((a, b) {
        final sa = _tracksByPath[a]?.filesize ?? 0;
        final sb = _tracksByPath[b]?.filesize ?? 0;
        return sa.compareTo(sb);
      });

      // Run several batches in parallel. Each `compute()` call
      // spawns its own isolate — the OS pipelines the per-file
      // syscalls across them. Concurrency was 4 (tuned for
      // throttled Dropbox FileProvider downloads); on local
      // files it can go higher because the bottleneck shifts
      // from network → disk + isolate scheduling. 8 fully
      // saturates a modern Mac's perf cores without exhausting
      // memory (8 isolates × ~50 files of buffered tag-header
      // bytes is still tiny). Throughput typically scales near
      // linear up to core count.
      const concurrency = 8;

      while (_enrichmentQueue.isNotEmpty) {
        final waveBatches = <List<String>>[];
        for (var i = 0;
            i < concurrency && _enrichmentQueue.isNotEmpty;
            i++) {
          final batch = _enrichmentQueue
              .take(_metadataBatchSize)
              .toList(growable: false);
          _enrichmentQueue.removeRange(0, batch.length);
          // These paths are leaving the queue. Drop them from the
          // dedup set so a future viewport report can re-enqueue
          // them if metadata extraction failed and didn't stamp
          // `metadata_read_at`.
          for (final p in batch) {
            _inEnrichmentQueue.remove(p);
          }
          waveBatches.add(batch);
        }
        final waveSw = Stopwatch()..start();
        final waveTotal =
            waveBatches.fold<int>(0, (s, b) => s + b.length);
        debugPrint(
          '[meta] wave start (${waveBatches.length} batches × '
          '$_metadataBatchSize, total=$waveTotal, '
          'queue remaining=${_enrichmentQueue.length})',
        );

        // Run all batches in parallel — but apply each batch's
        // results AS IT COMPLETES instead of waiting for the whole
        // wave. This is what makes the counter "fly": with 8
        // batches in flight and `Future.wait`, the user sees ZERO
        // progress for the entire wave duration and then a single
        // 400-track jump. With per-batch handling, each batch's
        // ~50 rows surface immediately on its completion, and the
        // `currentEnrichmentLabel` rotates through actual files
        // being processed.
        final sep = Platform.pathSeparator;
        await Future.wait(
          waveBatches.map((batch) async {
            final List<TrackMetadata> results;
            try {
              results = await MetadataExtractor.extractBatch(batch);
            } catch (e) {
              debugPrint('[meta] batch FAILED: $e');
              return;
            }
            // Surface a representative filename from this batch
            // for the status bar — rotates as batches finish.
            if (results.isNotEmpty) {
              final p = results.first.path;
              final i = p.lastIndexOf(sep);
              _currentEnrichmentLabel = i < 0 ? p : p.substring(i + 1);
            }
            for (final m in results) {
              final t = _trackByPath(m.path);
              if (t == null) continue;
              _applyMetadata(t, m);
            }
            try {
              await repo.updateMetadataBatch(results);
            } catch (e) {
              debugPrint('[meta] DB update FAILED: $e');
            }
            _metadataDoneThisRun += results.length;
            _markLibraryDirty();
            // Notify per batch so the counter and label update
            // every ~50 rows instead of every ~400.
            notifyListeners();
          }),
        );
        debugPrint(
          '[meta] wave done in ${waveSw.elapsedMilliseconds}ms '
          '($waveTotal in flight)',
        );
      }
    } finally {
      _metadataProcessing = false;
      _metadataDoneThisRun = 0;
      _metadataTotalThisRun = 0;
      _currentEnrichmentLabel = null;
      _inEnrichmentQueue.clear();
      notifyListeners();
      debugPrint('[meta] processor idle');
    }
  }

  void _applyMetadata(Track t, TrackMetadata m) {
    if (m.readSucceeded) {
      if (m.title != null) t.title = m.title!;
      if (m.artist != null) t.artist = m.artist!;
      if (m.album != null) t.album = m.album!;
      if (m.genre != null) t.genre = m.genre!;
      if (m.musicalKey != null) t.musicalKey = m.musicalKey!;
      if (m.bpm != null) t.bpm = m.bpm;
      if (m.duration != null && m.duration! > Duration.zero) {
        t.duration = m.duration!;
      }
      t.hasArtwork = m.hasArtwork;
    } else {
      // Tag parser failed (audio_metadata_reader can't decode this
      // particular format / file revision). Track the path so we
      // don't keep re-enqueueing it from every viewport snapshot.
      _failedEnrichmentPaths.add(t.path);
    }
    // Stamp regardless of success: "we have processed this row".
    // The filename-parsing display fallback still covers it; the
    // user just doesn't see flying-zero stuck-counter behaviour
    // when their library has lots of unparseable formats. Failed
    // rows can be re-attempted by removing+re-adding the source
    // (or via a future "Retry failed" action).
    t.metadataReadAt = DateTime.now();
  }

  // ---------------------------------------------------------------------------
  // Public read-only state
  // ---------------------------------------------------------------------------

  /// Persisted display order of top-level source IDs (sub-views are
  /// always rendered immediately under their parent and don't have
  /// their own slot in this list). Loaded from `app_settings` at
  /// hydrate, mutated by [moveSource], persisted as a comma-joined
  /// string under the `source_order` key.
  List<String> _sourceOrder = [];

  /// Compare-key helper: position in `_sourceOrder` if present;
  /// otherwise sources after all explicitly-ordered ones, ranked by
  /// their natural DB `createdAt`. Used by both `sources` getter
  /// and reorder logic so the two stay consistent.
  int _orderKey(Source s) {
    final idx = _sourceOrder.indexOf(s.id);
    if (idx >= 0) return idx;
    return _sourceOrder.length + s.createdAt;
  }

  List<Source> get sources {
    if (_sources.isEmpty) return const [];
    // Order top-level by `_sourceOrder`. Then for each top-level,
    // append its sub-views — also ordered by `_sourceOrder` so the
    // user can rearrange `B`, `C`, `D` independently.
    final topLevel = _sources.where((s) => !s.isSubView).toList()
      ..sort((a, b) => _orderKey(a).compareTo(_orderKey(b)));
    final ordered = <Source>[];
    for (final s in topLevel) {
      ordered.add(s);
      final subs = _sources
          .where((c) => c.parentSourceId == s.id)
          .toList()
        ..sort((a, b) => _orderKey(a).compareTo(_orderKey(b)));
      ordered.addAll(subs);
    }
    // Defensive: any sub-view whose parent vanished (shouldn't
    // happen with FK cascade, but cheap to handle).
    final byId = {for (final s in _sources) s.id};
    for (final s in _sources) {
      if (s.isSubView && !byId.contains(s.parentSourceId)) {
        ordered.add(s);
      }
    }
    return List.unmodifiable(ordered);
  }

  Source? _sourceLookup(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Insert [draggedId] immediately before [targetId] in the saved
  /// source order. Same-tier only — refuses if dragged and target
  /// have different parents (top-level + sub-view, or sub-views of
  /// different parents). The `_sourceOrder` list is one flat
  /// sequence shared by both tiers; the `sources` getter splits it
  /// per-tier when rendering, so this handles both cases.
  Future<void> moveSourceBefore(
    String draggedId,
    String targetId,
  ) async {
    if (draggedId == targetId) return;
    final dragged = _sourceLookup(draggedId);
    final target = _sourceLookup(targetId);
    if (dragged == null || target == null) return;
    if (dragged.parentSourceId != target.parentSourceId) return;

    // Materialise a flat order list with every source ID present
    // (anything missing from `_sourceOrder` gets appended in
    // createdAt order so we don't lose track of new sources).
    final ordered = [..._sourceOrder];
    final present = ordered.toSet();
    final byCreated = _sources.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final s in byCreated) {
      if (!present.contains(s.id)) ordered.add(s.id);
    }

    ordered.remove(draggedId);
    final targetIdx = ordered.indexOf(targetId);
    if (targetIdx < 0) return;
    ordered.insert(targetIdx, draggedId);

    _sourceOrder = ordered;
    notifyListeners();
    await repo.setSetting('source_order', _sourceOrder.join(','));
  }
  String? get selectedSourceId => _selectedSourceId;
  String get searchQuery => _searchQuery;
  bool get unreviewedOnly => _unreviewedOnly;
  bool get showArtwork => _showArtwork;
  bool get isScanning => _isScanning;
  TrackSortColumn get sortColumn => _sortColumn;
  bool get sortAscending => _sortAscending;

  String? get currentTrackUid => _currentTrackUid;
  String? get currentTrackPath => _currentTrackPath;
  String? get selectedTrackUid => _selectedTrackUid;
  PlaybackMode get playbackMode => _playbackMode;
  bool get isPlaying => _isPlaying;
  bool get isLoadingTrack => _isLoadingTrack;
  bool get isMetadataProcessing => _metadataProcessing;
  int get metadataProgressDone => _metadataDoneThisRun;
  int get metadataProgressTotal => _metadataTotalThisRun;
  String? get currentEnrichmentLabel => _currentEnrichmentLabel;
  Duration get currentPosition => _positionNotifier.value;

  /// Library-wide enriched tally (`metadataReadAt != null`).
  /// Cached at `_libraryVersion` granularity.
  int get enrichedCount {
    _ensureLibraryStats();
    return _enrichedCountCache ?? 0;
  }

  /// Library-wide missing tally — truly-gone files only. Auto-
  /// detected moves are excluded (they live in `movedCount`).
  int get missingCount {
    _ensureLibraryStats();
    return _missingCountCache ?? 0;
  }

  /// Library-wide count of `superseded` rows — files the scan
  /// detected as moved within their source (old DB path no longer
  /// on disk, but a same-fingerprint file exists at a new path).
  /// Surfaced separately from `missing` so the user can see "I
  /// reorganised these" vs "these are actually gone".
  int get movedCount {
    _ensureLibraryStats();
    return _movedCountCache ?? 0;
  }

  /// Snapshot of every track currently in the `missing` or
  /// `superseded` state, regardless of source. The Review-missing
  /// dialog reads this directly to populate its two sections.
  /// Linear scan, called only when the dialog opens.
  List<Track> get tracksNeedingReview {
    return [
      for (final t in _tracks)
        if (t.availability == 'missing' || t.availability == 'superseded') t,
    ];
  }

  /// Permanently delete `indexed_files` rows by path. Used by the
  /// Review-missing dialog when the user confirms purge. Intel
  /// rows in `tracks` survive (guardrail #5: never destroy user
  /// work — the intel reconnects on fingerprint match if the file
  /// ever returns).
  Future<void> purgeMissingTracks(List<String> paths) async {
    if (paths.isEmpty) return;
    await repo.purgeIndexedFiles(paths);
    // Reload — bulk delete is easier to express than incremental
    // in-memory pruning, and this only fires from the dialog
    // (rare user action), not during normal browsing.
    final allTracks = await repo.loadTracks();
    _replaceTracks(allTracks);
    _markLibraryDirty();
    notifyListeners();
  }

  // ── App-initiated Move / Copy orchestration ─────────────────
  //
  // Thin wrappers around `repo.moveTrackFile` / `repo.copyTrackFile`
  // that take care of post-success housekeeping (reload tracks,
  // mark library dirty, notify) while leaving the FS + DB heavy
  // lifting to the repo. Right-click "Move to..." / "Copy to..."
  // wires up to these from sub-slice C; tests cover the repo
  // primitives directly so we don't need a controller-level
  // mock-engine harness here.
  //
  // Both return the raw [MoveCopyResult] so the UI can render the
  // failure reason verbatim in a SnackBar — they don't try to
  // pretty-print or swallow errors at this layer.

  /// Move the file backing [track] into [destSource]'s folder root.
  /// On success: track list reloads from DB so the row appears at
  /// the new path and the old row's gone. On failure: nothing
  /// changes in DB / FS / memory; UI shows the reason.
  Future<MoveCopyResult> moveTrack({
    required Track track,
    required Source destSource,
  }) async {
    final result = await repo.moveTrackFile(
      sourcePath: track.path,
      destSource: destSource,
    );
    if (result.success) {
      final allTracks = await repo.loadTracks();
      _replaceTracks(allTracks);
      _markLibraryDirty();
      notifyListeners();
    }
    return result;
  }

  /// Copy the file backing [track] into [destSource]'s folder root.
  /// On success: new row appears in the track list sharing
  /// intel_uid with the original (favorites / plays / review state
  /// reflect for both). On failure: nothing changes.
  Future<MoveCopyResult> copyTrack({
    required Track track,
    required Source destSource,
  }) async {
    final result = await repo.copyTrackFile(
      sourcePath: track.path,
      destSource: destSource,
    );
    if (result.success) {
      final allTracks = await repo.loadTracks();
      _replaceTracks(allTracks);
      _markLibraryDirty();
      notifyListeners();
    }
    return result;
  }

  /// Watched sources that can be a Move/Copy destination — every
  /// non-sub-view source except the one the [track] currently
  /// lives in. Used to populate the right-click menu's source
  /// picker (sub-slice C).
  List<Source> moveCopyDestinationsFor(Track track) {
    return _sources
        .where((s) => !s.isSubView && s.id != track.sourceId)
        .toList(growable: false);
  }

  /// Distinct song-identity count — same buckets the variant
  /// collapse uses. Tracks with empty title/artist (no identity to
  /// group on) each count as their own song.
  int get songCount {
    _ensureLibraryStats();
    return _songCountCache ?? 0;
  }

  /// Count of songs (not files) where any variant in the bucket has
  /// crossed the cumulative-listen threshold. Mirrors how the
  /// table's REV column resolves a primary row.
  int get reviewedSongCount {
    _ensureLibraryStats();
    return _reviewedSongCountCache ?? 0;
  }

  /// `songCount - reviewedSongCount`, exposed for status-bar
  /// readability.
  int get unreviewedSongCount => songCount - reviewedSongCount;

  /// Files − songs: how many duplicate / variant rows the library
  /// holds beyond one-canonical-per-song. Always non-negative.
  int get variantFileCount {
    final v = totalTrackCount - songCount;
    return v < 0 ? 0 : v;
  }

  void _ensureLibraryStats() {
    // Keyed on `_dataVersion` (not `_libraryVersion`) — library-wide
    // totals don't care about the current filter, so source / search
    // / sort changes shouldn't force a 12k-track recompute.
    if (_libraryStatsVersion == _dataVersion) return;
    var enriched = 0;
    var supersededCount = 0;
    // Build the byte-equivalence side index in pass 1: every
    // content_hash that has at least one currently-`available`
    // row. Used in pass 2 to reclassify "missing but content
    // exists elsewhere" rows out of the alarming MISSING tally
    // and into the calmer MOVED bucket.
    final availableContentHashes = <String>{};
    // Song-identity bucketing in the same pass. Tracks with empty
    // title/artist (songIdentityKey returns null) can't bucket and
    // each count as a singleton song. Other tracks are deduped by
    // their identity key.
    var singletonSongs = 0;
    var singletonReviewed = 0;
    final reviewedByBucket = <String, bool>{};
    final missingTracks = <Track>[];
    for (final t in _tracks) {
      if (t.metadataReadAt != null) enriched++;
      if (t.availability == 'missing') {
        missingTracks.add(t);
      } else if (t.availability == 'superseded') {
        supersededCount++;
      }
      if (t.availability == 'available' && (t.contentHash?.isNotEmpty ?? false)) {
        availableContentHashes.add(t.contentHash!);
      }
      final key = songIdentityKey(t);
      if (key == null) {
        singletonSongs++;
        if (t.reviewed) singletonReviewed++;
        continue;
      }
      final prior = reviewedByBucket[key];
      if (prior == null) {
        reviewedByBucket[key] = t.reviewed;
      } else if (!prior && t.reviewed) {
        reviewedByBucket[key] = true;
      }
    }
    // Pass 2 over the missing-only subset: bucket into
    // truly-missing vs coexisting-elsewhere by content_hash match.
    // A missing row with a known content_hash that appears on at
    // least one available row is "coexisting" — UI counts it as
    // moved rather than missing.
    final coexistingPaths = <String>{};
    var trulyMissing = 0;
    for (final t in missingTracks) {
      final ch = t.contentHash;
      if (ch != null && ch.isNotEmpty &&
          availableContentHashes.contains(ch)) {
        coexistingPaths.add(t.path);
      } else {
        trulyMissing++;
      }
    }
    var reviewedBucketed = 0;
    for (final v in reviewedByBucket.values) {
      if (v) reviewedBucketed++;
    }
    _enrichedCountCache = enriched;
    _missingCountCache = trulyMissing;
    _movedCountCache = supersededCount + coexistingPaths.length;
    _coexistingMissingPathsCache = coexistingPaths;
    _songCountCache = singletonSongs + reviewedByBucket.length;
    _reviewedSongCountCache = singletonReviewed + reviewedBucketed;
    _libraryStatsVersion = _dataVersion;
  }

  /// Paths of rows whose `availability_state == 'missing'` but
  /// whose `content_hash` is present on at least one available
  /// row anywhere in the library. UI surfaces (Review dialog,
  /// status bar tally) treat these as "found elsewhere" — folded
  /// into the MOVED count, NOT the MISSING count, since the bytes
  /// haven't been lost. The DB state stays `'missing'` because
  /// uniqueness fails (≥ 2 byte-twins available); only the user
  /// can pick a single successor manually.
  // ── Activity log proxies (Sub-slice C) ─────────────────────────
  //
  // Thin pass-throughs to LibraryRepository so the History panel
  // widget doesn't need a direct repo handle. Not cached — the
  // panel does a single load on open / refresh, not on every
  // controller notify; query cost is small (LIMIT 250) and the
  // events index covers it.

  /// Paginated activity feed for the History panel. Newest first.
  Future<List<ActivityEvent>> loadActivityFeed({
    int limit = 250,
    int offset = 0,
    List<String>? eventTypes,
  }) {
    return repo.loadRecentEvents(
      limit: limit,
      offset: offset,
      eventTypes: eventTypes,
    );
  }

  /// Lifetime event count — for "X of Y" tally text in the panel
  /// header.
  Future<int> activityEventCount() => repo.eventCount();

  Set<String> get coexistingMissingPaths {
    _ensureLibraryStats();
    return _coexistingMissingPathsCache ?? const <String>{};
  }
  ValueListenable<Duration> get positionListenable => _positionNotifier;
  ValueListenable<int> get revealTick => _revealTick;

  int get totalTrackCount => _tracks.length;

  /// Whole-library view in insertion order. Read-only — callers
  /// must not mutate. Use this for cross-library pickers (e.g., the
  /// manual link-target dialog) that need to see tracks regardless
  /// of source / search filters.
  List<Track> get allTracks => List.unmodifiable(_tracks);
  int get libraryVersion => _libraryVersion;

  int get playThresholdSeconds => _playThresholdSeconds;
  double get colFavWidth => _colFavWidth;
  double get colRevWidth => _colRevWidth;
  double get colBpmWidth => _colBpmWidth;
  double get colKeyWidth => _colKeyWidth;
  double get colTimeWidth => _colTimeWidth;
  double get colFormatWidth => _colFormatWidth;
  double get colPlaysWidth => _colPlaysWidth;

  /// Aggregated cell values for a collapsed bucket whose primary
  /// row is [primary]. Returns `null` when [primary] is not a bucket
  /// primary or before the visible-tracks pipeline has been run.
  AggregatedTrackView? aggregatedViewForPrimary(Track primary) =>
      _bucketsByPrimaryUid[primary.uid];

  /// Cheap cached count of multi-variant buckets in the library —
  /// drives the `AUDIT N` badge in the utility rail. Without this,
  /// every notifyListeners rebuilt the rail and recomputed
  /// `groupBySongIdentity` on the full track list (12k+ items), which
  /// saturated the UI thread during normal browsing. Caching at
  /// `_libraryVersion` granularity means the count is computed once
  /// per data/filter change and read back in O(1) for subsequent
  /// rebuilds.
  int get multiVariantBucketCount {
    if (_multiVariantBucketCountVersion != _dataVersion) {
      var count = 0;
      for (final bucket in groupBySongIdentity(_tracks)) {
        var available = 0;
        for (final t in bucket) {
          if (!t.isAvailable) continue;
          available++;
          if (available >= 2) {
            count++;
            break; // early exit — we only care whether it's >=2
          }
        }
      }
      _multiVariantBucketCountCache = count;
      _multiVariantBucketCountVersion = _dataVersion;
    }
    return _multiVariantBucketCountCache;
  }

  int _multiVariantBucketCountCache = 0;
  int _multiVariantBucketCountVersion = -1;

  /// Every multi-variant bucket the matcher has assembled across the
  /// whole library (manual link, auto 4-field, fingerprint
  /// equivalence — any rule that paired two files), independent of
  /// the current source / search filters. Sorted by total filesize
  /// descending so the biggest-impact duplicates surface first.
  ///
  /// Used by the duplicates audit dialog; recomputed each call so a
  /// rescan or a fresh link / unlink immediately reflects in the
  /// dialog without needing a `visibleTracks` round-trip. The audit
  /// dialog is opened explicitly, so the recompute cost (one
  /// `groupBySongIdentity` pass + sort) only fires on user action —
  /// not per UI rebuild. The badge in the rail uses
  /// `multiVariantBucketCount` instead.
  List<AggregatedTrackView> get multiVariantBuckets {
    final out = <AggregatedTrackView>[];
    for (final bucket in groupBySongIdentity(_tracks)) {
      // Only count available variants. A bucket with one available
      // + one unavailable variant has no actual duplicate problem
      // to audit (the unavailable one is already going away).
      final ordered = orderBucketByPlaybackPreference(
        bucket.where((t) => t.isAvailable).toList(growable: false),
      );
      if (ordered.length < 2) continue;
      out.add(AggregatedTrackView(ordered));
    }
    out.sort((a, b) {
      final sa = _bucketFilesize(a);
      final sb = _bucketFilesize(b);
      return sb.compareTo(sa); // desc
    });
    return out;
  }

  /// Sum of the on-disk filesizes for every variant in [view].
  /// Helper for the audit dialog header + per-row total. Filesize is
  /// per-file (lives on `indexed_files`) so it's always at the
  /// variant level, not aggregated by slice 3.
  int _bucketFilesize(AggregatedTrackView view) {
    var total = 0;
    for (final t in view.variants) {
      total += t.filesize;
    }
    return total;
  }

  /// `true` when [primary] is the displayed primary of a multi-
  /// variant bucket — used by the right-click handler to decide
  /// whether to surface a per-format "Show in Finder" submenu.
  bool primaryHasSiblings(Track primary) {
    final view = _bucketsByPrimaryUid[primary.uid];
    return view != null && view.hasSiblings;
  }
  double get colLastPlayedWidth => _colLastPlayedWidth;
  double get colTitleWidth => _colTitleWidth;
  double get colArtistWidth => _colArtistWidth;

  List<String> get columnOrder => List.unmodifiable(_columnOrder);

  // ---------------------------------------------------------------------------
  // Settings + UI prefs
  // ---------------------------------------------------------------------------

  Future<void> moveColumn(String column, int targetIndex) async {
    final from = _columnOrder.indexOf(column);
    if (from < 0) return;
    final adjusted = targetIndex > from ? targetIndex - 1 : targetIndex;
    final clamped = adjusted.clamp(0, _columnOrder.length - 1);
    if (clamped == from) return;
    _columnOrder.removeAt(from);
    _columnOrder.insert(clamped, column);
    notifyListeners();
    await repo.setSetting('column_order', _columnOrder.join(','));
  }

  static const _playThresholdPresets = <int>[3, 5, 10, 15, 30];

  Future<void> cyclePlayThreshold() async {
    final idx = _playThresholdPresets.indexOf(_playThresholdSeconds);
    final next =
        _playThresholdPresets[(idx + 1) % _playThresholdPresets.length];
    await _setPlayThresholdSeconds(next);
  }

  double get volume => _volume;

  Future<void> setVolume(double v, {bool commit = false}) async {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    if (clamped == _volume) {
      if (commit) await repo.setSetting('volume', _volume.toString());
      return;
    }
    _volume = clamped;
    volumeListenable.value = _volume;
    await engine.setVolume(_volume);
    if (commit) await repo.setSetting('volume', _volume.toString());
  }

  bool get sidebarVisible => _sidebarVisible;
  double get sidebarWidth => _sidebarWidth;

  Future<void> toggleSidebarVisible() async {
    _sidebarVisible = !_sidebarVisible;
    notifyListeners();
    await repo.setSetting('sidebar_visible', _sidebarVisible ? '1' : '0');
  }

  Future<void> setSidebarWidth(double w, {bool commit = false}) async {
    final clamped = w.clamp(sidebarMinWidth, sidebarMaxWidth).toDouble();
    if (clamped == _sidebarWidth) {
      if (commit) {
        await repo.setSetting('sidebar_width', _sidebarWidth.toString());
      }
      return;
    }
    _sidebarWidth = clamped;
    notifyListeners();
    if (commit) {
      await repo.setSetting('sidebar_width', _sidebarWidth.toString());
    }
  }

  Future<void> _setPlayThresholdSeconds(int s) async {
    _playThresholdSeconds = s;
    notifyListeners();
    await repo.setSetting('play_threshold_seconds', s.toString());
  }

  Future<void> setColumnWidth(
    String column,
    double width, {
    bool commit = true,
  }) async {
    double clamped;
    switch (column) {
      case 'fav':
        clamped = width.clamp(28.0, 80.0);
        _colFavWidth = clamped;
        break;
      case 'rev':
        clamped = width.clamp(28.0, 80.0);
        _colRevWidth = clamped;
        break;
      case 'bpm':
        clamped = width.clamp(36.0, 120.0);
        _colBpmWidth = clamped;
        break;
      case 'key':
        clamped = width.clamp(36.0, 120.0);
        _colKeyWidth = clamped;
        break;
      case 'time':
        clamped = width.clamp(40.0, 120.0);
        _colTimeWidth = clamped;
        break;
      case 'format':
        clamped = width.clamp(44.0, 120.0);
        _colFormatWidth = clamped;
        break;
      case 'plays':
        clamped = width.clamp(36.0, 120.0);
        _colPlaysWidth = clamped;
        break;
      case 'lastPlayed':
        clamped = width.clamp(70.0, 160.0);
        _colLastPlayedWidth = clamped;
        break;
      case 'title':
        clamped = width.clamp(120.0, 1500.0);
        _colTitleWidth = clamped;
        break;
      case 'artist':
        clamped = width.clamp(100.0, 1200.0);
        _colArtistWidth = clamped;
        break;
      default:
        return;
    }
    notifyListeners();
    if (commit) {
      await repo.setSetting('col_${column}_width', clamped.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Track lookups
  // ---------------------------------------------------------------------------

  int sourceTrackCount(String sourceId) {
    // Per-source counts depend only on which tracks belong to which
    // source, not the user's filter. Key on `_dataVersion` so
    // sidebar tile counts stay valid across source / search / sort
    // changes.
    if (_sourceCountCache == null ||
        _sourceCountCacheVersion != _dataVersion) {
      _sourceCountCache = _computeAllSourceCounts();
      _sourceCountCacheVersion = _dataVersion;
    }
    return _sourceCountCache![sourceId] ?? 0;
  }

  /// Walk the in-memory tracks once and bucket per source. Sub-views
  /// (filtered lenses) get their own count from a path-prefix match
  /// against the parent's tracks. Called once per library-version
  /// change; subsequent reads are O(1).
  Map<String, int> _computeAllSourceCounts() {
    final counts = <String, int>{};
    final subViews = [for (final s in _sources) if (s.isSubView) s];
    for (final t in _tracks) {
      counts[t.sourceId] = (counts[t.sourceId] ?? 0) + 1;
      for (final sv in subViews) {
        if (sv.parentSourceId == t.sourceId &&
            t.path.startsWith(sv.pathPrefix!)) {
          counts[sv.id] = (counts[sv.id] ?? 0) + 1;
        }
      }
    }
    return counts;
  }

  Track? get currentTrack {
    final uid = _currentTrackUid;
    if (uid == null) return null;
    return _tracksByUid[uid];
  }

  Track? _trackByUid(String uid) => _tracksByUid[uid];

  Track? _trackByPath(String path) => _tracksByPath[path];

  /// Replace the in-memory track list and rebuild the lookup maps.
  /// Call sites: hydrate, scan reload, import.
  void _replaceTracks(List<Track> tracks) {
    _tracks
      ..clear()
      ..addAll(tracks);
    _tracksByUid.clear();
    _tracksByPath.clear();
    for (final t in tracks) {
      _tracksByUid[t.uid] = t;
      _tracksByPath[t.path] = t;
    }
  }

  /// Remove tracks where [test] returns true, keeping the maps in
  /// sync. Used by `removeSource` for top-level sources.
  void _removeTracksWhere(bool Function(Track) test) {
    _tracks.removeWhere((t) {
      if (test(t)) {
        _tracksByUid.remove(t.uid);
        _tracksByPath.remove(t.path);
        return true;
      }
      return false;
    });
  }

  List<Track> get recentReviewedTracks => [
    for (final uid in _recentReviewedUids)
      if (_trackByUid(uid) != null) _trackByUid(uid)!,
  ];

  void _pushRecentReviewed(String uid) {
    _recentReviewedUids.remove(uid);
    _recentReviewedUids.insert(0, uid);
    if (_recentReviewedUids.length > _recentBufferCapacity) {
      _recentReviewedUids.removeLast();
    }
  }

  int? trailIndexOf(String uid) {
    final upper = _recentReviewedUids.length < _trailVisibleCount
        ? _recentReviewedUids.length
        : _trailVisibleCount;
    for (var i = 0; i < upper; i++) {
      if (_recentReviewedUids[i] == uid) return i;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Visible-tracks pipeline
  // ---------------------------------------------------------------------------

  List<Track> get visibleTracks {
    if (_visibleCache != null && _visibleCacheVersion == _libraryVersion) {
      return _visibleCache!;
    }
    final result = _computeGroupedVisible();
    _visibleCache = result;
    _visibleCacheVersion = _libraryVersion;
    return result;
  }

  // ---------------------------------------------------------------------------
  // Grouped pipeline: group ALL tracks by song identity first, then filter
  // at the bucket level (source / unreviewed / search). Sort and sticky-
  // current operate on primaries using aggregated values. This is the path
  // that keeps a song's variant set intact across source views — e.g., when
  // the user navigates into "Z CRATE", a song whose MP3 lives in a different
  // crate still shows `MP3 · AIFF` and the favorite that was set on the MP3.
  // ---------------------------------------------------------------------------

  List<Track> _computeGroupedVisible() {
    // Step 1: group the whole library. Order each bucket so the
    // lowest-quality format (the displayed primary) is at index 0.
    // Unavailable variants (file deleted / removed since last scan,
    // marked `is_available = 0`) are dropped from the bucket so the
    // FORMAT cell count, the primary picker, and the right-click
    // submenu all stop referencing them as soon as a rescan marks
    // them gone. If every variant in a bucket is unavailable, the
    // bucket disappears from the visible table entirely — its
    // intelligence still lives on the `tracks` row (guardrail 5)
    // and reconnects automatically if the user adds the file back.
    final rawBuckets = groupBySongIdentity(_tracks);
    final buckets = <List<Track>>[];
    for (final raw in rawBuckets) {
      final available =
          raw.where((t) => t.isAvailable).toList(growable: false);
      if (available.isEmpty) continue;
      buckets.add(orderBucketByPlaybackPreference(available));
    }
    // Build the per-bucket aggregated view once so filter / sort don't
    // have to recompute.
    final views = <String, AggregatedTrackView>{
      for (final b in buckets) b.first.uid: AggregatedTrackView(b),
    };

    // Step 2: bucket-level filtering. A bucket passes if ANY variant
    // satisfies the filter. This keeps variant sets intact across
    // source / search views — the user sees the song with full
    // FORMAT aggregation and aggregated stats regardless of which
    // crate / folder they're currently looking at.
    Iterable<List<Track>> filtered = buckets;

    if (_selectedSourceId != null) {
      final selected = _sourceById(_selectedSourceId!);
      bool matchesSource(Track t) {
        if (selected != null && selected.isSubView) {
          return t.sourceId == selected.parentSourceId &&
              t.path.startsWith(selected.pathPrefix!);
        }
        return t.sourceId == _selectedSourceId;
      }
      filtered = filtered.where((b) => b.any(matchesSource));
    }

    if (_unreviewedOnly) {
      final exemptUids = _unreviewedExemptUids();
      filtered = filtered.where((b) {
        // Aggregated reviewed = any variant's cumulativeListened sum
        // ≥ threshold. Exempt-uid match on any variant keeps the
        // recent-reviewed trail and the currently-playing bucket
        // visible while filtering everything else.
        final view = views[b.first.uid]!;
        if (!view.reviewed) return true;
        return b.any((t) => exemptUids.contains(t.uid));
      });
    }

    if (_searchQuery.isNotEmpty) {
      final matcher = _buildSearchMatcher();
      filtered = filtered.where((b) => b.any(matcher));
    }

    // Step 3: emit primaries and sort using aggregated values where
    // applicable so the user's mental model ("the song has 13 plays")
    // matches what they sort by.
    final primaries = filtered.map((b) => b.first).toList();
    final dir = _sortAscending ? 1 : -1;
    primaries.sort((a, b) {
      final va = views[a.uid]!;
      final vb = views[b.uid]!;
      switch (_sortColumn) {
        case TrackSortColumn.favorite:
          return dir * ((va.favorite ? 1 : 0) - (vb.favorite ? 1 : 0));
        case TrackSortColumn.reviewed:
          return dir * ((va.reviewed ? 1 : 0) - (vb.reviewed ? 1 : 0));
        case TrackSortColumn.title:
          return dir *
              a.displayTitle
                  .toLowerCase()
                  .compareTo(b.displayTitle.toLowerCase());
        case TrackSortColumn.artist:
          final aa = a.displayArtist.toLowerCase();
          final ba = b.displayArtist.toLowerCase();
          if (aa.isEmpty && ba.isEmpty) return 0;
          if (aa.isEmpty) return 1;
          if (ba.isEmpty) return -1;
          return dir * aa.compareTo(ba);
        case TrackSortColumn.bpm:
          // Aggregated BPM honours blank-on-disagreement. Buckets
          // with a usable value sort numerically; rows that show "—"
          // sink to the bottom in both directions.
          final ab = va.bpm;
          final bb = vb.bpm;
          if (ab == null && bb == null) return 0;
          if (ab == null) return 1;
          if (bb == null) return -1;
          return dir * ab.compareTo(bb);
        case TrackSortColumn.key:
          final ak = camelotSortIndex(va.displayKey);
          final bk = camelotSortIndex(vb.displayKey);
          if (ak == unknownSortIndex && bk == unknownSortIndex) return 0;
          if (ak == unknownSortIndex) return 1;
          if (bk == unknownSortIndex) return -1;
          return dir * ak.compareTo(bk);
        case TrackSortColumn.duration:
          return dir * a.duration.compareTo(b.duration);
        case TrackSortColumn.format:
          // Each click on the FORMAT header rotates which format
          // leads. The bucket's sort key is the best (lowest) rank
          // any of its formats achieves under the current rotation.
          // Direction toggle doesn't apply to FORMAT — the click
          // advances the lead instead of flipping asc/desc.
          final ar = _formatBucketRank(va);
          final br = _formatBucketRank(vb);
          if (ar == _unknownFormatRank && br == _unknownFormatRank) return 0;
          if (ar == _unknownFormatRank) return 1;
          if (br == _unknownFormatRank) return -1;
          return ar.compareTo(br);
        case TrackSortColumn.plays:
          return dir * va.playCount.compareTo(vb.playCount);
        case TrackSortColumn.lastPlayed:
          final la = va.lastPlayedAt;
          final lb = vb.lastPlayedAt;
          if (la == null && lb == null) return 0;
          if (la == null) return 1;
          if (lb == null) return -1;
          return dir * la.compareTo(lb);
      }
    });

    // Step 4: sticky-current. The current track may be the primary OR
    // a sibling — pin whichever bucket *contains* it. Matches the
    // existing flat-pipeline rule (lock natural index on first
    // observation, otherwise move the row to honour the lock).
    _applyStickyCurrent(primaries, (primary) {
      final view = views[primary.uid]!;
      return view.variants.any((t) => t.uid == _currentTrackUid);
    });

    // Step 5: trim the bucket map to visible primaries only. The table
    // builds row-level renderers off this map (`aggregatedViewForPrimary`)
    // and consults it for context-menu variant lists — no point
    // exposing buckets the user can't see in the current view.
    final visibleViews = <String, AggregatedTrackView>{
      for (final p in primaries) p.uid: views[p.uid]!,
    };
    _bucketsByPrimaryUid = visibleViews;
    return primaries;
  }

  // ---------------------------------------------------------------------------
  // Shared filter / sort / sticky helpers — kept private to the controller.
  // ---------------------------------------------------------------------------

  Set<String> _unreviewedExemptUids() {
    final exempt = <String>{};
    if (_currentTrackUid != null) exempt.add(_currentTrackUid!);
    final upper = _recentReviewedUids.length < _trailVisibleCount
        ? _recentReviewedUids.length
        : _trailVisibleCount;
    for (var i = 0; i < upper; i++) {
      exempt.add(_recentReviewedUids[i]);
    }
    return exempt;
  }

  /// Builds the per-track search predicate. Reused by both pipelines so
  /// the search semantics ("Dm" finds 7A-tagged, "7A" finds Dm-tagged,
  /// raw musicalKey contains, display fields contain) stay identical
  /// whether grouping is on or off.
  bool Function(Track) _buildSearchMatcher() {
    final q = _searchQuery.toLowerCase();
    final qCamelot = normalizeKeyToCamelot(_searchQuery)?.toLowerCase();
    return (t) {
      if (t.displayTitle.toLowerCase().contains(q)) return true;
      if (t.displayArtist.toLowerCase().contains(q)) return true;
      if (t.rawKey.toLowerCase().contains(q)) return true;
      if (t.displayKey.toLowerCase().contains(q)) return true;
      if (qCamelot != null && t.displayKey.toLowerCase() == qCamelot) {
        return true;
      }
      return false;
    };
  }

  /// Locks the row identified by [matchesCurrent] to the index where it
  /// first appeared in the sorted list; if it later sorts to a
  /// different natural position (because its play count / favorite /
  /// last-played changed under the hood), move it back to the locked
  /// index so the user's eye doesn't have to chase the row.
  void _applyStickyCurrent(
    List<Track> rows,
    bool Function(Track) matchesCurrent,
  ) {
    if (_currentTrackUid == null) return;
    final naturalIdx = rows.indexWhere(matchesCurrent);
    if (naturalIdx < 0) return;
    if (_lockedCurrentIndex == null) {
      _lockedCurrentIndex = naturalIdx;
      return;
    }
    if (naturalIdx == _lockedCurrentIndex) return;
    final t = rows.removeAt(naturalIdx);
    final insertAt = _lockedCurrentIndex!.clamp(0, rows.length);
    rows.insert(insertAt, t);
  }

  /// Sentinel rank for a bucket that contains no format in
  /// `formatSortLeads`. Such buckets sort to the very end of the
  /// FORMAT-column ordering regardless of the current lead.
  static const int _unknownFormatRank = 1 << 20;

  /// Rank a bucket under the current FORMAT-column sort rotation.
  /// Returns the lowest position any of its formats occupies in the
  /// rotated priority list — so a bucket containing the current
  /// leading format always sorts to position 0, and the next-best
  /// format wins among the remainder. Unknown-format buckets
  /// (`fileFormatLabel` returned empty or a non-leads value) return
  /// [_unknownFormatRank].
  int _formatBucketRank(AggregatedTrackView view) {
    const leadCount = 4; // matches formatSortLeads.length
    // Build the rotated priority order: starting at the current
    // mode, wrapping around the list. mode 0 = [MP3, FLAC, WAV, AIFF],
    // mode 1 = [FLAC, WAV, AIFF, MP3], etc.
    int best = _unknownFormatRank;
    for (final t in view.variants) {
      final f = fileFormatLabel(t.filename);
      if (f.isEmpty) continue;
      final origIdx = formatSortLeads.indexOf(f);
      if (origIdx < 0) continue;
      final rotatedIdx =
          (origIdx - _sortFormatMode + leadCount) % leadCount;
      if (rotatedIdx < best) best = rotatedIdx;
    }
    return best;
  }

  void _markLibraryDirty() {
    _libraryVersion++;
    _dataVersion++;
    _visibleCache = null;
    // Source-count cache uses `_dataVersion` and invalidates lazily
    // on the next `sourceTrackCount` call.
  }

  /// Filter-only invalidation — search, source selection, sort,
  /// unreviewed-only toggle, sticky-current shifts. Bumps just the
  /// visible-cache version; library-wide counts (songCount,
  /// sourceTrackCount, multiVariantBucketCount, etc) stay valid
  /// because the underlying track data didn't change. Reduces
  /// per-keystroke cost on the search box from ~3 O(n) recomputes
  /// down to just the necessary visible-tracks rebuild.
  void _markFilterDirty() {
    _libraryVersion++;
    _visibleCache = null;
  }

  /// Bumped only when track DATA changes (list mutations, isAvailable
  /// flips, intel field updates). Used by caches whose value depends
  /// solely on the track set, not on filter state.
  int _dataVersion = 0;

  /// Coalesced notifier used by long-running enrichment loops
  /// (metadata extraction, future reconciliation). Guarantees at
  /// most one rebuild per ~500ms while still firing eventually
  /// after the last update.
  void _notifyThrottled() {
    final now = DateTime.now();
    final since = now.difference(_lastThrottledNotifyAt).inMilliseconds;
    if (since >= 500) {
      _lastThrottledNotifyAt = now;
      _throttledNotifyTimer?.cancel();
      _throttledNotifyTimer = null;
      notifyListeners();
      return;
    }
    if (_throttledNotifyTimer?.isActive == true) return;
    _throttledNotifyTimer = Timer(
      Duration(milliseconds: 500 - since),
      () {
        _lastThrottledNotifyAt = DateTime.now();
        _throttledNotifyTimer = null;
        notifyListeners();
      },
    );
  }

  void _invalidateLock() {
    _lockedCurrentIndex = null;
  }

  // ---------------------------------------------------------------------------
  // Sources — add / rescan / remove
  // ---------------------------------------------------------------------------

  /// Find the top-level scanning source whose `folder_path` contains
  /// [pickedPath] as a strict descendant. Returns `null` if [pickedPath]
  /// equals an existing source path or isn't nested under any.
  ///
  /// Sub-views are skipped — only scanning sources can become parents
  /// (nested-of-nested collapses to "sub-view of the top-level
  /// scanning ancestor").
  Source? findContainingSource(String pickedPath) {
    final sep = Platform.pathSeparator;
    for (final s in _sources) {
      if (s.isSubView) continue;
      if (pickedPath == s.folderPath) return null; // exact match
      final prefix = s.folderPath.endsWith(sep)
          ? s.folderPath
          : s.folderPath + sep;
      if (pickedPath.startsWith(prefix)) return s;
    }
    return null;
  }

  Source? _sourceById(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Add a new watched source.
  ///
  /// If [folderPath] is nested inside an existing top-level source,
  /// this short-circuits to a virtual sub-view (no scan, no
  /// `indexed_files` writes, no source-ownership transfer). Otherwise
  /// it's a fresh top-level scanning source: performs the initial
  /// scan with the requested [scanMode] and indexes discovered files
  /// into `indexed_files`. Workflow intelligence is **not** materialised
  /// during scan — that happens lazily on user interaction.
  Future<void> addSource(
    String folderPath,
    ScanMode scanMode, {
    String? displayName,
  }) async {
    debugPrint('[addSource] path=$folderPath mode=$scanMode');
    if (_sources.any((s) => s.folderPath == folderPath)) {
      final existing = _sources.firstWhere((s) => s.folderPath == folderPath);
      debugPrint(
        '[addSource] exact match → ${existing.isSubView ? "subview, return" : "rescan"}',
      );
      if (existing.isSubView) return; // sub-views never scan
      await rescanSource(existing.id);
      return;
    }

    final containing = findContainingSource(folderPath);
    debugPrint(
      '[addSource] containing=${containing?.displayName ?? "<none>"}',
    );
    if (containing != null) {
      await _addSubView(folderPath, parent: containing, displayName: displayName);
      return;
    }

    final source = Source(
      id: _uuid.v4(),
      displayName: displayName ?? _displayNameFor(folderPath),
      folderPath: folderPath,
      scanMode: scanMode,
      enabled: true,
      lastScanAt: null,
      trackCount: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    await repo.insertSource(source);
    _sources.add(source);
    notifyListeners();

    await _scanIntoSource(source);
    unawaited(_startWatcher(source));
  }

  /// Insert a sub-view source row. Sub-views never scan, never own
  /// `indexed_files` rows, never participate in availability —
  /// they're virtual filtered lenses over the parent's tracks
  /// keyed by exact path-prefix.
  Future<void> _addSubView(
    String folderPath, {
    required Source parent,
    String? displayName,
  }) async {
    final sep = Platform.pathSeparator;
    final prefix = folderPath.endsWith(sep) ? folderPath : folderPath + sep;
    final source = Source(
      id: _uuid.v4(),
      displayName: displayName ?? _displayNameFor(folderPath),
      folderPath: folderPath,
      scanMode: ScanMode.recursive, // unused for sub-views
      enabled: true,
      lastScanAt: null,
      trackCount: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      parentSourceId: parent.id,
      pathPrefix: prefix,
    );
    // Don't swallow insert errors — earlier silent-failure variant
    // produced the "toast says added, sidebar shows nothing" bug
    // because the snackbar was fired regardless of DB outcome.
    // Letting the exception propagate lets the sidebar surface the
    // real error to the user.
    await repo.insertSource(source);
    debugPrint(
      '[_addSubView] inserted id=${source.id} parent=${parent.id} prefix=$prefix',
    );
    _sources.add(source);
    _markLibraryDirty();
    notifyListeners();
  }

  /// Re-scan an existing source. Existing rows for this source whose
  /// files are still present are preserved (intelligence intact); rows
  /// not seen this scan are flagged unavailable, never deleted.
  ///
  /// Concurrent requests for the same source dedupe: a second caller
  /// while a scan is in flight gets the same Future as the first.
  /// Without this guard, the FS watcher + focus-rescan + manual
  /// REFRESH could all kick off overlapping scans of the same source
  /// at the same time and race on a shared SQLite transaction —
  /// `txnSynchronized` would then throw mid-batch and the whole
  /// rescan would abort before `markUnseenAvailability` ever ran.
  Future<void> rescanSource(String sourceId) async {
    final inFlight = _scansInFlight[sourceId];
    if (inFlight != null) return inFlight;
    final idx = _sources.indexWhere((s) => s.id == sourceId);
    if (idx < 0) return;
    final future = _scanIntoSource(_sources[idx])
        .whenComplete(() => _scansInFlight.remove(sourceId));
    _scansInFlight[sourceId] = future;
    return future;
  }

  // Per-source scan dedup map. See `rescanSource`.
  final Map<String, Future<void>> _scansInFlight = {};

  Future<void> _scanIntoSource(Source source) async {
    _isScanning = true;
    // Yield SQLite + disk to the foreground scan. The backfill
    // worker is best-effort by design; we'll restart it after the
    // scan finishes, picking up wherever it left off (the
    // candidates query is stateless).
    _backfillWorker.cancel();
    // Reset the hashing instrumentation so the per-scan summary
    // log at the end of this call reflects only THIS scan's work.
    ContentHashStats.reset();
    notifyListeners();
    try {
      // Snapshot the in-memory unavailable count BEFORE the rescan
      // so we can log how many rows changed availability. Quick
      // diagnostic — exposes whether the scan is actually marking
      // deleted files as gone.
      final preUnavailable =
          _tracks.where((t) => t.sourceId == source.id && !t.isAvailable).length;
      final scanStart = Stopwatch()..start();
      // Disk walk + per-file stat now happen inside the scanner
      // isolate; the UI thread stays responsive even on huge cloud
      // libraries.
      final entries = await AudioScanner.scan(
        source.folderPath,
        recursive: source.scanMode == ScanMode.recursive,
      );
      debugPrint(
        '[scan] ${source.displayName}: walked ${entries.length} files in '
        '${scanStart.elapsedMilliseconds}ms (pre-unavailable=$preUnavailable)',
      );

      // Build the batch payload. Carry forward already-known durations
      // so the fingerprint stays stable when we re-upsert files we've
      // already seen.
      final knownPaths = <String>{};
      final batch = <({
        String path,
        String filename,
        int filesize,
        int modifiedAtMs,
        String fallbackTitle,
        int durationMs
      })>[];
      for (final e in entries) {
        final existing = _trackByPath(e.path);
        if (existing != null) knownPaths.add(e.path);
        batch.add((
          path: e.path,
          filename: e.filename,
          filesize: e.filesize,
          modifiedAtMs: e.modifiedAtMs,
          fallbackTitle: filenameWithoutExtension(e.path),
          durationMs: existing?.duration.inMilliseconds ?? 0,
        ));
      }

      // Upsert can throw (UNIQUE constraint, SQLite lock, schema
      // mismatch); we want the rescan to keep going so deleted files
      // still get marked unavailable downstream. Otherwise an upsert
      // failure mid-scan leaves the in-memory state stale forever.
      final upsertStart = Stopwatch()..start();
      try {
        final inserted = await repo.upsertIndexedFilesBatch(
          sourceId: source.id,
          files: batch,
        );
        debugPrint(
          '[scan] upsert batch: ${batch.length} files '
          '($inserted new) in ${upsertStart.elapsedMilliseconds}ms',
        );
      } catch (e, st) {
        debugPrint(
          '[scan] upsert FAILED for ${source.displayName} '
          '(continuing with availability sweep): $e',
        );
        debugPrint('$st');
      }

      await repo.markUnseenAvailability(
        source.id,
        {for (final e in entries) e.path},
      );

      // Auto-detect moved files: any row left in `missing` state
      // whose fingerprint matches an `available` row in the same
      // source is almost certainly a file the user moved within
      // the source. Upgrade those rows to `superseded` so they
      // drop out of the "missing" tally and out of the table —
      // but stay around for the Review-missing dialog.
      final supersededCount =
          await repo.markMovedSupersessions(source.id);
      if (supersededCount > 0) {
        debugPrint(
          '[scan] ${source.displayName}: $supersededCount moved '
          'file(s) auto-detected via fingerprint match',
        );
      }

      // Cross-source relocation pass. Handles the intake → prep
      // → crate workflow: a file moved from one watched source
      // into another should auto-resolve instead of lingering as
      // missing. Strict uniqueness rule (see repo doc) — only
      // fires when exactly one valid same-fingerprint available
      // candidate exists across all sources. Idempotent; we run
      // it on every scan so any source-scan order produces the
      // same final state.
      final crossSourceCount = await repo.markCrossSourceMoves();
      if (crossSourceCount > 0) {
        debugPrint(
          '[scan] cross-source relocation: $crossSourceCount '
          'missing row(s) auto-resolved against a unique '
          'available copy in another watched source',
        );
      }

      // Re-link any new indexed_files row to its existing tracks
      // row by fingerprint. This is what makes "remove → re-add"
      // preserve favorites / play counts visibly: without this,
      // the table would show 0/false until each row was clicked.
      final reconnected =
          await repo.reconnectIntelligenceBySource(source.id);
      debugPrint('[scan] reconnected $reconnected rows to existing intelligence');

      // Reload tracks — rebuild the in-memory list so intel_uid
      // changes (fingerprint migration on re-tag) propagate and
      // newly-discovered rows become visible.
      final allTracks = await repo.loadTracks();
      _replaceTracks(allTracks);

      // Post-scan re-enrichment trigger. The scan upsert marks
      // a row's `metadata_read_at = 0` whenever its
      // `content_hash` diverged at the same path — that's the
      // signal "an external app (Mp3tag / Rekordbox / DAW)
      // rewrote tags or audio bytes; the stored title/artist/
      // album/BPM/key fields are now stale." Without an active
      // enqueue here the reactive viewport-driven enrichment
      // only re-reads when the user scrolls the row in or out,
      // and rows already visible would silently stay frozen at
      // the old values.
      //
      // `enrichSource(source.id)` enqueues any indexed_files
      // row for this source whose `metadata_read_at` is null,
      // which covers both newly-inserted rows AND rows the
      // upsert just invalidated. The enrichment queue runs in
      // the background; we don't block the scan completion on
      // it.
      enrichSource(source.id);

      // Diagnostic: how many rows in this source are now unavailable?
      // If preUnavailable < postUnavailable, the scan correctly
      // marked some files as gone. If unchanged after deleting a
      // file, something is broken — most likely the scanner isn't
      // detecting the file as missing (different source_id? trash
      // folder inside the source root? path normalization?).
      final postUnavailable = allTracks
          .where((t) => t.sourceId == source.id && !t.isAvailable)
          .length;
      debugPrint(
        '[scan] ${source.displayName}: rows for this source '
        'now unavailable=$postUnavailable (was $preUnavailable, delta=${postUnavailable - preUnavailable})',
      );

      final count = await repo.countIndexedFiles(source.id);
      final now = DateTime.now().millisecondsSinceEpoch;
      await repo.updateSourceMeta(
        source.id,
        lastScanAt: now,
        trackCount: count,
      );
      final i = _sources.indexWhere((s) => s.id == source.id);
      if (i >= 0) {
        _sources[i] = _sources[i].copyWith(
          lastScanAt: now,
          trackCount: count,
        );
      }

      _invalidateLock();
      _markLibraryDirty();

      // Reactive-first architecture: NO auto-enqueue here. New rows
      // appear in the table immediately at filename-only display;
      // they enrich on demand when the user scrolls them into view,
      // selects them, or plays them. Avoids the post-scan
      // multi-minute Dropbox materialisation storm we used to
      // trigger by enriching the whole library every scan.
    } catch (e, st) {
      debugPrint('[scan] FAILED: $e');
      debugPrint('$st');
    } finally {
      _isScanning = false;
      // Per-scan hashing summary. One line per scan boundary
      // makes performance regressions and pathological files
      // (slow Dropbox reads, AIFFs on slow NAS) visible without
      // needing a full UI.
      debugPrint(
        '[scan] ${source.displayName}: ${ContentHashStats.summary()}',
      );
      // Resume the content_hash backfill now that foreground
      // scanning is done. Picks up any newly-null rows the scan
      // just inserted as well as legacy rows the migration left
      // unhashed.
      _backfillWorker.start();
      notifyListeners();
    }
  }

  /// Start watching [source]'s folder for filesystem events. On any
  /// change (create / modify / delete) inside the folder, schedule a
  /// debounced rescan of just this source so the in-memory library
  /// stays current with what's actually on disk. The user reported
  /// "i just deleted one of those, but still shows up" — this is the
  /// instant-sync path that closes that loop.
  ///
  /// No-op for sub-views (they don't own files), non-existent paths,
  /// and non-macOS platforms (only macOS has been verified to deliver
  /// usable events from `Directory.watch`).
  Future<void> _startWatcher(Source source) async {
    if (!Platform.isMacOS) return;
    if (source.isSubView) return;
    await _stopWatcher(source.id);
    final dir = Directory(source.folderPath);
    if (!await dir.exists()) return;
    try {
      final sub = dir
          .watch(
            events: FileSystemEvent.all,
            recursive: source.scanMode == ScanMode.recursive,
          )
          .listen(
            (event) => _onWatcherEvent(source.id, event),
            onError: (e) => debugPrint(
              '[watcher] ${source.displayName}: $e',
            ),
            cancelOnError: false,
          );
      _watchers[source.id] = sub;
    } catch (e) {
      // Directory.watch can throw on some filesystems (older NFS,
      // unsupported sandbox configurations). Fail soft — manual
      // rescan still works.
      debugPrint('[watcher] failed to start for ${source.displayName}: $e');
    }
  }

  void _onWatcherEvent(String sourceId, FileSystemEvent event) {
    // Useful when diagnosing "I deleted a file but it didn't update":
    // the absence of this log means FSEvents never delivered the
    // change. The lifecycle-resumed rescan covers that case.
    debugPrint('[watcher] $sourceId ${_eventTypeName(event)} '
        '${event.path}${event.isDirectory ? " (dir)" : ""}');
    // Coalesce bursts. A single file save can fire create + modify
    // events in quick succession; a folder move can fire dozens.
    _watcherDebounce[sourceId]?.cancel();
    _watcherDebounce[sourceId] = Timer(_watcherDebounceWindow, () {
      _watcherDebounce.remove(sourceId);
      rescanSource(sourceId);
    });
  }

  String _eventTypeName(FileSystemEvent e) {
    switch (e.type) {
      case FileSystemEvent.create:
        return 'create';
      case FileSystemEvent.modify:
        return 'modify';
      case FileSystemEvent.delete:
        return 'delete';
      case FileSystemEvent.move:
        return 'move';
      default:
        return '?(${e.type})';
    }
  }

  /// Sequential rescan of every non-sub-view source. Triggered when
  /// the app comes back to foreground; covers the case where the
  /// per-source filesystem watcher missed an event. Guarded against
  /// re-entry so rapid focus toggles don't pile rescans on each other.
  Future<void> _rescanAllOnFocus() async {
    if (_focusRescanInFlight) return;
    _focusRescanInFlight = true;
    try {
      debugPrint(
        '[focus] resumed → rescanning ${_sources.length} sources',
      );
      // Snapshot the list — rescanSource awaits and the sources
      // list could mutate (e.g., user removes one mid-rescan).
      for (final source in _sources.toList()) {
        if (source.isSubView) continue;
        try {
          await rescanSource(source.id);
        } catch (e) {
          debugPrint(
            '[focus] rescan failed for ${source.displayName}: $e',
          );
        }
      }
    } finally {
      _focusRescanInFlight = false;
    }
  }

  /// User-triggered "rescan everything now" (Cmd+R). Reuses the
  /// focus-rescan path — same sequential walk over non-sub-view
  /// sources, same re-entry guard. Exposed so the manual escape
  /// hatch matches the automatic one byte-for-byte.
  Future<void> rescanAllSources() => _rescanAllOnFocus();

  Future<void> _stopWatcher(String sourceId) async {
    final sub = _watchers.remove(sourceId);
    await sub?.cancel();
    _watcherDebounce.remove(sourceId)?.cancel();
  }

  Future<void> _stopAllWatchers() async {
    for (final t in _watcherDebounce.values) {
      t.cancel();
    }
    _watcherDebounce.clear();
    final futures = _watchers.values.map((s) => s.cancel()).toList();
    _watchers.clear();
    await Future.wait(futures);
  }

  /// Remove the source. The FK cascade drops `indexed_files` rows under
  /// it; `tracks` rows are intentionally untouched (guardrail 5 — user
  /// work survives source removal). Re-adding the same folder will
  /// reconnect intelligence by fingerprint.
  Future<void> removeSource(String sourceId) async {
    await _stopWatcher(sourceId);
    await repo.deleteSource(sourceId);
    _sources.removeWhere((s) => s.id == sourceId);
    _removeTracksWhere((t) => t.sourceId == sourceId);
    final remainingUids = <String>{for (final t in _tracks) t.uid};
    _recentReviewedUids.removeWhere((uid) => !remainingUids.contains(uid));
    if (_selectedSourceId == sourceId) _selectedSourceId = null;
    if (_currentTrackUid != null &&
        !_tracks.any((t) => t.uid == _currentTrackUid)) {
      await engine.stop();
      _currentTrackUid = null;
      _currentTrackPath = null;
      _isPlaying = false;
      _positionNotifier.value = Duration.zero;
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
    }
    _invalidateLock();
    _markLibraryDirty();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Filter / selection
  // ---------------------------------------------------------------------------

  void selectSource(String? sourceId) {
    _selectedSourceId = sourceId;
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  void toggleUnreviewedOnly() {
    _unreviewedOnly = !_unreviewedOnly;
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  void toggleShowArtwork() {
    _showArtwork = !_showArtwork;
    notifyListeners();
  }

  /// Ordered list of which format leads the FORMAT-column sort.
  /// Each click on the FORMAT header advances through this list,
  /// wrapping at the end. The matcher / display still prefers the
  /// `aggregated_track_view._formatPreferenceOrder` for playback;
  /// this is purely a sort-visualization knob.
  static const List<String> formatSortLeads = [
    'MP3',
    'FLAC',
    'WAV',
    'AIFF',
  ];

  int get sortFormatMode => _sortFormatMode;

  /// The format that leads the current FORMAT-column sort, e.g.
  /// `'MP3'`. Buckets containing this format sort to the top;
  /// remaining buckets fall through to the rest of [formatSortLeads]
  /// in order. Only meaningful when the FORMAT column is the active
  /// sort.
  String get sortFormatLead => formatSortLeads[_sortFormatMode];

  void setSort(TrackSortColumn column) {
    if (_sortColumn == column) {
      // FORMAT cycles through `formatSortLeads` instead of the
      // usual asc/desc flip — each click promotes the next format
      // to the top of the sort.
      if (column == TrackSortColumn.format) {
        _sortFormatMode = (_sortFormatMode + 1) % formatSortLeads.length;
      } else {
        _sortAscending = !_sortAscending;
      }
    } else {
      _sortColumn = column;
      _sortAscending = true;
      if (column == TrackSortColumn.format) {
        _sortFormatMode = 0;
      }
    }
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Intelligence-mutating actions (lazy promotion + bucket consolidation).
  // Each user-driven write goes:
  //   resolve bucket → consolidate intel → mutate canonical → mirror
  //   in-memory across every Track sharing that intel uid.
  // The consolidation step (slice 3) ensures the song-identity bucket
  // shares a single `tracks` row, so favorite / play count / cumulative
  // listening / last-played stay coherent across format variants
  // regardless of which row the user interacted with.
  // ---------------------------------------------------------------------------

  /// Every in-memory Track sharing [t]'s song identity. Uses the
  /// same two-tier rule as the matcher: manual override → 4-field
  /// match → fingerprint match. Linear over `_tracks`; called only
  /// on mutation, so the cost is negligible.
  List<Track> variantsFor(Track t) {
    final out = <Track>[];
    for (final candidate in _tracks) {
      if (sameSongIdentity(t, candidate)) out.add(candidate);
    }
    return out.isEmpty ? [t] : out;
  }

  /// Run [mutate] against the canonical intel uid for [origin]'s
  /// bucket, then mirror canonical state back to every in-memory
  /// Track that points at it. Returns the canonical uid (`null` if
  /// promotion failed — caller should treat as a no-op).
  ///
  /// `mutate` receives the canonical uid and is expected to issue
  /// the `repo.updateIntelligence` write itself. After it returns,
  /// `fetchIntelligence` reads the now-current values and the
  /// helper propagates them to all in-memory tracks sharing the
  /// uid — including bucket variants AND any literal fingerprint
  /// duplicates (which may not be in the same song-identity bucket
  /// but already share intel via the older fingerprint-sharing path).
  Future<String?> _writeBucketIntelligence(
    Track origin,
    Future<void> Function(String canonicalUid) mutate,
  ) async {
    final bucket = variantsFor(origin);
    final canonical = await repo.consolidateBucketIntelligence(
      bucket.map((t) => t.path).toList(),
    );
    if (canonical == null) return null;
    // Mirror the canonical uid onto every bucket variant before
    // running the mutation — keeps the in-memory linkage current
    // even if the mutate call throws.
    for (final v in bucket) {
      v.intelUid = canonical;
    }
    await mutate(canonical);
    final intel = await repo.fetchIntelligence(canonical);
    if (intel != null) {
      for (final t in _tracks) {
        if (t.intelUid != canonical) continue;
        t.favorite = intel.favorite;
        t.playCount = intel.playCount;
        t.cumulativeListened = Duration(milliseconds: intel.cumulativeMs);
        t.lastPlayedAt = intel.lastPlayedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(intel.lastPlayedAt!)
            : null;
      }
    }
    return canonical;
  }

  /// Manually pair [origin] with [target] so they bucket together
  /// regardless of whether the strict 4-field matcher would have
  /// matched them. Both rows receive the same `identityOverride`
  /// value (a fresh UUID), and their intelligence is consolidated
  /// onto a single canonical `tracks` row.
  ///
  /// If [origin] is already part of a bucket (manual or computed),
  /// the override propagates to every variant in that bucket so the
  /// pairing extends transitively — pairing a fifth file to a song
  /// that already has four variants keeps them all together.
  Future<void> linkTracks(Track origin, Track target) async {
    if (origin.uid == target.uid) return;
    final originBucket = variantsFor(origin);
    final targetBucket = variantsFor(target);
    final unique = <String, Track>{
      for (final t in originBucket) t.uid: t,
      for (final t in targetBucket) t.uid: t,
    };
    final allTracks = unique.values.toList();
    if (allTracks.length < 2) return;

    // Pick the override: if any of the involved tracks already had
    // a manual override, reuse it (extending the existing manual
    // bucket); otherwise mint a fresh UUID.
    String? override;
    for (final t in allTracks) {
      final ov = t.identityOverride;
      if (ov != null && ov.isNotEmpty) {
        override = ov;
        break;
      }
    }
    override ??= _uuid.v4();

    // Apply in-memory immediately so the table redraws.
    for (final t in allTracks) {
      t.identityOverride = override;
    }
    _markLibraryDirty();
    notifyListeners();

    // Persist + consolidate intel so the pair shares one canonical
    // `tracks` row (slice 3 mechanism).
    await repo.setIdentityOverride(
      allTracks.map((t) => t.path).toList(),
      value: override,
    );
    await _writeBucketIntelligence(origin, (_) async {});
    _markLibraryDirty();
    notifyListeners();
  }

  /// Tear down [origin]'s song-identity bucket. Every variant becomes
  /// its own singleton (its `identityOverride` is forced to its own
  /// uid, ensuring no future auto-match re-pairs them), and every
  /// piece of *behavioral* intelligence — play count, favorite,
  /// cumulative listened, last played, review state — resets to its
  /// default on all variants.
  ///
  /// Per project memory: unlink means "these are NOT the same song
  /// anymore." File-analysis fields (BPM, key, duration, fingerprint)
  /// live on the per-file row and stay untouched.
  ///
  /// No-ops when the bucket has only one variant — nothing to unlink.
  Future<void> unlinkBucket(Track origin) async {
    final bucket = variantsFor(origin);
    if (bucket.length < 2) return;

    await repo.unlinkBucketIntelligence(
      bucket.map((t) => t.path).toList(),
    );
    // Mirror the DB tear-down into the in-memory tracks so the
    // table redraws immediately without a full reload.
    for (final t in bucket) {
      t.identityOverride = t.uid;
      t.intelUid = null;
      t.favorite = false;
      t.playCount = 0;
      t.cumulativeListened = Duration.zero;
      t.lastPlayedAt = null;
    }
    _markLibraryDirty();
    notifyListeners();
  }

  Future<void> toggleFavorite(String uid) async {
    final t = _trackByUid(uid);
    if (t == null) return;
    final bucket = variantsFor(t);
    // Flip against the value shown on the row the user actually
    // clicked — not the bucket aggregate. With grouping ON every
    // variant in the bucket has the same favorite (consolidation
    // mirrors them) so the two are equivalent. With grouping OFF
    // they can diverge if the user pre-favorited one variant
    // before slice 3 shipped: clicking the as-yet-unfavorited
    // sibling expects to turn the star ON, not OFF, and toggling
    // against the aggregate would silently un-favorite.
    final next = !t.favorite;

    // Optimistic in-memory flip on every bucket variant so the UI
    // updates instantly. _writeBucketIntelligence below will
    // overwrite these with canonical state once persisted.
    for (final v in bucket) {
      v.favorite = next;
    }
    _markLibraryDirty();
    notifyListeners();

    await _writeBucketIntelligence(t, (canonical) async {
      await repo.updateIntelligence(intelUid: canonical, favorite: next);
    });
    _markLibraryDirty();
    notifyListeners();
  }

  Future<void> toggleReviewed(String uid) async {
    final t = _trackByUid(uid);
    if (t == null) return;
    final bucket = variantsFor(t);
    // Same reasoning as toggleFavorite: flip against the clicked
    // row's reviewed state, not the bucket aggregate. Pre-slice-3
    // per-variant divergence would otherwise cause the click to
    // un-review when the user intended to review.
    final reviewed = t.reviewed;
    final nextCumulativeMs = reviewed ? 0 : 3000;

    // Optimistic in-memory update across the bucket.
    final nextDuration = Duration(milliseconds: nextCumulativeMs);
    for (final v in bucket) {
      v.cumulativeListened = nextDuration;
    }
    if (!reviewed) _pushRecentReviewed(uid);
    _markLibraryDirty();
    notifyListeners();

    await _writeBucketIntelligence(t, (canonical) async {
      await repo.updateIntelligence(
        intelUid: canonical,
        cumulativeMs: nextCumulativeMs,
      );
    });
    _markLibraryDirty();
    notifyListeners();
  }

  void cyclePlaybackMode() {
    final values = PlaybackMode.values;
    _playbackMode = values[(_playbackMode.index + 1) % values.length];
    notifyListeners();
  }

  void selectTrack(String? uid) {
    if (_selectedTrackUid == uid) return;
    _selectedTrackUid = uid;
    if (uid != null) {
      // Pre-warm metadata for the row the cursor is on, even if it's
      // outside the viewport (keyboard arrow navigation past the
      // last rendered row, etc.).
      final t = _tracksByUid[uid];
      if (t != null) enrichOnDemand(t.path);
    }
    notifyListeners();
  }

  void selectNextVisible() {
    final list = visibleTracks;
    if (list.isEmpty) return;
    final cursor = _selectedTrackUid ?? _currentTrackUid;
    if (cursor == null) {
      _selectedTrackUid = list.first.uid;
    } else {
      final idx = list.indexWhere((t) => t.uid == cursor);
      if (idx < 0) {
        _selectedTrackUid = list.first.uid;
      } else if (idx < list.length - 1) {
        _selectedTrackUid = list[idx + 1].uid;
      } else {
        _selectedTrackUid = list.last.uid;
      }
    }
    notifyListeners();
  }

  void selectPreviousVisible() {
    final list = visibleTracks;
    if (list.isEmpty) return;
    final cursor = _selectedTrackUid ?? _currentTrackUid;
    if (cursor == null) {
      _selectedTrackUid = list.first.uid;
    } else {
      final idx = list.indexWhere((t) => t.uid == cursor);
      if (idx <= 0) {
        _selectedTrackUid = list.first.uid;
      } else {
        _selectedTrackUid = list[idx - 1].uid;
      }
    }
    notifyListeners();
  }

  Future<void> playSelected() async {
    final uid = _selectedTrackUid;
    if (uid == null) return;
    await play(uid, reveal: true);
  }

  void revealCurrent() {
    if (_currentTrackUid == null) return;
    if (_selectedTrackUid != _currentTrackUid) {
      _selectedTrackUid = _currentTrackUid;
      notifyListeners();
    }
    _revealTick.value = _revealTick.value + 1;
  }

  /// Reveal a specific track instance in Finder. Used by row-level
  /// actions (right-click → Show in Finder).
  ///
  /// **Currently-playing instance wins**: if a track is playing and
  /// shares this row's intelligence (same `intelUid`), reveal the
  /// playing file instead — duplicate rows of the playing track all
  /// reveal the file on the engine. Otherwise the row's own path is
  /// the preferred target, with a fallback to other available
  /// siblings if that file is missing.
  /// Reveal a specific variant in Finder without the
  /// currently-playing override or the sibling fallback. Used by
  /// the multi-variant right-click submenu: when the user explicitly
  /// picks "Show MP3 in Finder" or "Show AIFF in Finder", honor
  /// exactly that pick — don't silently substitute the playing file
  /// or another sibling. If the picked variant is missing on disk,
  /// no-op (debug-printed).
  Future<void> revealVariantInFinder(Track t) async {
    if (!Platform.isMacOS) return;
    if (!t.isAvailable) {
      debugPrint('[finder] requested variant is unavailable: ${t.path}');
      return;
    }
    await _runFinderReveal(t.path);
  }

  Future<void> showTrackInstanceInFinder(Track t) async {
    if (_currentTrackUid != null &&
        _currentTrackPath != null &&
        t.intelUid != null &&
        currentTrack?.intelUid == t.intelUid) {
      await showCurrentTrackInFinder();
      return;
    }
    await _revealInFinderWithFallback(
      preferredPath: t.path,
      intelUid: t.intelUid,
    );
  }

  /// Reveal the file the engine is currently playing in Finder. Used
  /// by the utility-rail button. No-op if nothing is playing.
  Future<void> showCurrentTrackInFinder() async {
    final path = _currentTrackPath;
    if (path == null) return;
    await _revealInFinderWithFallback(
      preferredPath: path,
      intelUid: currentTrack?.intelUid,
    );
  }

  /// Resolver: open [preferredPath] if present and available; else
  /// fall back to the most-recently-seen available sibling (any
  /// `Track` whose `intelUid` matches and whose file is on disk).
  /// Never randomly picks — `last_seen_at` orders deterministically;
  /// if there's no usable instance, no-op + debugPrint.
  Future<void> _revealInFinderWithFallback({
    required String preferredPath,
    required String? intelUid,
  }) async {
    if (!Platform.isMacOS) return;
    final preferred = _trackByPath(preferredPath);
    if (preferred != null && preferred.isAvailable) {
      await _runFinderReveal(preferred.path);
      return;
    }
    if (intelUid != null) {
      Track? best;
      for (final t in _tracks) {
        if (t.intelUid != intelUid) continue;
        if (!t.isAvailable) continue;
        if (t.path == preferredPath) continue;
        if (best == null || t.lastSeenAt > best.lastSeenAt) best = t;
      }
      if (best != null) {
        await _runFinderReveal(best.path);
        return;
      }
    }
    debugPrint(
      '[finder] no available instance to reveal '
      '(preferred=$preferredPath, intelUid=$intelUid)',
    );
  }

  Future<void> _runFinderReveal(String path) async {
    try {
      await Process.run('open', ['-R', path]);
    } catch (_) {
      // best-effort
    }
  }

  Future<void> goBack() async {
    if (_recentReviewedUids.isNotEmpty &&
        _recentReviewedUids[0] != _currentTrackUid) {
      await play(_recentReviewedUids[0], reveal: true);
    } else {
      await previous();
    }
  }

  /// Try to play [origin]'s bucket, falling back through sibling
  /// variants when the chosen file is missing or the engine rejects
  /// it. Returns the Track whose file was actually loaded into the
  /// engine, or `null` if every variant failed.
  ///
  /// Order: requested track first (the user's explicit preference,
  /// e.g. clicking the AIFF row plays the AIFF), then the rest of
  /// the bucket in playback-preference order. Each candidate that
  /// fails has its in-memory `isAvailable` flipped to false so the
  /// table redraws without it on the next pipeline run; persistence
  /// will catch up on the next rescan.
  Future<Track?> _tryPlayBucket(Track origin) async {
    final bucket = variantsFor(origin);
    final ordered = orderBucketByPlaybackPreference(bucket);
    // Move origin to the front if it's in the bucket (user explicit
    // preference wins over the playback-preference default).
    final candidates = <Track>[origin];
    for (final v in ordered) {
      if (v.uid != origin.uid) candidates.add(v);
    }
    for (final candidate in candidates) {
      if (!candidate.isAvailable) {
        debugPrint(
          '[play] skipping unavailable variant: ${candidate.path}',
        );
        continue;
      }
      // Defensive pre-flight: if the file was marked available but
      // is actually gone from disk (rescan hasn't fired yet), avoid
      // the slower engine.setTrack failure and flip the in-memory
      // flag immediately so the row drops from the table.
      if (!File(candidate.path).existsSync()) {
        debugPrint(
          '[play] file missing on disk, marking unavailable: '
          '${candidate.path}',
        );
        candidate.isAvailable = false;
        continue;
      }
      try {
        await engine.setTrack(candidate.path);
        return candidate;
      } catch (e) {
        debugPrint(
          '[play] engine.setTrack failed for ${candidate.path}: $e — '
          'trying next variant',
        );
        // Engine errors can be transient — a Dropbox CloudStorage
        // file being materialised, a codec stall, a momentary
        // lock by another process, the engine still tearing down
        // a prior track. Previously we flipped `isAvailable=false`
        // here, which broke retries: after one transient failure
        // the row would silently fail on every subsequent click
        // until a rescan re-synced in-memory from DB. The terminal
        // case ("file actually gone") is already caught by the
        // `File.existsSync()` pre-flight above, so engine errors
        // get treated as "try the next variant this attempt" and
        // leave the in-memory flag alone.
      }
    }
    return null;
  }

  Future<void> play(String uid, {bool reveal = false}) async {
    // Per-step millisecond timing of the play path. Each `tick` call
    // logs the cumulative + delta against the last tick. Goal: the
    // segment from `entry` → `engine.setTrack returned` should be
    // <50 ms on local files; anything longer surfaces a real
    // bottleneck (sort, DB writes, listener storms, etc.).
    final sw = Stopwatch()..start();
    var lastMs = 0;
    void tick(String label) {
      final now = sw.elapsedMilliseconds;
      debugPrint('[play t+${now}ms +${now - lastMs}ms] $label');
      lastMs = now;
    }

    tick('entry uid=$uid');
    final track = _trackByUid(uid);
    tick('lookup → ${track == null ? "null" : "ok"}');
    if (track == null) {
      debugPrint('[play] unknown uid: $uid');
      return;
    }
    final isNewTrack = _currentTrackUid != uid;
    if (isNewTrack) {
      await _flushCurrentTrack();
      tick('_flushCurrentTrack');
      final visible = visibleTracks;
      tick('visibleTracks (${visible.length} rows, sort cost included)');
      final displayedIdx = visible.indexWhere((t) => t.uid == uid);
      tick('indexWhere');
      _currentTrackUid = uid;
      _selectedTrackUid = uid;
      _lockedCurrentIndex = displayedIdx >= 0 ? displayedIdx : null;
      _positionNotifier.value = Duration.zero;
      _lastTickPosition = Duration.zero;
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
      _isLoadingTrack = true;
      _markLibraryDirty();
      notifyListeners();
      tick('notifyListeners (loading state)');
      // Resolve the actual file to play. The bucket-level fallback
      // tries the requested track first; if its file is missing or
      // the engine refuses it (codec error, corrupt header, etc),
      // walks siblings in playback-preference order until one
      // works. This is how the user expects a song to keep playing
      // even after one of its variants gets deleted in Finder.
      final played = await _tryPlayBucket(track);
      if (played == null) {
        debugPrint(
          '[play] all variants in bucket failed for ${track.path}',
        );
        _currentTrackUid = null;
        _currentTrackPath = null;
        _isLoadingTrack = false;
        notifyListeners();
        return;
      }
      tick('engine.setTrack returned (path=${played.path})');
      _isLoadingTrack = false;
      _currentTrackPath = played.path;
      enrichOnDemand(played.path);
      tick('enrichOnDemand queued');

      final now = DateTime.now();
      await _writeBucketIntelligence(played, (canonical) async {
        await repo.updateIntelligence(
          intelUid: canonical,
          lastPlayedAt: now.millisecondsSinceEpoch,
        );
      });
      tick('updateIntelligence (lastPlayedAt, bucket)');
      _pushNowPlaying();
      tick('_pushNowPlaying');
    }
    await engine.play();
    tick('engine.play() — first audio frame requested');
    if (reveal) {
      _revealTick.value = _revealTick.value + 1;
    }
  }

  Future<void> _flushCurrentTrack() async {
    final t = currentTrack;
    if (t == null) return;
    if (t.intelUid == null) return;
    // The in-memory cumulativeListened / playCount on `t` is the
    // authoritative session state (this is the file the engine is
    // playing). Mirror it onto canonical intel + every bucket
    // sibling so favoriting / reviewing on a different variant
    // after this flush stays coherent.
    await _writeBucketIntelligence(t, (canonical) async {
      await repo.updateIntelligence(
        intelUid: canonical,
        cumulativeMs: t.cumulativeListened.inMilliseconds,
        playCount: t.playCount,
      );
    });
  }

  Future<void> togglePlayPause() async {
    if (_currentTrackUid == null) {
      final list = visibleTracks;
      if (list.isNotEmpty) await play(list.first.uid);
      return;
    }
    if (engine.isPlaying) {
      await engine.pause();
    } else {
      await engine.play();
    }
  }

  Future<void> next() async {
    final list = visibleTracks;
    if (list.isEmpty || _currentTrackUid == null) return;

    if (_playbackMode == PlaybackMode.shuffleUnreviewed) {
      final pool = list
          .where((t) => !t.reviewed && t.uid != _currentTrackUid)
          .toList();
      if (pool.isEmpty) return;
      await play(pool[_rng.nextInt(pool.length)].uid, reveal: true);
      return;
    }

    if (_playbackMode == PlaybackMode.shuffle && list.length > 1) {
      String pickUid;
      do {
        pickUid = list[_rng.nextInt(list.length)].uid;
      } while (pickUid == _currentTrackUid);
      await play(pickUid, reveal: true);
      return;
    }

    final idx = list.indexWhere((t) => t.uid == _currentTrackUid);
    if (idx >= 0 && idx < list.length - 1) {
      await play(list[idx + 1].uid, reveal: true);
    }
  }

  Future<void> previous() async {
    final list = visibleTracks;
    if (list.isEmpty || _currentTrackUid == null) return;
    final idx = list.indexWhere((t) => t.uid == _currentTrackUid);
    if (idx > 0) {
      await play(list[idx - 1].uid, reveal: true);
    }
  }

  Future<void> skip(Duration delta) async {
    final track = currentTrack;
    if (track == null) return;
    var newPos = _positionNotifier.value + delta;
    if (newPos < Duration.zero) newPos = Duration.zero;
    if (track.duration > Duration.zero && newPos > track.duration) {
      newPos = track.duration;
    }
    _positionNotifier.value = newPos;
    _lastTickPosition = newPos;
    await engine.seek(newPos);
  }

  Future<void> seekToFraction(double fraction) async {
    final track = currentTrack;
    if (track == null || track.duration == Duration.zero) return;
    final ms = (track.duration.inMilliseconds * fraction.clamp(0.0, 1.0))
        .round();
    final newPos = Duration(milliseconds: ms);
    _positionNotifier.value = newPos;
    _lastTickPosition = newPos;
    await engine.seek(newPos);
  }

  void _onPosition(Duration pos) {
    final track = currentTrack;
    if (track != null && _isPlaying) {
      final delta = pos - _lastTickPosition;
      if (delta > Duration.zero && delta < const Duration(seconds: 2)) {
        final wasReviewed = track.reviewed;
        track.cumulativeListened = track.cumulativeListened + delta;
        _sessionListened = _sessionListened + delta;

        final crossedReviewed = !wasReviewed && track.reviewed;
        final shouldCountSession =
            !_sessionPlayCounted &&
            _sessionListened >= Duration(seconds: _playThresholdSeconds);

        if (crossedReviewed || shouldCountSession) {
          if (shouldCountSession) {
            _sessionPlayCounted = true;
            track.playCount += 1;
          }
          _pushRecentReviewed(track.uid);
          _markLibraryDirty();
          notifyListeners();
          // Persist through the bucket helper so the play-count
          // increment and cumulative listening propagate to every
          // sibling variant in memory + the canonical intel row.
          // Promotion already happened at play() start, so this
          // call is just a write + mirror.
          final cumulativeMs = track.cumulativeListened.inMilliseconds;
          final playCount = track.playCount;
          unawaited(_writeBucketIntelligence(track, (canonical) async {
            await repo.updateIntelligence(
              intelUid: canonical,
              cumulativeMs: cumulativeMs,
              playCount: playCount,
            );
          }));
        }
      }
    }
    _lastTickPosition = pos;
    _positionNotifier.value = pos;
    final now = DateTime.now();
    if (now.difference(_lastNowPlayingPushAt).inMilliseconds >= 1000) {
      _lastNowPlayingPushAt = now;
      _pushNowPlaying();
    }
  }

  void _onPlaying(bool playing) {
    if (_isPlaying == playing) return;
    _isPlaying = playing;
    if (playing) {
      _flushTimer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => _flushCurrentTrack(),
      );
    } else {
      _flushTimer?.cancel();
      _flushTimer = null;
      _flushCurrentTrack();
    }
    _pushNowPlaying();
    notifyListeners();
  }

  void _onDuration(Duration? d) {
    if (d == null || d == Duration.zero) return;
    final track = currentTrack;
    if (track == null) return;
    if (track.duration != d) {
      track.duration = d;
      _markLibraryDirty();
      notifyListeners();
      // Duration is part of the lightweight index, not intelligence —
      // metadata extractor will eventually persist it via
      // updateMetadataBatch. We don't write to `tracks` from here.
    }
  }

  void _onProcessing(ProcessingState state) {
    if (state == ProcessingState.completed) {
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
      next();
    }
  }

  // ---------------------------------------------------------------------------
  // Intelligence export / import (cross-machine portability).
  // ---------------------------------------------------------------------------

  /// Snapshot intelligence rows to a JSON file.
  ///
  /// If [toPath] is `null`, writes to the default location:
  /// `~/Documents/Music Tracker/intelligence-{yyyyMMdd-HHmm}.json`.
  /// Returns the written file (caller can show the path in a toast).
  Future<File> exportIntelligence({String? toPath}) async {
    final records = await repo.exportIntelligenceRecords();
    final filePath = toPath ??
        '${(await IntelligenceExportFile.defaultExportDirectory()).path}/'
            '${IntelligenceExportFile.defaultFilename()}';
    final file = await IntelligenceExportFile.writeTo(
      filePath: filePath,
      records: records,
    );
    debugPrint(
      '[export] wrote ${records.length} intelligence records to '
      '${file.path}',
    );
    return file;
  }

  /// Read an intelligence file and preview the merge plan WITHOUT
  /// applying it. Used by the import-confirm dialog so the user sees
  /// the breakdown before committing.
  ///
  /// Throws [FormatException] if the file isn't a valid intelligence
  /// export. The returned `records` is what
  /// [applyIntelligenceImport] should be called with on confirm.
  Future<({List<IntelligenceRecord> records, List<String> parseErrors})>
      previewIntelligenceImport(File file) async {
    final errors = <String>[];
    final records = await IntelligenceExportFile.readFrom(file, errors: errors);
    return (records: records, parseErrors: errors);
  }

  /// Apply an already-parsed import. Reloads tracks afterwards so
  /// merged state appears in the UI without restarting the app.
  Future<ImportSummary> applyIntelligenceImport(
    List<IntelligenceRecord> records,
  ) async {
    final summary = await repo.importIntelligenceRecords(records);
    final allTracks = await repo.loadTracks();
    _replaceTracks(allTracks);
    _markLibraryDirty();
    notifyListeners();
    debugPrint(
      '[import] read=${summary.recordsRead} '
      'mergedByUid=${summary.mergedByUid} '
      'mergedByFp=${summary.mergedByFingerprint} '
      'ghost=${summary.insertedAsGhost} '
      'errors=${summary.skippedErrors.length}',
    );
    return summary;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _flushCurrentTrack();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _durationSub?.cancel();
    _processingSub?.cancel();
    _positionNotifier.dispose();
    _revealTick.dispose();
    _backfillWorker.cancel();
    unawaited(_stopAllWatchers());
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver);
      _lifecycleObserverRegistered = false;
    }
    super.dispose();
  }
}

String _displayNameFor(String path) {
  final segs = path.split(Platform.pathSeparator);
  for (var i = segs.length - 1; i >= 0; i--) {
    if (segs[i].isNotEmpty) return segs[i];
  }
  return path;
}

/// Thin shim around `WidgetsBindingObserver` so the controller can
/// listen for app lifecycle changes without itself mixing in
/// WidgetsBindingObserver (which isn't declared as a Dart mixin in
/// the current Flutter SDK). The controller registers an instance of
/// this with `WidgetsBinding.instance.addObserver(...)` and forwards
/// the lifecycle-state callback to a closure.
class _LifecycleObserver extends WidgetsBindingObserver {
  final void Function(AppLifecycleState) onChange;
  _LifecycleObserver(this.onChange);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChange(state);
  }
}

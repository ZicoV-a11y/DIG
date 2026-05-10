import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:uuid/uuid.dart';

import '../models/intelligence_record.dart';
import '../models/source.dart';
import '../models/track.dart';
import '../services/audio_scanner.dart';
import '../services/intelligence_export.dart';
import '../services/library_repository.dart';
import '../services/media_keys.dart';
import '../services/metadata_extractor.dart';
import '../services/playback_engine.dart';
import '../utils/aggregated_track_view.dart';
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
    _positionSub = engine.positionStream.listen(_onPosition);
    _playingSub = engine.playingStream.listen(_onPlaying);
    _durationSub = engine.durationStream.listen(_onDuration);
    _processingSub = engine.processingStateStream.listen(_onProcessing);
    _wireMediaBridge();
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

  /// Library-wide missing tally (`isAvailable == false`).
  int get missingCount {
    _ensureLibraryStats();
    return _missingCountCache ?? 0;
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
    if (_libraryStatsVersion == _libraryVersion) return;
    var enriched = 0;
    var missing = 0;
    // Song-identity bucketing in the same pass. Tracks with empty
    // title/artist (songIdentityKey returns null) can't bucket and
    // each count as a singleton song. Other tracks are deduped by
    // their identity key.
    var singletonSongs = 0;
    var singletonReviewed = 0;
    final reviewedByBucket = <String, bool>{};
    for (final t in _tracks) {
      if (t.metadataReadAt != null) enriched++;
      if (!t.isAvailable) missing++;
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
    var reviewedBucketed = 0;
    for (final v in reviewedByBucket.values) {
      if (v) reviewedBucketed++;
    }
    _enrichedCountCache = enriched;
    _missingCountCache = missing;
    _songCountCache = singletonSongs + reviewedByBucket.length;
    _reviewedSongCountCache = singletonReviewed + reviewedBucketed;
    _libraryStatsVersion = _libraryVersion;
  }
  ValueListenable<Duration> get positionListenable => _positionNotifier;
  ValueListenable<int> get revealTick => _revealTick;

  int get totalTrackCount => _tracks.length;
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
    if (_sourceCountCache == null ||
        _sourceCountCacheVersion != _libraryVersion) {
      _sourceCountCache = _computeAllSourceCounts();
      _sourceCountCacheVersion = _libraryVersion;
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
    final rawBuckets = groupBySongIdentity(_tracks);
    final buckets = [
      for (final b in rawBuckets) orderBucketByPlaybackPreference(b),
    ];
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
          // Sort by the aggregated label so `MP3 · AIFF` buckets sort
          // together rather than being scattered by their primary's
          // single-format string.
          final af = va.formatLabel;
          final bf = vb.formatLabel;
          if (af.isEmpty && bf.isEmpty) return 0;
          if (af.isEmpty) return 1;
          if (bf.isEmpty) return -1;
          return dir * af.compareTo(bf);
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

  void _markLibraryDirty() {
    _libraryVersion++;
    _visibleCache = null;
    // Source-count cache uses the same version key; invalidation
    // happens lazily on the next `sourceTrackCount` call.
  }

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
  Future<void> rescanSource(String sourceId) async {
    final idx = _sources.indexWhere((s) => s.id == sourceId);
    if (idx < 0) return;
    await _scanIntoSource(_sources[idx]);
  }

  Future<void> _scanIntoSource(Source source) async {
    _isScanning = true;
    notifyListeners();
    try {
      final scanStart = Stopwatch()..start();
      // Disk walk + per-file stat now happen inside the scanner
      // isolate; the UI thread stays responsive even on huge cloud
      // libraries.
      final entries = await AudioScanner.scan(
        source.folderPath,
        recursive: source.scanMode == ScanMode.recursive,
      );
      debugPrint(
        '[scan] walked ${entries.length} files in '
        '${scanStart.elapsedMilliseconds}ms',
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

      final upsertStart = Stopwatch()..start();
      final inserted = await repo.upsertIndexedFilesBatch(
        sourceId: source.id,
        files: batch,
      );
      debugPrint(
        '[scan] upsert batch: ${batch.length} files '
        '($inserted new) in ${upsertStart.elapsedMilliseconds}ms',
      );

      await repo.markUnseenAvailability(
        source.id,
        {for (final e in entries) e.path},
      );

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
      notifyListeners();
    }
  }

  /// Remove the source. The FK cascade drops `indexed_files` rows under
  /// it; `tracks` rows are intentionally untouched (guardrail 5 — user
  /// work survives source removal). Re-adding the same folder will
  /// reconnect intelligence by fingerprint.
  Future<void> removeSource(String sourceId) async {
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
    _markLibraryDirty();
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    _invalidateLock();
    _markLibraryDirty();
    notifyListeners();
  }

  void toggleUnreviewedOnly() {
    _unreviewedOnly = !_unreviewedOnly;
    _invalidateLock();
    _markLibraryDirty();
    notifyListeners();
  }

  void toggleShowArtwork() {
    _showArtwork = !_showArtwork;
    notifyListeners();
  }

  void setSort(TrackSortColumn column) {
    if (_sortColumn == column) {
      _sortAscending = !_sortAscending;
    } else {
      _sortColumn = column;
      _sortAscending = true;
    }
    _invalidateLock();
    _markLibraryDirty();
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

  /// Every in-memory Track sharing [t]'s song identity. Returns just
  /// [t] when the track has empty title/artist (no identity to group
  /// on) or when no siblings exist. Linear over `_tracks`; called
  /// only on mutation, so the cost is negligible.
  List<Track> variantsFor(Track t) {
    final key = songIdentityKey(t);
    if (key == null) return [t];
    final out = <Track>[];
    for (final candidate in _tracks) {
      if (songIdentityKey(candidate) == key) out.add(candidate);
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
    if (!track.isAvailable) {
      debugPrint('[play] file unavailable: ${track.path}');
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
      try {
        await engine.setTrack(track.path);
      } catch (e) {
        debugPrint('[play] engine.setTrack failed: $e');
        _currentTrackUid = null;
        _currentTrackPath = null;
        _isLoadingTrack = false;
        notifyListeners();
        return;
      }
      tick('engine.setTrack returned');
      _isLoadingTrack = false;
      _currentTrackPath = track.path;
      enrichOnDemand(track.path);
      tick('enrichOnDemand queued');

      final now = DateTime.now();
      await _writeBucketIntelligence(track, (canonical) async {
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

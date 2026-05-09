import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import '../models/track.dart';
import '../models/watched_folder.dart';
import '../services/audio_scanner.dart';
import '../services/library_repository.dart';
import '../services/metadata_extractor.dart';
import '../services/playback_engine.dart';

enum TrackSortColumn { favorite, reviewed, title, artist, bpm, duration, plays }

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

  static const _recentBufferCapacity = 8;
  static const _trailVisibleCount = 5;
  static const _metadataBatchSize = 100;

  final List<WatchedFolder> _folders = [];
  final List<Track> _tracks = [];
  final List<String> _recentReviewedIds = [];
  final List<String> _metadataQueue = [];
  bool _metadataProcessing = false;

  String? _selectedFolderPath;
  String _searchQuery = '';
  bool _unreviewedOnly = false;
  bool _showArtwork = false;
  bool _isScanning = false;
  TrackSortColumn _sortColumn = TrackSortColumn.title;
  bool _sortAscending = true;

  String? _currentTrackId;
  String? _selectedTrackId;
  PlaybackMode _playbackMode = PlaybackMode.sequential;
  final Random _rng = Random();
  bool _isPlaying = false;
  Duration _lastTickPosition = Duration.zero;
  Duration _sessionListened = Duration.zero;
  bool _sessionPlayCounted = false;
  int _playThresholdSeconds = 10;

  // Utility columns: locked widths, content-fitted (label + glyph + small
  // horizontal padding). Not resizable, not loaded from persistence.
  double _colFavWidth = 32;
  double _colRevWidth = 38;
  double _colBpmWidth = 38;
  double _colTimeWidth = 50;
  double _colPlaysWidth = 52;
  // Text columns: absolute stored widths, persisted. Each has its own
  // right-edge resize handle. Dragging only changes that column's width;
  // neighbours get pushed (and horizontal scroll engages if the row
  // exceeds the viewport).
  double _colTitleWidth = 350;
  double _colArtistWidth = 240;

  // Column order. All seven ids must be present exactly once; user can
  // reorder via long-press-drag on any header cell. Persisted as a
  // comma-separated string in app_settings under `column_order`.
  static const List<String> _defaultColumnOrder = [
    'fav', 'rev', 'title', 'artist', 'bpm', 'time', 'plays',
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
  }

  Future<void> hydrate() async {
    final settings = await repo.loadSettings();
    _playThresholdSeconds =
        int.tryParse(settings['play_threshold_seconds'] ?? '') ?? 10;
    // Utility column widths are locked — defaults always used, never
    // restored from SQLite. TITLE / ARTIST are user-resizable; load
    // their stored absolute widths.
    _colTitleWidth =
        double.tryParse(settings['col_title_width'] ?? '') ?? _colTitleWidth;
    _colArtistWidth =
        double.tryParse(settings['col_artist_width'] ?? '') ?? _colArtistWidth;
    final orderStr = settings['column_order'];
    if (orderStr != null && orderStr.isNotEmpty) {
      final parsed = orderStr.split(',').map((s) => s.trim()).toList();
      // Validate: must contain all seven default ids exactly once.
      if (parsed.length == _defaultColumnOrder.length &&
          parsed.toSet().length == _defaultColumnOrder.length &&
          parsed.toSet().containsAll(_defaultColumnOrder)) {
        _columnOrder = parsed;
      }
    }

    final folders = await repo.loadFolders();
    final tracks = await repo.loadTracks();
    _folders
      ..clear()
      ..addAll(folders);
    _tracks
      ..clear()
      ..addAll(tracks);
    _markLibraryDirty();
    notifyListeners();

    final unread = tracks
        .where((t) => t.metadataReadAt == null)
        .map((t) => t.id)
        .toList();
    debugPrint(
      '[meta] hydrate loaded ${tracks.length} tracks (${unread.length} need metadata)',
    );
    _enqueueMetadata(unread);
  }

  void _enqueueMetadata(Iterable<String> paths) {
    final list = paths.toList(growable: false);
    if (list.isEmpty) {
      debugPrint('[meta] enqueue called with 0 paths — skipping');
      return;
    }
    debugPrint(
      '[meta] enqueue +${list.length} (queue=${_metadataQueue.length + list.length}, processing=$_metadataProcessing)',
    );
    _metadataQueue.addAll(list);
    if (!_metadataProcessing) {
      _processMetadataQueue();
    }
  }

  Future<void> _processMetadataQueue() async {
    if (_metadataProcessing) return;
    _metadataProcessing = true;
    debugPrint('[meta] processor starting (queue=${_metadataQueue.length})');
    try {
      while (_metadataQueue.isNotEmpty) {
        final batch = _metadataQueue
            .take(_metadataBatchSize)
            .toList(growable: false);
        _metadataQueue.removeRange(0, batch.length);

        final stopwatch = Stopwatch()..start();
        debugPrint(
          '[meta] batch start (${batch.length} files, queue remaining=${_metadataQueue.length})',
        );

        List<TrackMetadata> results;
        try {
          results = await MetadataExtractor.extractBatch(batch);
        } catch (e, st) {
          debugPrint('[meta] batch FAILED in isolate: $e');
          debugPrint('$st');
          continue;
        }

        var withTitle = 0;
        var withArtist = 0;
        var withBpm = 0;
        var withDuration = 0;
        var failures = 0;
        for (final m in results) {
          if (!m.readSucceeded) failures++;
          if (m.title != null) withTitle++;
          if (m.artist != null) withArtist++;
          if (m.bpm != null) withBpm++;
          if (m.duration != null && m.duration! > Duration.zero) withDuration++;
          final t = _trackById(m.path);
          if (t == null) continue;
          _applyMetadata(t, m);
        }
        debugPrint(
          '[meta] batch done in ${stopwatch.elapsedMilliseconds}ms: '
          'extracted=${results.length} fail=$failures '
          'titles=$withTitle artists=$withArtist bpm=$withBpm duration=$withDuration',
        );

        try {
          await repo.updateMetadataBatch(results);
          debugPrint('[meta] DB updated for ${results.length} rows');
        } catch (e) {
          debugPrint('[meta] DB update FAILED: $e');
        }

        _markLibraryDirty();
        notifyListeners();
      }
    } finally {
      _metadataProcessing = false;
      debugPrint('[meta] processor idle');
    }
  }

  void _applyMetadata(Track t, TrackMetadata m) {
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
    t.metadataReadAt = DateTime.now();
  }

  List<WatchedFolder> get folders => List.unmodifiable(_folders);
  String? get selectedFolderPath => _selectedFolderPath;
  String get searchQuery => _searchQuery;
  bool get unreviewedOnly => _unreviewedOnly;
  bool get showArtwork => _showArtwork;
  bool get isScanning => _isScanning;
  TrackSortColumn get sortColumn => _sortColumn;
  bool get sortAscending => _sortAscending;

  String? get currentTrackId => _currentTrackId;
  String? get selectedTrackId => _selectedTrackId;
  PlaybackMode get playbackMode => _playbackMode;
  bool get isPlaying => _isPlaying;
  Duration get currentPosition => _positionNotifier.value;
  ValueListenable<Duration> get positionListenable => _positionNotifier;
  ValueListenable<int> get revealTick => _revealTick;

  int get totalTrackCount => _tracks.length;
  int get libraryVersion => _libraryVersion;

  int get playThresholdSeconds => _playThresholdSeconds;
  double get colFavWidth => _colFavWidth;
  double get colRevWidth => _colRevWidth;
  double get colBpmWidth => _colBpmWidth;
  double get colTimeWidth => _colTimeWidth;
  double get colPlaysWidth => _colPlaysWidth;
  double get colTitleWidth => _colTitleWidth;
  double get colArtistWidth => _colArtistWidth;

  /// Read-only view of the current column order. Indexes 0..6 in the
  /// canonical seven-column set.
  List<String> get columnOrder => List.unmodifiable(_columnOrder);

  /// Move [column] so it ends up at [targetIndex] in the order list.
  /// `targetIndex` is the slot index *before any removal* — values up to
  /// `columnOrder.length` mean "drop after the last column". Notifies
  /// once and persists the new order to SQLite (single write).
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

  Future<void> _setPlayThresholdSeconds(int s) async {
    _playThresholdSeconds = s;
    notifyListeners();
    await repo.setSetting('play_threshold_seconds', s.toString());
  }

  /// Update [column]'s stored width. During an active drag the caller
  /// passes `commit: false` per frame so we only update the in-memory
  /// value and notify; SQLite writes are deferred to a single
  /// `commit: true` call on drag end. This keeps drag at 60 fps.
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
      case 'time':
        clamped = width.clamp(40.0, 120.0);
        _colTimeWidth = clamped;
        break;
      case 'plays':
        clamped = width.clamp(36.0, 120.0);
        _colPlaysWidth = clamped;
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

  int folderTrackCount(String folderPath) {
    var count = 0;
    for (final t in _tracks) {
      if (t.folderPath == folderPath) count++;
    }
    return count;
  }

  Track? get currentTrack {
    if (_currentTrackId == null) return null;
    for (final t in _tracks) {
      if (t.id == _currentTrackId) return t;
    }
    return null;
  }

  Track? _trackById(String id) {
    for (final t in _tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  List<Track> get recentReviewedTracks => [
    for (final id in _recentReviewedIds)
      if (_trackById(id) != null) _trackById(id)!,
  ];

  void _pushRecentReviewed(String trackId) {
    _recentReviewedIds.remove(trackId);
    _recentReviewedIds.insert(0, trackId);
    if (_recentReviewedIds.length > _recentBufferCapacity) {
      _recentReviewedIds.removeLast();
    }
  }

  int? trailIndexOf(String trackId) {
    final upper = _recentReviewedIds.length < _trailVisibleCount
        ? _recentReviewedIds.length
        : _trailVisibleCount;
    for (var i = 0; i < upper; i++) {
      if (_recentReviewedIds[i] == trackId) return i;
    }
    return null;
  }

  List<Track> get visibleTracks {
    if (_visibleCache != null && _visibleCacheVersion == _libraryVersion) {
      return _visibleCache!;
    }

    Iterable<Track> list = _tracks;

    if (_selectedFolderPath != null) {
      list = list.where((t) => t.folderPath == _selectedFolderPath);
    }
    if (_unreviewedOnly) {
      final exemptIds = <String>{};
      if (_currentTrackId != null) exemptIds.add(_currentTrackId!);
      final upper = _recentReviewedIds.length < _trailVisibleCount
          ? _recentReviewedIds.length
          : _trailVisibleCount;
      for (var i = 0; i < upper; i++) {
        exemptIds.add(_recentReviewedIds[i]);
      }
      list = list.where((t) => !t.reviewed || exemptIds.contains(t.id));
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where(
        (t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q),
      );
    }

    final result = list.toList();
    final dir = _sortAscending ? 1 : -1;
    result.sort((a, b) {
      switch (_sortColumn) {
        case TrackSortColumn.favorite:
          return dir * ((a.favorite ? 1 : 0) - (b.favorite ? 1 : 0));
        case TrackSortColumn.reviewed:
          return dir * ((a.reviewed ? 1 : 0) - (b.reviewed ? 1 : 0));
        case TrackSortColumn.title:
          return dir *
              a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case TrackSortColumn.artist:
          final aa = a.artist.toLowerCase();
          final ba = b.artist.toLowerCase();
          if (aa.isEmpty && ba.isEmpty) return 0;
          if (aa.isEmpty) return 1;
          if (ba.isEmpty) return -1;
          return dir * aa.compareTo(ba);
        case TrackSortColumn.bpm:
          final ab = a.bpm;
          final bb = b.bpm;
          if (ab == null && bb == null) return 0;
          if (ab == null) return 1;
          if (bb == null) return -1;
          return dir * ab.compareTo(bb);
        case TrackSortColumn.duration:
          return dir * a.duration.compareTo(b.duration);
        case TrackSortColumn.plays:
          return dir * a.playCount.compareTo(b.playCount);
      }
    });

    if (_currentTrackId != null) {
      final naturalIdx = result.indexWhere((t) => t.id == _currentTrackId);
      if (naturalIdx >= 0) {
        if (_lockedCurrentIndex == null) {
          _lockedCurrentIndex = naturalIdx;
        } else if (naturalIdx != _lockedCurrentIndex) {
          final t = result.removeAt(naturalIdx);
          final insertAt = _lockedCurrentIndex!.clamp(0, result.length);
          result.insert(insertAt, t);
        }
      }
    }

    _visibleCache = result;
    _visibleCacheVersion = _libraryVersion;
    return result;
  }

  void _markLibraryDirty() {
    _libraryVersion++;
    _visibleCache = null;
  }

  void _invalidateLock() {
    _lockedCurrentIndex = null;
  }

  Future<void> addWatchedFolder(String path) async {
    if (_folders.any((f) => f.path == path)) return;

    _isScanning = true;
    notifyListeners();
    try {
      final filePaths = await AudioScanner.scan(path);
      final folder = WatchedFolder(
        path: path,
        displayName: _displayNameFor(path),
      );
      await repo.insertFolder(folder);
      _folders.add(folder);

      final existingIds = <String>{for (final t in _tracks) t.id};
      final newTracks = <Track>[];
      for (final filePath in filePaths) {
        if (existingIds.contains(filePath)) continue;
        existingIds.add(filePath);
        final t = Track(
          id: filePath,
          title: filenameWithoutExtension(filePath),
          artist: '',
          folderPath: path,
          duration: Duration.zero,
        );
        newTracks.add(t);
        _tracks.add(t);
      }
      await repo.insertTracksBatch(newTracks);
      _invalidateLock();
      _markLibraryDirty();
      _enqueueMetadata(newTracks.map((t) => t.id));
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> removeWatchedFolder(String path) async {
    await repo.deleteFolder(path);
    _folders.removeWhere((f) => f.path == path);
    _tracks.removeWhere((t) => t.folderPath == path);
    final remainingIds = <String>{for (final t in _tracks) t.id};
    _recentReviewedIds.removeWhere((id) => !remainingIds.contains(id));
    if (_selectedFolderPath == path) _selectedFolderPath = null;
    if (_currentTrackId != null &&
        !_tracks.any((t) => t.id == _currentTrackId)) {
      await engine.stop();
      _currentTrackId = null;
      _isPlaying = false;
      _positionNotifier.value = Duration.zero;
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
    }
    _invalidateLock();
    _markLibraryDirty();
    notifyListeners();
  }

  void selectFolder(String? path) {
    _selectedFolderPath = path;
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

  void toggleFavorite(String trackId) {
    final t = _tracks.firstWhere((t) => t.id == trackId);
    t.favorite = !t.favorite;
    _markLibraryDirty();
    notifyListeners();
    repo.updateTrackState(t);
  }

  void toggleReviewed(String trackId) {
    final t = _tracks.firstWhere((t) => t.id == trackId);
    if (t.reviewed) {
      t.cumulativeListened = Duration.zero;
    } else {
      t.cumulativeListened = const Duration(seconds: 3);
      _pushRecentReviewed(trackId);
    }
    _markLibraryDirty();
    notifyListeners();
    repo.updateTrackState(t);
  }

  void cyclePlaybackMode() {
    final values = PlaybackMode.values;
    _playbackMode = values[(_playbackMode.index + 1) % values.length];
    notifyListeners();
  }

  void selectTrack(String? trackId) {
    if (_selectedTrackId == trackId) return;
    _selectedTrackId = trackId;
    notifyListeners();
  }

  void selectNextVisible() {
    final list = visibleTracks;
    if (list.isEmpty) return;
    final cursor = _selectedTrackId ?? _currentTrackId;
    if (cursor == null) {
      _selectedTrackId = list.first.id;
    } else {
      final idx = list.indexWhere((t) => t.id == cursor);
      if (idx < 0) {
        _selectedTrackId = list.first.id;
      } else if (idx < list.length - 1) {
        _selectedTrackId = list[idx + 1].id;
      } else {
        _selectedTrackId = list.last.id;
      }
    }
    notifyListeners();
  }

  void selectPreviousVisible() {
    final list = visibleTracks;
    if (list.isEmpty) return;
    final cursor = _selectedTrackId ?? _currentTrackId;
    if (cursor == null) {
      _selectedTrackId = list.first.id;
    } else {
      final idx = list.indexWhere((t) => t.id == cursor);
      if (idx <= 0) {
        _selectedTrackId = list.first.id;
      } else {
        _selectedTrackId = list[idx - 1].id;
      }
    }
    notifyListeners();
  }

  Future<void> playSelected() async {
    final id = _selectedTrackId;
    if (id == null) return;
    await play(id, reveal: true);
  }

  void revealCurrent() {
    if (_currentTrackId == null) return;
    if (_selectedTrackId != _currentTrackId) {
      _selectedTrackId = _currentTrackId;
      notifyListeners();
    }
    _revealTick.value = _revealTick.value + 1;
  }

  Future<void> showTrackInFinder(String trackId) async {
    if (!Platform.isMacOS) return;
    try {
      await Process.run('open', ['-R', trackId]);
    } catch (_) {
      // file may have moved or sandbox restricted; best-effort
    }
  }

  Future<void> goBack() async {
    if (_recentReviewedIds.isNotEmpty &&
        _recentReviewedIds[0] != _currentTrackId) {
      await play(_recentReviewedIds[0], reveal: true);
    } else {
      await previous();
    }
  }

  Future<void> play(String trackId, {bool reveal = false}) async {
    final track = _tracks.firstWhere(
      (t) => t.id == trackId,
      orElse: () => throw StateError('Track not found: $trackId'),
    );
    final isNewTrack = _currentTrackId != trackId;
    if (isNewTrack) {
      await _flushCurrentTrack();
      final visible = visibleTracks;
      final displayedIdx = visible.indexWhere((t) => t.id == trackId);
      _currentTrackId = trackId;
      _selectedTrackId = trackId;
      _lockedCurrentIndex = displayedIdx >= 0 ? displayedIdx : null;
      _positionNotifier.value = Duration.zero;
      _lastTickPosition = Duration.zero;
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
      _markLibraryDirty();
      notifyListeners();
      try {
        await engine.setTrack(track.id);
      } catch (e) {
        _currentTrackId = null;
        notifyListeners();
        return;
      }
      repo.markPlayed(trackId);
    }
    await engine.play();
    if (reveal) {
      _revealTick.value = _revealTick.value + 1;
    }
  }

  Future<void> _flushCurrentTrack() async {
    final t = currentTrack;
    if (t != null) await repo.updateTrackState(t);
  }

  Future<void> togglePlayPause() async {
    if (_currentTrackId == null) {
      final list = visibleTracks;
      if (list.isNotEmpty) await play(list.first.id);
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
    if (list.isEmpty || _currentTrackId == null) return;

    if (_playbackMode == PlaybackMode.shuffleUnreviewed) {
      final pool = list
          .where((t) => !t.reviewed && t.id != _currentTrackId)
          .toList();
      if (pool.isEmpty) return;
      await play(pool[_rng.nextInt(pool.length)].id, reveal: true);
      return;
    }

    if (_playbackMode == PlaybackMode.shuffle && list.length > 1) {
      String pickId;
      do {
        pickId = list[_rng.nextInt(list.length)].id;
      } while (pickId == _currentTrackId);
      await play(pickId, reveal: true);
      return;
    }

    final idx = list.indexWhere((t) => t.id == _currentTrackId);
    if (idx >= 0 && idx < list.length - 1) {
      await play(list[idx + 1].id, reveal: true);
    }
  }

  Future<void> previous() async {
    final list = visibleTracks;
    if (list.isEmpty || _currentTrackId == null) return;
    final idx = list.indexWhere((t) => t.id == _currentTrackId);
    if (idx > 0) {
      await play(list[idx - 1].id, reveal: true);
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
          _pushRecentReviewed(track.id);
          _markLibraryDirty();
          notifyListeners();
          repo.updateTrackState(track);
        }
      }
    }
    _lastTickPosition = pos;
    _positionNotifier.value = pos;
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
      repo.updateTrackState(track);
    }
  }

  void _onProcessing(ProcessingState state) {
    if (state == ProcessingState.completed) {
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
      next();
    }
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

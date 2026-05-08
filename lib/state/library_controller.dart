import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import '../models/track.dart';
import '../models/watched_folder.dart';
import '../services/audio_scanner.dart';
import '../services/playback_engine.dart';

enum TrackSortColumn { favorite, reviewed, title, duration, plays }

class LibraryController extends ChangeNotifier {
  final PlaybackEngine engine;

  final List<WatchedFolder> _folders = [];
  final List<Track> _tracks = [];

  String? _selectedFolderPath;
  String _searchQuery = '';
  bool _unreviewedOnly = false;
  bool _showArtwork = false;
  bool _isScanning = false;
  TrackSortColumn _sortColumn = TrackSortColumn.title;
  bool _sortAscending = true;

  String? _currentTrackId;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _lastTickPosition = Duration.zero;

  int _libraryVersion = 0;
  List<Track>? _visibleCache;
  int _visibleCacheVersion = -1;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<ProcessingState>? _processingSub;

  LibraryController({required this.engine}) {
    _positionSub = engine.positionStream.listen(_onPosition);
    _playingSub = engine.playingStream.listen(_onPlaying);
    _durationSub = engine.durationStream.listen(_onDuration);
    _processingSub = engine.processingStateStream.listen(_onProcessing);
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
  bool get isPlaying => _isPlaying;
  Duration get currentPosition => _currentPosition;

  int get totalTrackCount => _tracks.length;
  int get libraryVersion => _libraryVersion;

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

  List<Track> get visibleTracks {
    if (_visibleCache != null && _visibleCacheVersion == _libraryVersion) {
      return _visibleCache!;
    }

    Iterable<Track> list = _tracks;

    if (_selectedFolderPath != null) {
      list = list.where((t) => t.folderPath == _selectedFolderPath);
    }
    if (_unreviewedOnly) {
      list = list.where((t) => !t.reviewed);
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
        case TrackSortColumn.duration:
          return dir * a.duration.compareTo(b.duration);
        case TrackSortColumn.plays:
          return dir * a.playCount.compareTo(b.playCount);
      }
    });

    _visibleCache = result;
    _visibleCacheVersion = _libraryVersion;
    return result;
  }

  void _markLibraryDirty() {
    _libraryVersion++;
    _visibleCache = null;
  }

  Future<void> addWatchedFolder(String path) async {
    if (_folders.any((f) => f.path == path)) return;

    _isScanning = true;
    notifyListeners();
    try {
      final filePaths = await AudioScanner.scan(path);
      _folders.add(
        WatchedFolder(path: path, displayName: _displayNameFor(path)),
      );

      final existingIds = <String>{for (final t in _tracks) t.id};
      for (final filePath in filePaths) {
        if (existingIds.contains(filePath)) continue;
        existingIds.add(filePath);
        _tracks.add(
          Track(
            id: filePath,
            title: filenameWithoutExtension(filePath),
            artist: '',
            folderPath: path,
            duration: Duration.zero,
          ),
        );
      }
      _markLibraryDirty();
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> removeWatchedFolder(String path) async {
    _folders.removeWhere((f) => f.path == path);
    _tracks.removeWhere((t) => t.folderPath == path);
    if (_selectedFolderPath == path) _selectedFolderPath = null;
    if (_currentTrackId != null &&
        !_tracks.any((t) => t.id == _currentTrackId)) {
      await engine.stop();
      _currentTrackId = null;
      _isPlaying = false;
      _currentPosition = Duration.zero;
    }
    _markLibraryDirty();
    notifyListeners();
  }

  void selectFolder(String? path) {
    _selectedFolderPath = path;
    _markLibraryDirty();
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    _markLibraryDirty();
    notifyListeners();
  }

  void toggleUnreviewedOnly() {
    _unreviewedOnly = !_unreviewedOnly;
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
    _markLibraryDirty();
    notifyListeners();
  }

  void toggleFavorite(String trackId) {
    final t = _tracks.firstWhere((t) => t.id == trackId);
    t.favorite = !t.favorite;
    _markLibraryDirty();
    notifyListeners();
  }

  Future<void> play(String trackId) async {
    final track = _tracks.firstWhere(
      (t) => t.id == trackId,
      orElse: () => throw StateError('Track not found: $trackId'),
    );
    final isNewTrack = _currentTrackId != trackId;
    if (isNewTrack) {
      _currentTrackId = trackId;
      _currentPosition = Duration.zero;
      _lastTickPosition = Duration.zero;
      notifyListeners();
      try {
        await engine.setTrack(track.id);
      } catch (e) {
        _currentTrackId = null;
        notifyListeners();
        return;
      }
    }
    await engine.play();
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
    final idx = list.indexWhere((t) => t.id == _currentTrackId);
    if (idx >= 0 && idx < list.length - 1) {
      await play(list[idx + 1].id);
    }
  }

  Future<void> previous() async {
    final list = visibleTracks;
    if (list.isEmpty || _currentTrackId == null) return;
    final idx = list.indexWhere((t) => t.id == _currentTrackId);
    if (idx > 0) {
      await play(list[idx - 1].id);
    }
  }

  Future<void> skip(Duration delta) async {
    final track = currentTrack;
    if (track == null) return;
    var newPos = _currentPosition + delta;
    if (newPos < Duration.zero) newPos = Duration.zero;
    if (track.duration > Duration.zero && newPos > track.duration) {
      newPos = track.duration;
    }
    _currentPosition = newPos;
    _lastTickPosition = newPos;
    notifyListeners();
    await engine.seek(newPos);
  }

  Future<void> seekToFraction(double fraction) async {
    final track = currentTrack;
    if (track == null || track.duration == Duration.zero) return;
    final ms = (track.duration.inMilliseconds * fraction.clamp(0.0, 1.0))
        .round();
    final newPos = Duration(milliseconds: ms);
    _currentPosition = newPos;
    _lastTickPosition = newPos;
    notifyListeners();
    await engine.seek(newPos);
  }

  void _onPosition(Duration pos) {
    final track = currentTrack;
    if (track != null && _isPlaying) {
      final delta = pos - _lastTickPosition;
      if (delta > Duration.zero && delta < const Duration(seconds: 2)) {
        final wasReviewed = track.reviewed;
        track.cumulativeListened = track.cumulativeListened + delta;
        if (!wasReviewed && track.reviewed) {
          track.playCount += 1;
          _markLibraryDirty();
        }
      }
    }
    _lastTickPosition = pos;
    _currentPosition = pos;
    notifyListeners();
  }

  void _onPlaying(bool playing) {
    if (_isPlaying == playing) return;
    _isPlaying = playing;
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
    }
  }

  void _onProcessing(ProcessingState state) {
    if (state == ProcessingState.completed) {
      next();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    _durationSub?.cancel();
    _processingSub?.cancel();
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

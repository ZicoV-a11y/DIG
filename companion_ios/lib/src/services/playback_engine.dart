import 'dart:async';

/// Abstract audio playback surface. Production wires a
/// `just_audio` implementation; tests + the chaos simulator
/// use the in-memory [FakePlaybackEngine] so playback state
/// can be driven deterministically without sound output.
///
/// PR2.8.C contract: the engine is an EXECUTOR. It plays the
/// path it's told to play, reports position + state, and does
/// nothing more. All track resolution — `intel_uid` →
/// generation → file path — happens in [AudioService] BEFORE
/// the engine is touched. The engine knows nothing about
/// inventory, manifests, generations, or sync.
abstract class PlaybackEngine {
  /// Load a local audio file. `null` clears any source.
  Future<void> setSource(String? filePath);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Current monotonically-increasing playback position. Emits
  /// at audio-frame cadence in real implementations; the fake
  /// emits on demand.
  Stream<Duration> get positionStream;

  /// `true` when audio is actively playing, `false` when
  /// paused / stopped / no source loaded.
  Stream<bool> get playingStream;

  /// Synchronous snapshots so AudioService can build its own
  /// snapshot record without subscribing.
  Duration get currentPosition;
  bool get isPlaying;

  Future<void> dispose();
}

/// In-memory fake for tests + simulator. Behaves like a real
/// engine for the methods AudioService calls, but never spins
/// the audio hardware up.
class FakePlaybackEngine implements PlaybackEngine {
  String? _currentSource;
  Duration _position = Duration.zero;
  bool _playing = false;

  final StreamController<Duration> _positionCtl =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingCtl =
      StreamController<bool>.broadcast();

  String? get currentSource => _currentSource;

  /// Test helper — manually advance the simulated position. The
  /// real engine emits these naturally as audio plays; tests
  /// drive them explicitly.
  void advancePosition(Duration delta) {
    _position += delta;
    _positionCtl.add(_position);
  }

  @override
  Future<void> setSource(String? filePath) async {
    _currentSource = filePath;
    _position = Duration.zero;
    _playing = false;
    _positionCtl.add(_position);
    _playingCtl.add(_playing);
  }

  @override
  Future<void> play() async {
    if (_currentSource == null) return;
    _playing = true;
    _playingCtl.add(_playing);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _playingCtl.add(_playing);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _position = Duration.zero;
    _currentSource = null;
    _playingCtl.add(_playing);
    _positionCtl.add(_position);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _positionCtl.add(_position);
  }

  @override
  Stream<Duration> get positionStream => _positionCtl.stream;
  @override
  Stream<bool> get playingStream => _playingCtl.stream;

  @override
  Duration get currentPosition => _position;
  @override
  bool get isPlaying => _playing;

  @override
  Future<void> dispose() async {
    await _positionCtl.close();
    await _playingCtl.close();
  }
}

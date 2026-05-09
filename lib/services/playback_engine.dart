import 'package:just_audio/just_audio.dart';

class PlaybackEngine {
  final AudioPlayer _player = AudioPlayer();

  String? _currentPath;

  late final Stream<Duration> _positionStream = _player.createPositionStream(
    minPeriod: const Duration(milliseconds: 16),
    maxPeriod: const Duration(milliseconds: 16),
  );

  String? get currentPath => _currentPath;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  Stream<Duration> get positionStream => _positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  Stream<ProcessingState> get processingStateStream =>
      _player.processingStateStream;

  Future<void> setTrack(String filePath) async {
    if (_currentPath == filePath) return;
    _currentPath = filePath;
    await _player.setFilePath(filePath);
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);

  double get volume => _player.volume;
  Future<void> setVolume(double v) =>
      _player.setVolume(v.clamp(0.0, 1.0).toDouble());

  Future<void> dispose() => _player.dispose();
}

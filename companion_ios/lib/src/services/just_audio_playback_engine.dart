import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'operational_log.dart';
import 'playback_engine.dart';

/// `just_audio` execution adapter — **EXECUTOR ONLY**.
///
/// Per the PR2.8.D non-negotiable: this class implements
/// [PlaybackEngine] and nothing more. It does NOT know about
/// inventory, manifests, generations, sync, queues, or
/// playback semantics. Those live in [AudioService]; this
/// class plays the path it's told to and reports state back
/// via streams.
///
/// iOS lifecycle wiring:
///   - Configures [AudioSession] with the `music()` preset
///     (AVAudioSessionCategoryPlayback) so background audio +
///     route changes + Now Playing surface work.
///   - Listens to `interruptionEventStream` and pauses the
///     player when the OS hands an interruption begin event
///     (incoming call, Siri, alarm).
///   - Listens to `becomingNoisyEventStream` and pauses when
///     headphones disconnect (the courteous behavior — don't
///     blast a phone speaker because Bluetooth dropped).
///
/// What this class does NOT do:
///   - Auto-resume after interruption end. That's an
///     [AudioService] semantic decision (it knows whether the
///     user expected playback to continue). The engine just
///     reports its state via [playingStream].
///   - Persist any state. Snapshot is owned by [AudioService].
class JustAudioPlaybackEngine implements PlaybackEngine {
  JustAudioPlaybackEngine({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  bool _sessionConfigured = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;

  /// One-shot session config. Deferred to first use so plain-
  /// Dart tests that construct the engine never hit the
  /// platform channel. Returns immediately on subsequent calls.
  Future<void> _ensureSession() async {
    if (_sessionConfigured) return;
    _sessionConfigured = true;
    OperationalLog.emit('engine', 'configuring AudioSession.music()');
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _interruptionSub =
        session.interruptionEventStream.listen((event) {
      OperationalLog.emit('engine',
          'interruption ${event.begin ? "begin" : "end"} '
          'type=${event.type}');
      if (event.begin) {
        unawaited(_player.pause());
      }
      // No auto-resume on end — AudioService decides whether
      // resuming makes sense given current sync / inventory
      // state.
    });
    _noisySub = session.becomingNoisyEventStream.listen((_) {
      OperationalLog.emit('engine',
          'becoming noisy (headphones disconnected) — pause');
      unawaited(_player.pause());
    });
  }

  @override
  Future<void> setSource(String? filePath) async {
    await _ensureSession();
    OperationalLog.emit('engine', 'setSource ${filePath ?? "<null>"}');
    if (filePath == null) {
      await _player.stop();
    } else {
      await _player.setFilePath(filePath);
    }
  }

  @override
  Future<void> play() async {
    await _ensureSession();
    OperationalLog.emit('engine', 'play');
    await _player.play();
  }

  @override
  Future<void> pause() async {
    OperationalLog.emit('engine', 'pause');
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    OperationalLog.emit('engine', 'stop');
    await _player.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    OperationalLog.emit('engine', 'seek ${position.inMilliseconds}ms');
    await _player.seek(position);
  }

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Duration get currentPosition => _player.position;

  @override
  bool get isPlaying => _player.playing;

  @override
  Future<void> dispose() async {
    OperationalLog.emit('engine', 'dispose');
    await _interruptionSub?.cancel();
    await _noisySub?.cancel();
    await _player.dispose();
  }
}

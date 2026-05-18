import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Synthesizes deterministic sine-wave WAV files for PR2.8.D.2
/// real-device testing without committing binary audio assets.
///
/// Two presets are exposed via [presets] (440Hz "A4" + 880Hz
/// "A5"); the dev panel uses them to stage two distinguishable
/// generations so retirement-survival is audibly observable on
/// device:
///
///   - load gen with preset A → engine plays 440Hz tone
///   - tap "load gen B" while playing → 440Hz keeps playing
///     (retirement-survival), engine source unchanged
///   - stop, play first again → engine resolves against the now-
///     active gen B, plays 880Hz
///
/// The synthesizer is deliberately tiny — mono 16-bit PCM WAV,
/// no fades, no envelope. Just enough to prove the runtime
/// stack moves real audio bytes through AVFoundation.
class DevSampleAudio {
  DevSampleAudio._();

  /// Two preset tones — distinguishable by ear, identifiable
  /// in the operational log via [label].
  static const List<TonePreset> presets = [
    TonePreset(label: 'A4-440Hz', frequencyHz: 440),
    TonePreset(label: 'A5-880Hz', frequencyHz: 880),
  ];

  /// Writes a sine-wave WAV file at [path]. Caller is
  /// responsible for the parent directory existing. Overwrites
  /// any existing file.
  ///
  /// Default duration is 30 seconds — long enough to test
  /// pause / seek / interruption / lock-screen behavior, short
  /// enough that the on-device file footprint stays trivial
  /// (~2.6MB at 44.1kHz mono 16-bit).
  static Future<void> writeSineWav({
    required String path,
    required double frequencyHz,
    Duration duration = const Duration(seconds: 30),
    int sampleRate = 44100,
  }) async {
    final totalSamples =
        (sampleRate * duration.inMilliseconds / 1000).round();
    final dataBytes = totalSamples * 2; // mono, 16-bit
    final fileSize = 36 + dataBytes;
    final buffer = ByteData(44 + dataBytes);

    // RIFF header
    _writeAscii(buffer, 0, 'RIFF');
    buffer.setUint32(4, fileSize, Endian.little);
    _writeAscii(buffer, 8, 'WAVE');
    // fmt subchunk
    _writeAscii(buffer, 12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);          // chunk size
    buffer.setUint16(20, 1, Endian.little);           // PCM
    buffer.setUint16(22, 1, Endian.little);           // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    buffer.setUint16(32, 2, Endian.little);           // block align
    buffer.setUint16(34, 16, Endian.little);          // bits per sample
    // data subchunk
    _writeAscii(buffer, 36, 'data');
    buffer.setUint32(40, dataBytes, Endian.little);

    const amplitude = 0.3; // -10dBFS — comfortable on phone speaker
    final twoPiF = 2 * math.pi * frequencyHz;
    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final sample = (math.sin(twoPiF * t) * 32767 * amplitude).round();
      buffer.setInt16(44 + i * 2, sample, Endian.little);
    }

    await File(path).writeAsBytes(buffer.buffer.asUint8List());
  }

  static void _writeAscii(ByteData b, int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(offset + i, s.codeUnitAt(i));
    }
  }
}

class TonePreset {
  const TonePreset({required this.label, required this.frequencyHz});

  final String label;
  final double frequencyHz;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/utils/file_format.dart';

void main() {
  group('fileFormatLabel', () {
    test('uppercases known audio extensions', () {
      expect(fileFormatLabel('track.mp3'), 'MP3');
      expect(fileFormatLabel('track.wav'), 'WAV');
      expect(fileFormatLabel('track.flac'), 'FLAC');
      expect(fileFormatLabel('track.aiff'), 'AIFF');
      expect(fileFormatLabel('track.m4a'), 'M4A');
      expect(fileFormatLabel('track.ogg'), 'OGG');
    });

    test('normalises .aif to AIFF', () {
      // Same container, DJ libraries use them interchangeably; we
      // don't want two separate "formats" for the same encode.
      expect(fileFormatLabel('master.aif'), 'AIFF');
      expect(fileFormatLabel('master.AIF'), 'AIFF');
    });

    test('case-insensitive on the extension', () {
      expect(fileFormatLabel('track.MP3'), 'MP3');
      expect(fileFormatLabel('track.Mp3'), 'MP3');
    });

    test('uses the last dot only', () {
      expect(fileFormatLabel('track.tar.aiff'), 'AIFF');
      expect(fileFormatLabel('mix.set.flac'), 'FLAC');
    });

    test('returns empty for no extension', () {
      expect(fileFormatLabel('noext'), '');
      expect(fileFormatLabel('track.'), ''); // trailing dot
    });

    test('returns empty for dotfile basenames', () {
      // Leading dot only — treat as a hidden file, not an extension.
      expect(fileFormatLabel('.hidden'), '');
      expect(fileFormatLabel('.DS_Store'), '');
    });

    test('returns empty for empty input', () {
      expect(fileFormatLabel(''), '');
    });
  });
}

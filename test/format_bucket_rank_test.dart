import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/track.dart';
import 'package:music_tracker/utils/aggregated_track_view.dart';

/// The user reported that under the **single MP3 lead**, buckets
/// labelled `MP3 · AIFF` get scattered among pure-`MP3` buckets
/// instead of clustering after them. The rank function is what
/// drives that — if these tests pass and the user still sees
/// scattering, the bug is not in the rank but in how the live
/// controller wires it (caching, stale view, hot-reload not
/// picking up the controller change, etc.).
Track _t(String filename) {
  return Track(
    uid: 'uid-$filename',
    fingerprint: 'fp-$filename',
    path: '/lib/$filename',
    filename: filename,
    sourceId: 'src',
    title: filename,
    artist: 'a',
    duration: const Duration(minutes: 4),
    musicalKey: '',
  );
}

AggregatedTrackView _view(List<String> filenames) =>
    AggregatedTrackView([for (final f in filenames) _t(f)]);

void main() {
  group('computeFormatBucketRank — single lead [MP3]', () {
    test('pure MP3 bucket → tier 0', () {
      expect(
        computeFormatBucketRank(_view(['x.mp3']), const ['MP3']),
        0,
      );
    });

    test('MP3 ×2 bucket (two MP3 variants, same format set) → tier 0', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3', 'y.mp3']),
          const ['MP3'],
        ),
        0,
      );
    });

    test('MP3 + AIFF bucket → tier 1 (contains, not exact)', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3', 'x.aiff']),
          const ['MP3'],
        ),
        1,
      );
    });

    test('MP3 + WAV + AIFF bucket → tier 1', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3', 'x.wav', 'x.aiff']),
          const ['MP3'],
        ),
        1,
      );
    });

    test('AIFF only → tier 2 (lacks)', () {
      expect(
        computeFormatBucketRank(_view(['x.aiff']), const ['MP3']),
        2,
      );
    });
  });

  group('computeFormatBucketRank — pair lead [MP3, WAV]', () {
    test('exact pair {MP3, WAV} → tier 0', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3', 'x.wav']),
          const ['MP3', 'WAV'],
        ),
        0,
      );
    });

    test('pair + extras {MP3, WAV, AIFF} → tier 0 (family clusters)', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3', 'x.wav', 'x.aiff']),
          const ['MP3', 'WAV'],
        ),
        0,
      );
    });

    test('only MP3 → tier 1 (one of pair)', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3']),
          const ['MP3', 'WAV'],
        ),
        1,
      );
    });

    test('MP3 + AIFF (one of pair, has extras) → tier 1', () {
      expect(
        computeFormatBucketRank(
          _view(['x.mp3', 'x.aiff']),
          const ['MP3', 'WAV'],
        ),
        1,
      );
    });

    test('FLAC + AIFF (neither of pair) → tier 2', () {
      expect(
        computeFormatBucketRank(
          _view(['x.flac', 'x.aiff']),
          const ['MP3', 'WAV'],
        ),
        2,
      );
    });
  });

  group('computeFormatBucketRank — empty / unknown', () {
    test('bucket with no recognised formats → tier 2', () {
      expect(
        computeFormatBucketRank(_view(['x.weird']), const ['MP3']),
        2,
      );
    });
  });
}

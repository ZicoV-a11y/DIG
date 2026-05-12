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
Track _t(String filename, {String? title}) {
  return Track(
    uid: 'uid-$filename',
    fingerprint: 'fp-$filename',
    path: '/lib/$filename',
    filename: filename,
    sourceId: 'src',
    title: title ?? filename,
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

  /// Under single-MP3 lead, tier-1 rows (any bucket containing MP3
  /// plus extras) must form adjacent blocks by exact combo
  /// signature — NOT interleave by title alone. The user-visible
  /// goal: scrolling shows all `MP3 · AIFF` rows together, then
  /// all `MP3 · FLAC`, then all `MP3 · WAV`, etc., with title
  /// ordering only inside each block.
  group('compareFormatBuckets — combo block clustering', () {
    test('same-combo rows cluster, different combos separate', () {
      const lead = ['MP3'];
      // Two MP3·AIFF buckets (titles B / D), two MP3·WAV buckets
      // (titles A / E), one pure MP3 bucket (title C). Shuffled
      // input order — the sort must regroup them into:
      //   tier 0: pure MP3 (C)
      //   tier 1 / MP3·AIFF block: B, D
      //   tier 1 / MP3·WAV block:  A, E
      final views = <AggregatedTrackView>[
        AggregatedTrackView([_t('a.mp3', title: 'A'), _t('a.wav', title: 'A')]),
        AggregatedTrackView([_t('b.mp3', title: 'B'), _t('b.aiff', title: 'B')]),
        AggregatedTrackView([_t('c.mp3', title: 'C')]),
        AggregatedTrackView([_t('d.mp3', title: 'D'), _t('d.aiff', title: 'D')]),
        AggregatedTrackView([_t('e.mp3', title: 'E'), _t('e.wav', title: 'E')]),
      ];
      views.sort((a, b) => compareFormatBuckets(a, b, lead));
      expect(
        views.map((v) => '${v.formatLabel}/${v.primary.displayTitle}').toList(),
        [
          'MP3/C',          // tier 0
          'MP3 · AIFF/B',   // tier 1, AIFF block first (alphabetical)
          'MP3 · AIFF/D',
          'MP3 · WAV/A',    // tier 1, WAV block next
          'MP3 · WAV/E',
        ],
      );
    });

    test('3-format combo lands in its own block, after 2-format combos', () {
      const lead = ['MP3'];
      final views = <AggregatedTrackView>[
        AggregatedTrackView([
          _t('a.mp3', title: 'A'),
          _t('a.wav', title: 'A'),
          _t('a.aiff', title: 'A'),
        ]),
        AggregatedTrackView([_t('b.mp3', title: 'B'), _t('b.wav', title: 'B')]),
      ];
      views.sort((a, b) => compareFormatBuckets(a, b, lead));
      expect(
        views.map((v) => v.formatLabel).toList(),
        ['MP3 · WAV', 'MP3 · WAV · AIFF'],
        reason:
            'MP3 · WAV sorts before MP3 · WAV · AIFF — same prefix, '
            'shorter combo first by lexicographic order on formatLabel',
      );
    });

    test('tier 2 (no lead) rows sink below all tier-1 blocks', () {
      const lead = ['MP3'];
      final views = <AggregatedTrackView>[
        AggregatedTrackView([_t('a.flac', title: 'A')]),
        AggregatedTrackView([_t('b.mp3', title: 'B'), _t('b.aiff', title: 'B')]),
      ];
      views.sort((a, b) => compareFormatBuckets(a, b, lead));
      expect(
        views.map((v) => v.formatLabel).toList(),
        ['MP3 · AIFF', 'FLAC'],
      );
    });
  });
}

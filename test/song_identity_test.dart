import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/track.dart';
import 'package:music_tracker/utils/song_identity.dart';

Track _t({
  required String filename,
  required String title,
  required String artist,
  Duration duration = const Duration(minutes: 4),
  String? uid,
  String? path,
}) {
  return Track(
    uid: uid ?? 'uid-$filename',
    fingerprint: 'fp-$filename',
    path: path ?? '/library/$filename',
    filename: filename,
    sourceId: 'src1',
    title: title,
    artist: artist,
    duration: duration,
  );
}

void main() {
  group('sameSongIdentity', () {
    test('MP3 vs AIFF variants of the same song match', () {
      final mp3 = _t(
        filename: 'Afro Warriors - Uyankenteza.mp3',
        title: 'Uyankenteza (Hyenah Remix Vocal)',
        artist: 'Afro Warriors',
        duration: const Duration(seconds: 482),
      );
      final aiff = _t(
        filename: 'Afro Warriors - Uyankenteza.aiff',
        title: 'Uyankenteza (Hyenah Remix Vocal)',
        artist: 'Afro Warriors',
        duration: const Duration(seconds: 482),
      );
      expect(sameSongIdentity(mp3, aiff), isTrue);
    });

    test('identical tracks return true via early-exit path', () {
      final t = _t(filename: 'a.mp3', title: 'A', artist: 'X');
      expect(sameSongIdentity(t, t), isTrue);
    });

    test('different basename does not match', () {
      final a = _t(filename: 'one.mp3', title: 'Same', artist: 'Same');
      final b = _t(filename: 'two.mp3', title: 'Same', artist: 'Same');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('different title does not match', () {
      final a = _t(filename: 'x.mp3', title: 'One', artist: 'Artist');
      final b = _t(filename: 'x.aiff', title: 'Two', artist: 'Artist');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('different artist does not match', () {
      final a = _t(filename: 'x.mp3', title: 'Track', artist: 'A');
      final b = _t(filename: 'x.aiff', title: 'Track', artist: 'B');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('duration mismatch by 1ms does not match (exact)', () {
      // Strict millisecond-exact equality. The user explicitly chose
      // tightness over codec-rounding tolerance — false-positive
      // merges silently hide files, false-negatives just leave a
      // bucket split until a manual-link UI ships.
      final a = _t(
        filename: 'x.mp3',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482000),
      );
      final b = _t(
        filename: 'x.aiff',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482001),
      );
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('exact millisecond match still pairs across formats', () {
      // When both decoders happen to report the same length (or the
      // tagger normalized them), the rule still pairs.
      final mp3 = _t(
        filename: 'x.mp3',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482000),
      );
      final aiff = _t(
        filename: 'x.aiff',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482000),
      );
      expect(sameSongIdentity(mp3, aiff), isTrue);
    });

    test('case-sensitive title — does not match across case differences', () {
      final a = _t(filename: 'x.mp3', title: 'Foo', artist: 'A');
      final b = _t(filename: 'x.aiff', title: 'foo', artist: 'A');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('case-sensitive artist', () {
      final a = _t(filename: 'x.mp3', title: 'T', artist: 'Bar');
      final b = _t(filename: 'x.aiff', title: 'T', artist: 'bar');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('case-sensitive filename', () {
      final a = _t(filename: 'Track.mp3', title: 'T', artist: 'A');
      final b = _t(filename: 'track.aiff', title: 'T', artist: 'A');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('leading-whitespace difference in title does not match (no trim)', () {
      final a = _t(filename: 'x.mp3', title: 'T', artist: 'A');
      final b = _t(filename: 'x.aiff', title: ' T', artist: 'A');
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('empty title on either side prevents any match', () {
      final empty = _t(filename: 'x.mp3', title: '', artist: 'A');
      final filled = _t(filename: 'x.aiff', title: 'T', artist: 'A');
      expect(sameSongIdentity(empty, filled), isFalse);
      // Two empty-title tracks also don't match — without metadata
      // there's no song identity to assert.
      final empty2 = _t(filename: 'x.aiff', title: '', artist: 'A');
      expect(sameSongIdentity(empty, empty2), isFalse);
    });

    test('empty artist on either side prevents any match', () {
      final empty = _t(filename: 'x.mp3', title: 'T', artist: '');
      final filled = _t(filename: 'x.aiff', title: 'T', artist: 'A');
      expect(sameSongIdentity(empty, filled), isFalse);
    });

    test('different filesize / uid / path do not block a match', () {
      // The 4-field rule is metadata-only; physical file divergence
      // is the whole reason variants exist.
      final a = Track(
        uid: 'uid-a',
        fingerprint: 'fp-a',
        path: '/library/house/track.mp3',
        filename: 'track.mp3',
        sourceId: 'src1',
        title: 'T',
        artist: 'A',
        filesize: 5 * 1024 * 1024,
        duration: const Duration(seconds: 300),
      );
      final b = Track(
        uid: 'uid-b',
        fingerprint: 'fp-b',
        path: '/library/zcrate/track.aiff',
        filename: 'track.aiff',
        sourceId: 'src1',
        title: 'T',
        artist: 'A',
        filesize: 80 * 1024 * 1024,
        duration: const Duration(seconds: 300),
      );
      expect(sameSongIdentity(a, b), isTrue);
    });

    test('extension stripping uses LAST dot only', () {
      // `track.tar.mp3` and `track.tar.aiff` should both strip to
      // `track.tar` and therefore match (contrived for audio but the
      // invariant matters for correctness).
      final a = _t(filename: 'track.tar.mp3', title: 'T', artist: 'A');
      final b = _t(filename: 'track.tar.aiff', title: 'T', artist: 'A');
      expect(sameSongIdentity(a, b), isTrue);
    });

    test('extensionless filenames match each other if title/artist/duration agree', () {
      final a = _t(filename: 'noext', title: 'T', artist: 'A');
      final b = _t(filename: 'noext', title: 'T', artist: 'A');
      expect(sameSongIdentity(a, b), isTrue);
    });

    test('hidden-file basename (dotfile) does not get treated as extension', () {
      // `.hidden` → no extension stripped; both compare as `.hidden`.
      final a = _t(filename: '.hidden', title: 'T', artist: 'A');
      final b = _t(filename: '.hidden', title: 'T', artist: 'A');
      expect(sameSongIdentity(a, b), isTrue);
    });
  });

  group('groupBySongIdentity', () {
    test('empty input → empty output', () {
      expect(groupBySongIdentity(const <Track>[]), isEmpty);
    });

    test('single track returns one singleton bucket', () {
      final t = _t(filename: 'a.mp3', title: 'T', artist: 'A');
      final result = groupBySongIdentity([t]);
      expect(result, hasLength(1));
      expect(result.first, [t]);
    });

    test('two matching variants collapse into one bucket', () {
      final mp3 = _t(filename: 'track.mp3', title: 'T', artist: 'A');
      final aiff = _t(filename: 'track.aiff', title: 'T', artist: 'A');
      final result = groupBySongIdentity([mp3, aiff]);
      expect(result, hasLength(1));
      expect(result.first, [mp3, aiff]);
    });

    test('non-matching tracks stay in separate buckets', () {
      final a = _t(filename: 'a.mp3', title: 'A', artist: 'X');
      final b = _t(filename: 'b.mp3', title: 'B', artist: 'X');
      final result = groupBySongIdentity([a, b]);
      expect(result, hasLength(2));
      expect(result[0], [a]);
      expect(result[1], [b]);
    });

    test('bucket order matches first occurrence in input', () {
      final a1 = _t(filename: 'a.mp3', title: 'A', artist: 'X');
      final b1 = _t(filename: 'b.mp3', title: 'B', artist: 'X');
      final a2 = _t(filename: 'a.aiff', title: 'A', artist: 'X');
      final result = groupBySongIdentity([a1, b1, a2]);
      expect(result, hasLength(2));
      expect(result[0], [a1, a2]); // 'A' bucket appears before 'B'
      expect(result[1], [b1]);
    });

    test('order within a bucket preserves input order', () {
      final first = _t(
        filename: 't.mp3',
        title: 'T',
        artist: 'A',
        uid: 'first',
      );
      final second = _t(
        filename: 't.aiff',
        title: 'T',
        artist: 'A',
        uid: 'second',
      );
      final third = _t(
        filename: 't.flac',
        title: 'T',
        artist: 'A',
        uid: 'third',
      );
      final result = groupBySongIdentity([second, first, third]);
      expect(result, hasLength(1));
      expect(result.first.map((t) => t.uid), ['second', 'first', 'third']);
    });

    test('tracks with empty title/artist each get their own bucket', () {
      final tagged = _t(filename: 'x.mp3', title: 'T', artist: 'A');
      final untagged1 = _t(filename: 'y.mp3', title: '', artist: '');
      final untagged2 = _t(filename: 'y.aiff', title: '', artist: '');
      final result = groupBySongIdentity([tagged, untagged1, untagged2]);
      // Three buckets — the two untagged tracks must NOT collapse,
      // even though they share basename + duration. Without metadata
      // there's no song identity to assert.
      expect(result, hasLength(3));
      expect(result[0], [tagged]);
      expect(result[1], [untagged1]);
      expect(result[2], [untagged2]);
    });

    test('mixed scenario — realistic library slice', () {
      final afroMp3 = _t(
        filename: 'Afro Warriors - Uyankenteza.mp3',
        title: 'Uyankenteza',
        artist: 'Afro Warriors',
        duration: const Duration(seconds: 482),
      );
      final afroAiff = _t(
        filename: 'Afro Warriors - Uyankenteza.aiff',
        title: 'Uyankenteza',
        artist: 'Afro Warriors',
        duration: const Duration(seconds: 482),
      );
      final acnA = _t(
        filename: 'A.C.N. - Warriors.mp3',
        title: 'Warriors (Original Mix)',
        artist: 'A.C.N.',
        duration: const Duration(seconds: 413),
      );
      final acnB = _t(
        filename: 'A.C.N. - Warriors.aiff',
        title: 'Warriors (Original Mix)',
        artist: 'A.C.N.',
        duration: const Duration(seconds: 413),
      );
      final unrelated = _t(
        filename: 'unrelated.mp3',
        title: 'Different',
        artist: 'Different',
        duration: const Duration(seconds: 200),
      );
      final result =
          groupBySongIdentity([afroMp3, acnA, afroAiff, unrelated, acnB]);
      expect(result, hasLength(3));
      expect(result[0], [afroMp3, afroAiff]);
      expect(result[1], [acnA, acnB]);
      expect(result[2], [unrelated]);
    });
  });
}

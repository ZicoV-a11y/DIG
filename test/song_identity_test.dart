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
  String? identityOverride,
  String? fingerprint,
}) {
  return Track(
    uid: uid ?? 'uid-$filename',
    fingerprint: fingerprint ?? 'fp-$filename',
    identityOverride: identityOverride,
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

    test('sub-second duration deltas still match (codec rounding)', () {
      // MP3 vs AIFF decoders report durations that differ by tens or
      // hundreds of ms for the same master because MP3 frame counts
      // and PCM sample counts don't align cleanly. The rule uses
      // truncated-to-seconds equality so these collapse.
      final mp3 = _t(
        filename: 'x.mp3',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482234),
      );
      final aiff = _t(
        filename: 'x.aiff',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482890),
      );
      expect(sameSongIdentity(mp3, aiff), isTrue);
    });

    test('whole-second duration delta does NOT match', () {
      // Radio-edit / extended-mix pairs differ by many seconds and
      // still correctly fail the rule.
      final a = _t(
        filename: 'x.mp3',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 482999),
      );
      final b = _t(
        filename: 'x.aiff',
        title: 'T',
        artist: 'A',
        duration: const Duration(milliseconds: 483001),
      );
      expect(sameSongIdentity(a, b), isFalse);
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

  group('fingerprint fallback', () {
    test('same fingerprint pairs even when ID3 tags differ', () {
      // Two MP3 files with the same filename and audio length but
      // different ID3 metadata (different tagger / edited tags).
      // The 4-field rule would fail (title or artist differs); the
      // fingerprint fallback catches it.
      final a = _t(
        filename: 'song.mp3',
        title: 'Original Title',
        artist: 'Original Artist',
        fingerprint: 'shared-fp',
      );
      final b = _t(
        filename: 'song.mp3',
        title: 'Edited Title',
        artist: 'Edited Artist',
        fingerprint: 'shared-fp',
      );
      expect(sameSongIdentity(a, b), isTrue);
    });

    test('same fingerprint pairs even with empty tags', () {
      final a = _t(
        filename: 'song.mp3',
        title: '',
        artist: '',
        fingerprint: 'shared-fp',
      );
      final b = _t(
        filename: 'song.mp3',
        title: 'Tagged',
        artist: 'Artist',
        fingerprint: 'shared-fp',
      );
      expect(sameSongIdentity(a, b), isTrue);
    });

    test('different fingerprints + different tags do not match', () {
      final a = _t(
        filename: 'one.mp3',
        title: 'A',
        artist: 'X',
        fingerprint: 'fp-a',
      );
      final b = _t(
        filename: 'two.mp3',
        title: 'B',
        artist: 'Y',
        fingerprint: 'fp-b',
      );
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('manual override outranks fingerprint match', () {
      // Two byte-identical files (same fingerprint) but the user
      // explicitly set different overrides. Override wins —
      // they stay distinct.
      final a = _t(
        filename: 'song.mp3',
        title: 'Song',
        artist: 'Artist',
        fingerprint: 'shared-fp',
        identityOverride: 'group-x',
      );
      final b = _t(
        filename: 'song.mp3',
        title: 'Song',
        artist: 'Artist',
        fingerprint: 'shared-fp',
        identityOverride: 'group-y',
      );
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('groupBySongIdentity merges via fingerprint', () {
      // The user's reported scenario: two MP3s appear identical on
      // the row (same filename, same display BPM/key/time) but
      // have drifted ID3 metadata. They should bucket together.
      final a = _t(
        filename: 'Apparel Wax - 008A1.mp3',
        title: '008A1 (Original Mix)',
        artist: 'Apparel Wax',
        fingerprint: 'shared',
      );
      final b = _t(
        filename: 'Apparel Wax - 008A1.mp3',
        title: '008A1 (Original Mix) ', // trailing space — tag drift
        artist: 'Apparel Wax',
        fingerprint: 'shared',
      );
      final result = groupBySongIdentity([a, b]);
      expect(result, hasLength(1));
      expect(result.first, [a, b]);
    });

    test('empty fingerprint falls back to 4-field only', () {
      // Defensive — a row that hasn't been hashed yet shouldn't
      // collide with all other empty-fingerprint rows.
      final a = _t(
        filename: 'a.mp3',
        title: 'A',
        artist: 'X',
        fingerprint: '',
      );
      final b = _t(
        filename: 'b.mp3',
        title: 'B',
        artist: 'Y',
        fingerprint: '',
      );
      expect(sameSongIdentity(a, b), isFalse);
    });
  });

  group('identityOverride (manual link)', () {
    test('two tracks with the same override match regardless of fields', () {
      // Otherwise these would never match — different basenames,
      // titles, artists, and durations.
      final a = _t(
        filename: 'a.mp3',
        title: 'Different Title',
        artist: 'Different Artist',
        duration: const Duration(seconds: 100),
        identityOverride: 'manual-uuid',
      );
      final b = _t(
        filename: 'b.aiff',
        title: 'Other Title',
        artist: 'Other Artist',
        duration: const Duration(seconds: 200),
        identityOverride: 'manual-uuid',
      );
      expect(sameSongIdentity(a, b), isTrue);
    });

    test('different overrides do not match (even with matching fields)', () {
      // Two tracks that the auto-matcher would pair, each with a
      // DIFFERENT manual override, stay distinct. The override is
      // also an "explicit isolation" signal — same key = together,
      // different keys = apart.
      final a = _t(
        filename: 'song.mp3',
        title: 'Song',
        artist: 'Artist',
        identityOverride: 'group-x',
      );
      final b = _t(
        filename: 'song.aiff',
        title: 'Song',
        artist: 'Artist',
        identityOverride: 'group-y',
      );
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('one override + one no-override do not match', () {
      // Asymmetric: a track that opted into a manual bucket
      // doesn't accidentally also match an unrelated track that
      // happens to share the auto-matcher fields.
      final a = _t(
        filename: 'song.mp3',
        title: 'Song',
        artist: 'Artist',
        identityOverride: 'group-x',
      );
      final b = _t(
        filename: 'song.aiff',
        title: 'Song',
        artist: 'Artist',
      );
      expect(sameSongIdentity(a, b), isFalse);
    });

    test('groupBySongIdentity collapses overridden tracks together', () {
      final a = _t(
        filename: 'one.mp3',
        title: 'A',
        artist: 'X',
        identityOverride: 'shared',
      );
      final b = _t(
        filename: 'two.aiff',
        title: 'B',
        artist: 'Y',
        identityOverride: 'shared',
      );
      final c = _t(filename: 'three.mp3', title: 'C', artist: 'Z');
      final result = groupBySongIdentity([a, b, c]);
      expect(result, hasLength(2));
      expect(result[0], [a, b]);
      expect(result[1], [c]);
    });

    test('empty-string override is treated as no override', () {
      // Defensive — a writer might store '' instead of null.
      final a = _t(
        filename: 'song.mp3',
        title: 'Song',
        artist: 'Artist',
        identityOverride: '',
      );
      final b = _t(
        filename: 'song.aiff',
        title: 'Song',
        artist: 'Artist',
      );
      // Both fall back to computed identity, which DOES match.
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

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/track.dart';
import 'package:music_tracker/utils/aggregated_track_view.dart';

Track _t({
  required String filename,
  String title = 'Title',
  String artist = 'Artist',
  Duration duration = const Duration(minutes: 4),
  String musicalKey = '',
  double? bpm,
  int playCount = 0,
  Duration cumulativeListened = Duration.zero,
  bool favorite = false,
  DateTime? lastPlayedAt,
  DateTime? metadataReadAt,
  String? uid,
  String? identityOverride,
  String? fingerprint,
}) {
  return Track(
    uid: uid ?? 'uid-$filename',
    fingerprint: fingerprint ?? 'fp-$filename',
    identityOverride: identityOverride,
    path: '/lib/$filename',
    filename: filename,
    sourceId: 'src',
    title: title,
    artist: artist,
    duration: duration,
    musicalKey: musicalKey,
    bpm: bpm,
    playCount: playCount,
    cumulativeListened: cumulativeListened,
    favorite: favorite,
    lastPlayedAt: lastPlayedAt,
    metadataReadAt: metadataReadAt,
  );
}

void main() {
  group('AggregatedTrackView — singleton bucket', () {
    test('mirrors the single variant for every field', () {
      final track = _t(
        filename: 'a.mp3',
        bpm: 124,
        musicalKey: 'Dm',
        playCount: 3,
        favorite: true,
        cumulativeListened: const Duration(seconds: 90),
      );
      final v = AggregatedTrackView([track]);

      expect(v.primary, same(track));
      expect(v.hasSiblings, isFalse);
      expect(v.variantCount, 1);
      expect(v.playCount, 3);
      expect(v.cumulativeListened, const Duration(seconds: 90));
      expect(v.reviewed, isTrue);
      expect(v.favorite, isTrue);
      expect(v.bpm, 124);
      expect(v.displayKey, '7A'); // Dm → 7A
      expect(v.formatLabel, 'MP3');
    });
  });

  group('AggregatedTrackView — aggregation across variants', () {
    test('playCount sums across variants', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', playCount: 2),
        _t(filename: 'x.aiff', playCount: 5),
      ]);
      expect(v.playCount, 7);
    });

    test('cumulativeListened sums across variants', () {
      final v = AggregatedTrackView([
        _t(
          filename: 'x.mp3',
          cumulativeListened: const Duration(seconds: 30),
        ),
        _t(
          filename: 'x.aiff',
          cumulativeListened: const Duration(seconds: 90),
        ),
      ]);
      expect(v.cumulativeListened, const Duration(seconds: 120));
    });

    test('favorite is OR across variants', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', favorite: false),
        _t(filename: 'x.aiff', favorite: true),
      ]);
      expect(v.favorite, isTrue);

      final none = AggregatedTrackView([
        _t(filename: 'x.mp3', favorite: false),
        _t(filename: 'x.aiff', favorite: false),
      ]);
      expect(none.favorite, isFalse);
    });

    test('reviewed derives from summed cumulativeListened', () {
      // Each variant alone is under threshold (3s); together they're
      // over → bucket counts as reviewed.
      final v = AggregatedTrackView([
        _t(
          filename: 'x.mp3',
          cumulativeListened: const Duration(seconds: 2),
        ),
        _t(
          filename: 'x.aiff',
          cumulativeListened: const Duration(seconds: 2),
        ),
      ]);
      expect(v.reviewed, isTrue);
    });

    test('lastPlayedAt picks most recent across variants', () {
      final early = DateTime(2026, 5, 1);
      final late_ = DateTime(2026, 5, 9);
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', lastPlayedAt: late_),
        _t(filename: 'x.aiff', lastPlayedAt: early),
      ]);
      expect(v.lastPlayedAt, late_);
    });

    test('lastPlayedAt returns null when no variant has played', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3'),
        _t(filename: 'x.aiff'),
      ]);
      expect(v.lastPlayedAt, isNull);
    });
  });

  group('AggregatedTrackView — last-change-wins (BPM)', () {
    test('agreement passes the value through', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', bpm: 125),
        _t(filename: 'x.aiff', bpm: 125),
      ]);
      expect(v.bpm, 125);
    });

    test('one variant present + one blank → present value passes', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', bpm: 125),
        _t(filename: 'x.aiff', bpm: null),
      ]);
      expect(v.bpm, 125);
    });

    test(
        'disagreement → freshest-enriched variant wins (last-change-wins)',
        () {
      // User refinement (2026-05-11): BPM no longer blanks on
      // disagreement. Whichever variant was most recently
      // re-enriched supplies the value. Lets the user "fix" a
      // bucket's BPM by editing one variant's tag and trusting
      // the bucket to converge on the new value.
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 6, 1);
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', bpm: 125, metadataReadAt: older),
        _t(filename: 'x.aiff', bpm: 124, metadataReadAt: newer),
      ]);
      expect(v.bpm, 124,
          reason:
              'freshest metadata_read_at (newer) supplies the BPM');
    });

    test(
        'freshest variant has blank BPM → fallback to another variant with a value',
        () {
      // If the most-recently-enriched variant happens to have
      // no BPM tag, fall back to a variant that does — better
      // to show a value than `—` when the data exists somewhere
      // in the bucket.
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 6, 1);
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', bpm: 125, metadataReadAt: older),
        _t(filename: 'x.aiff', bpm: null, metadataReadAt: newer),
      ]);
      expect(v.bpm, 125);
    });

    test('all blank → null', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', bpm: null),
        _t(filename: 'x.aiff', bpm: null),
      ]);
      expect(v.bpm, isNull);
    });

    test('zero / negative BPMs are treated as blank', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', bpm: 0),
        _t(filename: 'x.aiff', bpm: 124),
      ]);
      expect(v.bpm, 124);
    });
  });

  group('AggregatedTrackView — last-change-wins (key)', () {
    test('agreement on Camelot value', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', musicalKey: 'Dm'), // 7A
        _t(filename: 'x.aiff', musicalKey: '7A'), // 7A
      ]);
      expect(v.displayKey, '7A');
    });

    test('one variant has key, other blank → present value passes', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', musicalKey: 'Dm'),
        _t(filename: 'x.aiff', musicalKey: ''),
      ]);
      expect(v.displayKey, '7A');
    });

    test('disagreement → freshest-enriched variant supplies the key',
        () {
      // The A.C.N. — Warriors case from earlier: one variant
      // tagged 1B, another tagged 10A. Old behaviour blanked
      // the cell; new behaviour picks the most-recently-enriched
      // variant's value so the user's deliberate fix on one
      // side propagates to the row display.
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 6, 1);
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', musicalKey: '1B', metadataReadAt: older),
        _t(filename: 'x.aiff', musicalKey: '10A', metadataReadAt: newer),
      ]);
      expect(v.displayKey, '10A');
    });

    test('unparseable keys are treated as blank', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', musicalKey: 'xyz'),
        _t(filename: 'x.aiff', musicalKey: 'Dm'),
      ]);
      expect(v.displayKey, '7A');
    });
  });

  group('AggregatedTrackView — divergence flags (title / artist)', () {
    test('titleDivergent: identical titles → false', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', title: 'Song'),
        _t(filename: 'x.aiff', title: 'Song'),
      ]);
      expect(v.titleDivergent, isFalse);
      expect(v.artistDivergent, isFalse);
    });

    test('titleDivergent: differing titles → true', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', title: 'Song'),
        _t(filename: 'x.aiff', title: 'Song test'),
      ]);
      expect(v.titleDivergent, isTrue);
    });

    test('artistDivergent: differing artists → true', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', artist: 'Artist A'),
        _t(filename: 'x.aiff', artist: 'Artist A & B'),
      ]);
      expect(v.artistDivergent, isTrue);
    });

    test(
        'titleDivergent: one variant has empty title → not counted (only one real value)',
        () {
      // The empty-string check guards against treating a blank
      // (un-enriched) variant as a divergence partner.
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3', title: 'Song'),
        _t(filename: 'x.aiff', title: ''),
      ]);
      expect(v.titleDivergent, isFalse);
    });

    test(
        'operationalMetadataSource: returns variant with freshest metadata_read_at',
        () {
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 6, 1);
      final a = _t(filename: 'x.mp3', metadataReadAt: older);
      final b = _t(filename: 'x.aiff', metadataReadAt: newer);
      final v = AggregatedTrackView([a, b]);
      expect(v.operationalMetadataSource.path, b.path);
    });

    test('operationalMetadataSource: no variant enriched → falls back to primary',
        () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3'),
        _t(filename: 'x.aiff'),
      ]);
      expect(v.operationalMetadataSource.path, v.primary.path);
    });
  });

  group('AggregatedTrackView — FORMAT label', () {
    test('single variant returns single format', () {
      final v = AggregatedTrackView([_t(filename: 'x.mp3')]);
      expect(v.formatLabel, 'MP3');
    });

    test('two variants joined by middle-dot', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3'),
        _t(filename: 'x.aiff'),
      ]);
      expect(v.formatLabel, 'MP3 · AIFF');
    });

    test('formats appear in lowest-quality-first order', () {
      // Even if AIFF is added first, MP3 sorts before AIFF.
      final v = AggregatedTrackView([
        _t(filename: 'x.aiff'),
        _t(filename: 'x.mp3'),
      ]);
      expect(v.formatLabel, 'MP3 · AIFF');
    });

    test('duplicates of the same format show a count suffix', () {
      // Two MP3 copies (e.g., macOS Cmd+D " copy" duplicate) show
      // `MP3 ×2` so the user sees there's more than one file under
      // the bucket without the FORMAT cell hiding the fact.
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3'),
        _t(filename: 'y.mp3'),
      ]);
      expect(v.formatLabel, 'MP3 ×2');
    });

    test('mixed multi-format + multi-variant', () {
      // Two MP3s and one AIFF → `MP3 ×2 · AIFF`. The single-
      // occurrence format omits the count.
      final v = AggregatedTrackView([
        _t(filename: 'a.mp3'),
        _t(filename: 'a copy.mp3'),
        _t(filename: 'a.aiff'),
      ]);
      expect(v.formatLabel, 'MP3 ×2 · AIFF');
    });

    test('counts appear in preference order', () {
      final v = AggregatedTrackView([
        _t(filename: 'a.aiff'),
        _t(filename: 'b.aiff'),
        _t(filename: 'a.mp3'),
      ]);
      expect(v.formatLabel, 'MP3 · AIFF ×2');
    });

    test('unknown extensions go last, alphabetised', () {
      final v = AggregatedTrackView([
        _t(filename: 'x.mp3'),
        _t(filename: 'x.zzz'),
        _t(filename: 'x.aiff'),
        _t(filename: 'x.qqq'),
      ]);
      expect(v.formatLabel, 'MP3 · AIFF · QQQ · ZZZ');
    });

    test('empty when no variant has an extension', () {
      final v = AggregatedTrackView([
        _t(filename: 'noext'),
        _t(filename: '.hidden'),
      ]);
      expect(v.formatLabel, '');
    });
  });

  group('matchReason — bucket classification', () {
    test('singleton bucket → exactMatch (trivially)', () {
      final v = AggregatedTrackView([_t(filename: 'a.mp3')]);
      expect(v.matchReason, BucketMatchReason.exactMatch);
    });

    test('all fields agree, same format → exactMatch', () {
      // macOS Cmd+D copies — both MP3 in same folder.
      final v = AggregatedTrackView([
        _t(filename: 'song.mp3', title: 'T', artist: 'A'),
        _t(filename: 'song copy.mp3', title: 'T', artist: 'A'),
      ]);
      expect(v.matchReason, BucketMatchReason.exactMatch);
    });

    test('all fields agree but multiple formats → crossFormat', () {
      // MP3 + AIFF of the same song — intentional alternates the
      // user is encouraged to verify.
      final v = AggregatedTrackView([
        _t(
          filename: 'song.mp3',
          title: 'T',
          artist: 'A',
          duration: const Duration(seconds: 300),
        ),
        _t(
          filename: 'song.aiff',
          title: 'T',
          artist: 'A',
          duration: const Duration(seconds: 300),
        ),
      ]);
      expect(v.matchReason, BucketMatchReason.crossFormat);
    });

    test('three formats with matching tags → crossFormat', () {
      final v = AggregatedTrackView([
        _t(filename: 'song.mp3', title: 'T', artist: 'A'),
        _t(filename: 'song.aiff', title: 'T', artist: 'A'),
        _t(filename: 'song.wav', title: 'T', artist: 'A'),
      ]);
      expect(v.matchReason, BucketMatchReason.crossFormat);
    });

    test('extensionless variant doesn\'t falsely trigger crossFormat',
        () {
      // A `noext` file has an empty format label; pair it with an
      // MP3 having matching tags. Empty formats are ignored when
      // counting distinct formats, so this stays exactMatch.
      final v = AggregatedTrackView([
        _t(filename: 'song.mp3', title: 'T', artist: 'A'),
        _t(filename: 'song', title: 'T', artist: 'A'),
      ]);
      expect(v.matchReason, BucketMatchReason.exactMatch);
    });

    test('macOS " copy" suffix still classifies as exactMatch', () {
      final v = AggregatedTrackView([
        _t(filename: 'song.mp3', title: 'T', artist: 'A'),
        _t(filename: 'song copy.mp3', title: 'T', artist: 'A'),
      ]);
      expect(v.matchReason, BucketMatchReason.exactMatch);
    });

    test('different titles → fingerprintWithTagDrift', () {
      final v = AggregatedTrackView([
        _t(filename: 'song.mp3', title: 'Title A', artist: 'X'),
        _t(filename: 'song.mp3', title: 'Title B', artist: 'X'),
      ]);
      expect(v.matchReason, BucketMatchReason.fingerprintWithTagDrift);
    });

    test('different artists → fingerprintWithTagDrift', () {
      final v = AggregatedTrackView([
        _t(filename: 'song.mp3', title: 'T', artist: 'A1'),
        _t(filename: 'song.mp3', title: 'T', artist: 'A2'),
      ]);
      expect(v.matchReason, BucketMatchReason.fingerprintWithTagDrift);
    });

    test('different durations (whole seconds) → fingerprintWithTagDrift',
        () {
      final v = AggregatedTrackView([
        _t(
          filename: 'song.mp3',
          title: 'T',
          artist: 'A',
          duration: const Duration(seconds: 300),
        ),
        _t(
          filename: 'song.mp3',
          title: 'T',
          artist: 'A',
          duration: const Duration(seconds: 305),
        ),
      ]);
      expect(v.matchReason, BucketMatchReason.fingerprintWithTagDrift);
    });

    test('two variants sharing an override (not exact) → manualLink', () {
      final v = AggregatedTrackView([
        _t(
          filename: 'one.mp3',
          title: 'Track A',
          artist: 'Artist X',
          identityOverride: 'shared',
        ),
        _t(
          filename: 'two.aiff',
          title: 'Track B',
          artist: 'Artist Y',
          identityOverride: 'shared',
        ),
      ]);
      expect(v.matchReason, BucketMatchReason.manualLink);
    });

    test('override on cross-format pair → crossFormat (override redundant)',
        () {
      // User manually linked an MP3 + AIFF pair the auto-matcher
      // would have paired anyway via the 4-field rule. Cross-format
      // classification still applies.
      final v = AggregatedTrackView([
        _t(
          filename: 'song.mp3',
          title: 'T',
          artist: 'A',
          identityOverride: 'redundant',
        ),
        _t(
          filename: 'song.aiff',
          title: 'T',
          artist: 'A',
          identityOverride: 'redundant',
        ),
      ]);
      expect(v.matchReason, BucketMatchReason.crossFormat);
    });

    test('only one variant has override → not enough to manualLink', () {
      // Asymmetric override means the auto-matcher must have paired
      // them another way (fingerprint). Classify by that.
      final v = AggregatedTrackView([
        _t(
          filename: 'one.mp3',
          title: 'Track A',
          artist: 'X',
          identityOverride: 'group-x',
        ),
        _t(
          filename: 'two.mp3',
          title: 'Track B',
          artist: 'Y',
        ),
      ]);
      expect(v.matchReason, BucketMatchReason.fingerprintWithTagDrift);
    });
  });

  group('orderBucketByPlaybackPreference', () {
    test('single track returns a one-element list', () {
      final t = _t(filename: 'a.mp3');
      expect(orderBucketByPlaybackPreference([t]), [t]);
    });

    test('lowest-quality format comes first', () {
      final mp3 = _t(filename: 'x.mp3', uid: 'mp3');
      final aiff = _t(filename: 'x.aiff', uid: 'aiff');
      final flac = _t(filename: 'x.flac', uid: 'flac');
      final wav = _t(filename: 'x.wav', uid: 'wav');
      final ordered = orderBucketByPlaybackPreference([aiff, wav, flac, mp3]);
      expect(ordered.map((t) => t.uid), ['mp3', 'flac', 'wav', 'aiff']);
    });

    test('does not mutate the input list', () {
      final mp3 = _t(filename: 'x.mp3', uid: 'mp3');
      final aiff = _t(filename: 'x.aiff', uid: 'aiff');
      final input = [aiff, mp3];
      orderBucketByPlaybackPreference(input);
      expect(input.map((t) => t.uid), ['aiff', 'mp3']);
    });

    test('ties broken by insertion order', () {
      final mp3a = _t(filename: 'a.mp3', uid: 'a');
      final mp3b = _t(filename: 'b.mp3', uid: 'b');
      final ordered = orderBucketByPlaybackPreference([mp3b, mp3a]);
      expect(ordered.map((t) => t.uid), ['b', 'a']);
    });

    test('unknown formats sort last', () {
      final mp3 = _t(filename: 'x.mp3', uid: 'mp3');
      final zzz = _t(filename: 'x.zzz', uid: 'zzz');
      final ordered = orderBucketByPlaybackPreference([zzz, mp3]);
      expect(ordered.map((t) => t.uid), ['mp3', 'zzz']);
    });
  });
}

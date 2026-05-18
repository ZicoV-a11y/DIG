// ManifestBuilder dry-run contract tests.
//
// The builder is the heart of the companion architecture — it
// answers "what should go onto the phone?" Per the seven
// principles documented in the plan, it's a PURE FUNCTION:
// same inputs → same manifest. These tests assert exact output
// (not just "approximately reasonable") so any regression to
// the selection logic is loud, not silent.
//
// Pipeline (from the plan):
//   1. Build eligible pool (hard filters → exclusion reasons)
//   2. Apply preservation rules (continuity)
//   3. Apply pin queue (FIFO pinned consume budget first)
//   4. Apply inventory policy (recipe — Slice 1: unreviewed-random)
//   5. Apply capacity budgeting (trim to fit)
//   6. Emit manifest + diff + exclusions
//
// Each test pins one branch of the pipeline and asserts:
//   - which intel_uids made it into the manifest
//   - the exclusion reason for every track that didn't
//   - the diff numbers
// so the diagnostic surface stays trustworthy.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/track.dart';
import 'package:music_tracker/services/mobile_sync/manifest_builder.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:shared_core/shared_core.dart';

void main() {
  group('ManifestBuilder — stage 1: eligible pool / hard filters', () {
    test('excludes reviewed tracks with reason=reviewed', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', reviewed: true),
        _mp3(uid: 'b', intelUid: 'B'), // eligible
      ];
      final result = _build(tracks: tracks);
      expect(result.manifest.entries.map((e) => e.identity.intelUid),
          ['B']);
      expect(
        result.exclusionsByIntelUid,
        equals({'A': ExclusionReason.reviewed}),
      );
    });

    test('excludes unavailable / missing / superseded with reason', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', availability: 'missing'),
        _mp3(uid: 'b', intelUid: 'B', availability: 'superseded'),
        _mp3(uid: 'c', intelUid: 'C'), // available, eligible
      ];
      final result = _build(tracks: tracks);
      expect(result.manifest.entries, hasLength(1));
      expect(result.exclusionsByIntelUid['A'], ExclusionReason.unavailable);
      expect(result.exclusionsByIntelUid['B'], ExclusionReason.unavailable);
    });

    test('excludes rows with null intel_uid', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: null), // can't reconcile
        _mp3(uid: 'b', intelUid: 'B'),
      ];
      final result = _build(tracks: tracks);
      expect(result.manifest.entries.map((e) => e.identity.intelUid),
          ['B']);
      // Excluded record keys by the track uid since intelUid is null.
      final excludedByUid = {
        for (final e in result.exclusions) e.intelUid: e.reason,
      };
      expect(excludedByUid['a'], ExclusionReason.noIntelUid);
    });

    test('excludes rows with null content_hash', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', contentHash: null),
        _mp3(uid: 'b', intelUid: 'B'),
      ];
      final result = _build(tracks: tracks);
      expect(result.manifest.entries.map((e) => e.identity.intelUid),
          ['B']);
      expect(result.exclusionsByIntelUid['A'],
          ExclusionReason.noContentHash);
    });

    test('excludes non-MP3 formats in Slice 1', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A'),
        _track(
          uid: 'b',
          intelUid: 'B',
          filename: 'song.aiff',
        ),
        _track(
          uid: 'c',
          intelUid: 'C',
          filename: 'song.wav',
        ),
        _track(
          uid: 'd',
          intelUid: 'D',
          filename: 'song.flac',
        ),
      ];
      final result = _build(tracks: tracks);
      expect(result.manifest.entries.map((e) => e.identity.intelUid),
          ['A']);
      expect(result.exclusionsByIntelUid['B'],
          ExclusionReason.unsupportedFormat);
      expect(result.exclusionsByIntelUid['C'],
          ExclusionReason.unsupportedFormat);
      expect(result.exclusionsByIntelUid['D'],
          ExclusionReason.unsupportedFormat);
    });

    test('de-dupes by intel_uid; prefers MP3 variant', () {
      // Two rows share intelUid 'A'. One is MP3, one is AIFF.
      // MP3 wins; AIFF gets a duplicateIdentity exclusion.
      // (The AIFF would ALSO have been excluded by
      // unsupportedFormat, but the dedup check fires first when
      // they share intelUid — verifies pipeline order.)
      final tracks = [
        _track(uid: 'a-aiff', intelUid: 'A', filename: 'a.aiff'),
        _mp3(uid: 'a-mp3', intelUid: 'A'),
      ];
      final result = _build(tracks: tracks);
      // The AIFF still excluded by unsupportedFormat (it's
      // checked BEFORE dedup so we don't even consider it a
      // candidate).
      expect(result.manifest.entries, hasLength(1));
      expect(result.manifest.entries.single.identity.variantId, 'a-mp3');
    });

    test('exclusion priority: reviewed beats unavailable', () {
      // Per the plan, the FIRST reason that matches wins so the
      // diagnostic is deterministic. A reviewed-AND-missing
      // track should report `reviewed` (the user-meaningful
      // signal) rather than `unavailable` (the lower-level
      // signal).
      final tracks = [
        _mp3(
          uid: 'a',
          intelUid: 'A',
          reviewed: true,
          availability: 'missing',
        ),
      ];
      final result = _build(tracks: tracks);
      expect(result.exclusionsByIntelUid['A'], ExclusionReason.reviewed);
    });
  });

  group('ManifestBuilder — stage 2-3: preservation + pin queue', () {
    test('preserves already-on-phone tracks that stay eligible', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A'),
        _mp3(uid: 'b', intelUid: 'B'),
      ];
      final result = _build(
        tracks: tracks,
        phoneCachedIntelUids: {'A'},
        currentInventory: [
          _pinnedRow('A'), // already pinned + cached
        ],
      );
      expect(
        result.manifest.entries.map((e) => e.identity.intelUid).toSet(),
        equals({'A', 'B'}),
      );
      // Preserved-pinned entry carries residency=pinned.
      final preserved = result.manifest.entries
          .firstWhere((e) => e.identity.intelUid == 'A');
      expect(preserved.residency, ResidencyClass.pinned);
    });

    test('FIFO pin queue: oldest pinned_at fills first', () {
      // Two pinned tracks compete for one slot. Older pinnedAt
      // wins; newer goes to pinQueueOverflow.
      final tracks = [
        _mp3(uid: 'older', intelUid: 'OLDER', filesize: 5_000_000),
        _mp3(uid: 'newer', intelUid: 'NEWER', filesize: 5_000_000),
      ];
      final result = _build(
        tracks: tracks,
        device: _device(
          capacity: const CapacityPolicy.songs(1),
        ),
        phoneCachedIntelUids: {'OLDER', 'NEWER'},
        currentInventory: [
          _pinnedRow('OLDER',
              pinnedAt: DateTime(2024, 1, 1), byteSize: 5_000_000),
          _pinnedRow('NEWER',
              pinnedAt: DateTime(2024, 6, 1), byteSize: 5_000_000),
        ],
      );
      expect(
        result.manifest.entries.map((e) => e.identity.intelUid).toList(),
        ['OLDER'],
      );
      expect(result.exclusionsByIntelUid['NEWER'],
          ExclusionReason.pinQueueOverflow);
    });
  });

  group('ManifestBuilder — stage 4: random recipe (deterministic)', () {
    test('same seed + same inputs → identical manifest entries', () {
      final tracks = [
        for (var i = 0; i < 20; i++)
          _mp3(uid: 'u$i', intelUid: 'I$i', filesize: 1_000_000),
      ];
      final r1 = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(5)),
        randomSeed: 42,
      );
      final r2 = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(5)),
        randomSeed: 42,
      );
      expect(
        r1.manifest.entries.map((e) => e.identity.intelUid).toList(),
        equals(r2.manifest.entries.map((e) => e.identity.intelUid).toList()),
      );
    });

    test('different seeds produce different orderings', () {
      // Probabilistic but with 20 candidates + 5 picks, the
      // chance of identical permutations across two arbitrary
      // seeds is negligible.
      final tracks = [
        for (var i = 0; i < 20; i++)
          _mp3(uid: 'u$i', intelUid: 'I$i', filesize: 1_000_000),
      ];
      final r1 = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(5)),
        randomSeed: 1,
      );
      final r2 = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(5)),
        randomSeed: 999,
      );
      expect(
        r1.manifest.entries.map((e) => e.identity.intelUid).toList(),
        isNot(r2.manifest.entries.map((e) => e.identity.intelUid).toList()),
      );
    });

    test('recent-eviction cooldown soft-deprioritizes (still selectable)',
        () {
      // Two eligible candidates, capacity for 1. The one in
      // cooldown should land LAST in the random deck, so the
      // fresh one wins. Tag also surfaces in exclusion records
      // as informational.
      final tracks = [
        _mp3(uid: 'fresh', intelUid: 'FRESH', filesize: 1_000_000),
        _mp3(uid: 'cooled', intelUid: 'COOLED', filesize: 1_000_000),
      ];
      final result = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(1)),
        recentlyEvictedIntelUids: {'COOLED'},
        randomSeed: 42,
      );
      expect(result.manifest.entries, hasLength(1));
      expect(result.manifest.entries.single.identity.intelUid, 'FRESH');
      // Cooled is excluded for capacity, NOT cooldown — cooldown
      // is a deprioritization, not a hard filter.
      expect(result.exclusionsByIntelUid['COOLED'],
          ExclusionReason.capacityExceeded);
    });
  });

  group('ManifestBuilder — stage 5: capacity budgeting', () {
    test('song-count capacity strictly capped', () {
      final tracks = [
        for (var i = 0; i < 10; i++)
          _mp3(uid: 'u$i', intelUid: 'I$i', filesize: 1_000_000),
      ];
      final result = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(3)),
        randomSeed: 42,
      );
      expect(result.manifest.entries, hasLength(3));
      // The other 7 all got capacityExceeded.
      expect(
        result.exclusions
            .where((e) => e.reason == ExclusionReason.capacityExceeded)
            .length,
        7,
      );
    });

    test('storage-budget capacity stops on cumulative bytes', () {
      // Three tracks of 4MB each, budget = 10MB → only 2 fit.
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', filesize: 4_000_000),
        _mp3(uid: 'b', intelUid: 'B', filesize: 4_000_000),
        _mp3(uid: 'c', intelUid: 'C', filesize: 4_000_000),
      ];
      final result = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.bytes(10_000_000)),
        randomSeed: 42,
      );
      expect(result.manifest.entries, hasLength(2));
      expect(
        result.exclusions
            .where((e) => e.reason == ExclusionReason.capacityExceeded)
            .length,
        1,
      );
    });

    test('pinned consume budget FIRST; rotating fills remainder', () {
      // Capacity 3 songs. 2 pinned + 5 unreviewed candidates.
      // Result: 2 pinned + 1 random fill.
      final tracks = [
        _mp3(uid: 'p1', intelUid: 'P1', filesize: 1_000_000),
        _mp3(uid: 'p2', intelUid: 'P2', filesize: 1_000_000),
        _mp3(uid: 'r1', intelUid: 'R1', filesize: 1_000_000),
        _mp3(uid: 'r2', intelUid: 'R2', filesize: 1_000_000),
        _mp3(uid: 'r3', intelUid: 'R3', filesize: 1_000_000),
        _mp3(uid: 'r4', intelUid: 'R4', filesize: 1_000_000),
        _mp3(uid: 'r5', intelUid: 'R5', filesize: 1_000_000),
      ];
      final result = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(3)),
        phoneCachedIntelUids: {'P1', 'P2'},
        currentInventory: [
          _pinnedRow('P1',
              pinnedAt: DateTime(2024, 1, 1), byteSize: 1_000_000),
          _pinnedRow('P2',
              pinnedAt: DateTime(2024, 2, 1), byteSize: 1_000_000),
        ],
        randomSeed: 42,
      );
      // Pinned + 1 rotating = 3.
      expect(result.manifest.entries, hasLength(3));
      final pinnedCount = result.manifest.entries
          .where((e) => e.residency == ResidencyClass.pinned)
          .length;
      final rotatingCount = result.manifest.entries
          .where((e) => e.residency == ResidencyClass.rotating)
          .length;
      expect(pinnedCount, 2);
      expect(rotatingCount, 1);
    });
  });

  group('ManifestBuilder — stage 6: diff emission', () {
    test('need_add captures tracks not currently on phone', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', filesize: 3_000_000),
        _mp3(uid: 'b', intelUid: 'B', filesize: 4_000_000),
      ];
      final result = _build(
        tracks: tracks,
        phoneCachedIntelUids: const {}, // nothing on phone yet
        currentInventory: const [],
      );
      expect(result.diff.needAdd.map((id) => id.intelUid).toSet(),
          equals({'A', 'B'}));
      expect(result.diff.needAddBytes, 7_000_000);
      expect(result.diff.needRemove, isEmpty);
    });

    test('need_remove captures phone-held tracks no longer in manifest',
        () {
      // 'A' stays, 'STALE' is on the phone but not in the
      // library anymore (e.g., user deleted on desktop).
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', filesize: 3_000_000),
      ];
      final result = _build(
        tracks: tracks,
        phoneCachedIntelUids: {'A', 'STALE'},
        currentInventory: [
          _pinnedRow('A', byteSize: 3_000_000),
          _pinnedRow('STALE', byteSize: 5_000_000),
        ],
      );
      expect(result.diff.needRemove.map((id) => id.intelUid).toSet(),
          equals({'STALE'}));
      expect(result.diff.needRemoveBytes, 5_000_000);
    });

    test('current totals reflect the pre-sync inventory', () {
      final tracks = [
        _mp3(uid: 'a', intelUid: 'A', filesize: 3_000_000),
      ];
      final result = _build(
        tracks: tracks,
        phoneCachedIntelUids: {'A', 'STALE'},
        currentInventory: [
          _pinnedRow('A', byteSize: 3_000_000),
          _pinnedRow('STALE', byteSize: 5_000_000),
        ],
      );
      expect(result.diff.currentTrackCount, 2);
      expect(result.diff.currentInventoryBytes, 8_000_000);
    });
  });

  group('ManifestBuilder — full dry-run fixture', () {
    test(
        '10 tracks, 3 reviewed, 2 pinned, 2 cloud-only, capacity 5 songs '
        '→ exact expected manifest', () {
      // The fixture from the plan's "Dry-run tests" section.
      // Pinned: P1 (older), P2 (newer)
      // Reviewed: R1, R2, R3
      // Cloud-only (unavailable): C1, C2
      // Unreviewed eligible: U1, U2, U3
      // Capacity: 5 songs (mode: songCount)
      // Expected output:
      //   2 pinned (P1, P2)
      //   3 random (U1/U2/U3 in seeded order)
      //   Reviewed + cloud-only excluded with matching reasons.
      final tracks = [
        _mp3(uid: 'p1', intelUid: 'P1', filesize: 1_000_000),
        _mp3(uid: 'p2', intelUid: 'P2', filesize: 1_000_000),
        _mp3(uid: 'r1', intelUid: 'R1', reviewed: true),
        _mp3(uid: 'r2', intelUid: 'R2', reviewed: true),
        _mp3(uid: 'r3', intelUid: 'R3', reviewed: true),
        _mp3(uid: 'c1', intelUid: 'C1', availability: 'missing'),
        _mp3(uid: 'c2', intelUid: 'C2', availability: 'missing'),
        _mp3(uid: 'u1', intelUid: 'U1', filesize: 1_000_000),
        _mp3(uid: 'u2', intelUid: 'U2', filesize: 1_000_000),
        _mp3(uid: 'u3', intelUid: 'U3', filesize: 1_000_000),
      ];
      final result = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(5)),
        phoneCachedIntelUids: const {'P1', 'P2'},
        currentInventory: [
          _pinnedRow('P1',
              pinnedAt: DateTime(2024, 1, 1), byteSize: 1_000_000),
          _pinnedRow('P2',
              pinnedAt: DateTime(2024, 2, 1), byteSize: 1_000_000),
        ],
        randomSeed: 42,
      );

      // Manifest contains 5 entries: 2 pinned + 3 unreviewed.
      expect(result.manifest.entries, hasLength(5));
      final selectedIntelUids = result.manifest.entries
          .map((e) => e.identity.intelUid)
          .toSet();
      expect(
        selectedIntelUids,
        equals({'P1', 'P2', 'U1', 'U2', 'U3'}),
      );

      // Pinned entries first (priorityRank=100) with FIFO order
      // by pinned_at — P1 before P2.
      final pinnedEntries = result.manifest.entries
          .where((e) => e.residency == ResidencyClass.pinned)
          .toList();
      expect(pinnedEntries.map((e) => e.identity.intelUid),
          ['P1', 'P2']);

      // Exclusions cover every non-selected track with the
      // right reason.
      expect(result.exclusionsByIntelUid, {
        'R1': ExclusionReason.reviewed,
        'R2': ExclusionReason.reviewed,
        'R3': ExclusionReason.reviewed,
        'C1': ExclusionReason.unavailable,
        'C2': ExclusionReason.unavailable,
      });

      // Diff: nothing on phone other than P1/P2 already.
      // Adds 3 unreviewed (U1/U2/U3), removes nothing.
      expect(result.diff.needAdd.map((id) => id.intelUid).toSet(),
          equals({'U1', 'U2', 'U3'}));
      expect(result.diff.needRemove, isEmpty);
      expect(result.diff.needAddBytes, 3_000_000);
      expect(result.diff.currentTrackCount, 2);
      expect(result.diff.currentInventoryBytes, 2_000_000);
    });

    test('builder is pure — same inputs produce identical outputs', () {
      final tracks = [
        for (var i = 0; i < 6; i++)
          _mp3(uid: 'u$i', intelUid: 'I$i', filesize: 1_000_000),
      ];
      final r1 = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(3)),
        randomSeed: 7,
        generatedAtMs: 1747520000,
        manifestVersion: 5,
      );
      final r2 = _build(
        tracks: tracks,
        device: _device(capacity: const CapacityPolicy.songs(3)),
        randomSeed: 7,
        generatedAtMs: 1747520000,
        manifestVersion: 5,
      );
      // Identical manifests means identical wire JSON.
      expect(r1.manifest.toJson(), equals(r2.manifest.toJson()));
      expect(r1.diff.toJson(), equals(r2.diff.toJson()));
    });
  });
}

// ─── Fixture helpers ────────────────────────────────────────────────

ManifestBuilderResult _build({
  required List<Track> tracks,
  MobileDevice? device,
  List<PhoneInventoryRow> currentInventory = const [],
  Set<String> phoneCachedIntelUids = const {},
  Set<String> recentlyEvictedIntelUids = const {},
  int randomSeed = 42,
  int generatedAtMs = 1700000000000,
  int manifestVersion = 1,
}) {
  return const ManifestBuilder().build(ManifestBuilderInput(
    libraryTracks: tracks,
    device: device ?? _device(),
    currentInventory: currentInventory,
    phoneCachedIntelUids: phoneCachedIntelUids,
    recentlyEvictedIntelUids: recentlyEvictedIntelUids,
    randomSeed: randomSeed,
    generatedAtMs: generatedAtMs,
    manifestVersion: manifestVersion,
  ));
}

MobileDevice _device({CapacityPolicy? capacity}) {
  return MobileDevice(
    deviceId: 'd1',
    friendlyName: 'Zico iPhone',
    pairedAt: DateTime(2024, 1, 1),
    capacity: capacity ?? const CapacityPolicy.songs(100),
    tokenHash: 'stub',
  );
}

Track _mp3({
  required String uid,
  String? intelUid,
  String? contentHash = 'hash',
  bool reviewed = false,
  String availability = 'available',
  int filesize = 1_000_000,
}) {
  return _track(
    uid: uid,
    intelUid: intelUid,
    contentHash: contentHash,
    reviewed: reviewed,
    availability: availability,
    filename: '$uid.mp3',
    filesize: filesize,
  );
}

Track _track({
  required String uid,
  String? intelUid,
  String? contentHash = 'hash',
  bool reviewed = false,
  String availability = 'available',
  required String filename,
  int filesize = 1_000_000,
}) {
  return Track(
    uid: uid,
    fingerprint: 'fp-$uid',
    contentHash: contentHash,
    intelUid: intelUid,
    path: '/lib/$filename',
    filename: filename,
    sourceId: 'src1',
    filesize: filesize,
    title: 'Title $uid',
    artist: 'Artist',
    availability: availability,
    duration: const Duration(seconds: 240),
    reviewedAt: reviewed ? DateTime(2024, 5, 1) : null,
  );
}

PhoneInventoryRow _pinnedRow(
  String intelUid, {
  DateTime? pinnedAt,
  int byteSize = 1_000_000,
}) {
  return PhoneInventoryRow(
    intelUid: intelUid,
    variantId: 'variant-$intelUid',
    residency: ResidencyClass.pinned,
    byteSize: byteSize,
    pinnedAt: pinnedAt ?? DateTime(2024, 1, 1),
  );
}

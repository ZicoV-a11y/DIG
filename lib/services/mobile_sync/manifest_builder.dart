import 'dart:math';

import 'package:shared_core/shared_core.dart';

import '../../models/track.dart';
import 'mobile_device.dart';

/// Why a candidate didn't make it into the manifest. Surfaced
/// alongside the manifest so the desktop can render a "Why isn't
/// this track on my phone?" diagnostic, and so the test suite can
/// assert exact exclusion behavior.
///
/// Every excluded candidate gets exactly one reason — the FIRST
/// one that matches. Order in this enum is the priority order
/// the builder walks.
enum ExclusionReason {
  /// `reviewed_at IS NOT NULL`. Slice 1 ships unreviewed-only.
  reviewed,

  /// `availability_state != 'available'`. Includes Dropbox /
  /// iCloud placeholders, missing files, superseded variants.
  unavailable,

  /// `contentHash` is null. We require byte identity to ship.
  noContentHash,

  /// `intelUid` is null. We require song identity to reconcile
  /// telemetry back to the right `tracks` row.
  noIntelUid,

  /// No MP3 variant available AND transcode-on-send isn't yet
  /// implemented (Slice 1). Slice 3 will revisit this rule.
  unsupportedFormat,

  /// Eligible but no room in the capacity budget. Slice 1 just
  /// drops these; future slices may carry them in a wait queue.
  capacityExceeded,

  /// Two eligible rows resolve to the same `intelUid`. We ship
  /// at most one variant per song identity per device.
  duplicateIdentity,

  /// `pending_pin = 1` row in mobile_sync_inventory — pinned but
  /// queued behind capacity overflow. Surfaces in the sidebar's
  /// "12 GB pinned, 7 GB queued" indicator.
  pinQueueOverflow,

  /// Within the recent-eviction cooldown window (default 14 days).
  /// Not excluded outright — soft-deprioritized in random recipes.
  recentEvictionCooldown,
}

/// One row's exclusion record. Carries enough metadata for the
/// "why isn't this on my phone?" diagnostic without needing a
/// re-query.
class ExclusionRecord {
  final String intelUid;
  final String? variantId;
  final ExclusionReason reason;

  /// Free-form context — e.g., the bytes that would have been
  /// added before `capacityExceeded` triggered, or the
  /// availability_state value for `unavailable`.
  final String? detail;

  const ExclusionRecord({
    required this.intelUid,
    required this.reason,
    this.variantId,
    this.detail,
  });
}

/// Pure-data input to [ManifestBuilder.build]. All the state the
/// builder needs to decide what ships, in one place. Tests pass
/// hand-constructed fixtures; production passes a snapshot
/// gathered by the controller right before building.
class ManifestBuilderInput {
  /// Every track row in the desktop library, with its current
  /// intelligence joined. Builder filters down from here.
  final List<Track> libraryTracks;

  /// Target device — capacity + transport policy + recipe.
  final MobileDevice device;

  /// The phone's current inventory. Used for both diff
  /// computation (need_add / need_remove) and continuity
  /// preservation (already-eligible held tracks stay).
  final List<PhoneInventoryRow> currentInventory;

  /// intel_uids the phone reports it currently holds. Sourced
  /// from the phone's local cached_tracks, sent on the sync-
  /// request envelope. Drives the diff. Subset of
  /// [currentInventory] but kept distinct because the canonical
  /// "what does the phone actually hold" answer is the phone's
  /// truth, not the desktop's inventory record.
  final Set<String> phoneCachedIntelUids;

  /// intel_uids evicted from this device within the cooldown
  /// window. Soft-deprioritized in random selection (rank weight
  /// × 0.1) — see §8.
  final Set<String> recentlyEvictedIntelUids;

  /// Seed for the deterministic RNG. Same seed + same inputs →
  /// same manifest. Production uses the sync-request timestamp;
  /// tests use a fixed value.
  final int randomSeed;

  /// Wall-clock for the generated_at field on the emitted manifest.
  final int generatedAtMs;

  /// Monotonically increasing per device. Caller bumps from
  /// `device.lastManifestVersion + 1`.
  final int manifestVersion;

  const ManifestBuilderInput({
    required this.libraryTracks,
    required this.device,
    required this.currentInventory,
    required this.phoneCachedIntelUids,
    required this.recentlyEvictedIntelUids,
    required this.randomSeed,
    required this.generatedAtMs,
    required this.manifestVersion,
  });
}

/// One row in the phone's current inventory as the desktop sees it.
/// Sourced from `mobile_sync_inventory` rows for this device.
class PhoneInventoryRow {
  final String intelUid;
  final String variantId;
  final ResidencyClass residency;
  final DateTime? pinnedAt;
  final bool pendingPin;
  final int byteSize;

  const PhoneInventoryRow({
    required this.intelUid,
    required this.variantId,
    required this.residency,
    required this.byteSize,
    this.pinnedAt,
    this.pendingPin = false,
  });
}

/// What the builder emits. Three artifacts produced together
/// because they share the same compilation pass — making them
/// separate calls would force the work to run twice.
class ManifestBuilderResult {
  final SyncManifest manifest;
  final ManifestDiff diff;
  final List<ExclusionRecord> exclusions;

  const ManifestBuilderResult({
    required this.manifest,
    required this.diff,
    required this.exclusions,
  });

  /// Quick lookup by intelUid for tests + UI.
  Map<String, ExclusionReason> get exclusionsByIntelUid =>
      {for (final e in exclusions) e.intelUid: e.reason};
}

/// Pure-function constrained-inventory compilation.
///
/// One public entry point — [build] — that takes a
/// [ManifestBuilderInput] and returns a [ManifestBuilderResult].
/// No I/O, no DB writes, no clock reads (the input carries the
/// timestamp). That purity is the load-bearing property: a
/// `GET /api/v1/manifest/preview` and the actual sync share the
/// same builder; tests assert exact output; the desktop can
/// dry-run a hypothetical capacity in the sidebar without
/// touching real state.
///
/// The internal pipeline matches the seven principles documented
/// in the plan:
///
///   1. Build eligible pool (hard filters → exclusion reasons)
///   2. Apply preservation rules (continuity from current inventory)
///   3. Apply pin queue (FIFO pinned consume budget first)
///   4. Apply inventory policy (recipe — Slice 1: unreviewed-random)
///   5. Apply capacity budgeting (trim to fit; capacity_exceeded
///      reasons)
///   6. Emit manifest + diff + exclusions
class ManifestBuilder {
  const ManifestBuilder();

  ManifestBuilderResult build(ManifestBuilderInput input) {
    final exclusions = <ExclusionRecord>[];

    // ── Stage 1: eligible pool ────────────────────────────────────
    // Walk every library row once. Drop ineligible into the
    // exclusion bucket with a specific reason; keep the rest.
    // Order of checks matters — the FIRST reason that matches
    // wins, so the diagnostic surface is deterministic.
    final eligibleByIntelUid = <String, Track>{};
    for (final t in input.libraryTracks) {
      final intelUid = t.intelUid;
      if (intelUid == null || intelUid.isEmpty) {
        exclusions.add(ExclusionRecord(
          intelUid: t.uid,
          reason: ExclusionReason.noIntelUid,
        ));
        continue;
      }
      if (t.reviewed) {
        exclusions.add(ExclusionRecord(
          intelUid: intelUid,
          variantId: t.uid,
          reason: ExclusionReason.reviewed,
        ));
        continue;
      }
      if (t.availability != 'available') {
        exclusions.add(ExclusionRecord(
          intelUid: intelUid,
          variantId: t.uid,
          reason: ExclusionReason.unavailable,
          detail: t.availability,
        ));
        continue;
      }
      final hash = t.contentHash;
      if (hash == null || hash.isEmpty) {
        exclusions.add(ExclusionRecord(
          intelUid: intelUid,
          variantId: t.uid,
          reason: ExclusionReason.noContentHash,
        ));
        continue;
      }
      if (!_supportedFormat(t.filename)) {
        exclusions.add(ExclusionRecord(
          intelUid: intelUid,
          variantId: t.uid,
          reason: ExclusionReason.unsupportedFormat,
          detail: t.filename,
        ));
        continue;
      }

      // De-dup by intelUid: ship at most one variant per song
      // identity. Prefer MP3 over other formats so Slice-1
      // passthrough has a file to actually serve. If we already
      // saw a candidate for this song, keep the better-ranked
      // one and exclude the worse.
      final existing = eligibleByIntelUid[intelUid];
      if (existing == null) {
        eligibleByIntelUid[intelUid] = t;
      } else {
        final keep = _preferredVariant(existing, t);
        final drop = identical(keep, existing) ? t : existing;
        eligibleByIntelUid[intelUid] = keep;
        exclusions.add(ExclusionRecord(
          intelUid: intelUid,
          variantId: drop.uid,
          reason: ExclusionReason.duplicateIdentity,
        ));
      }
    }

    // ── Stage 2: preservation rules ───────────────────────────────
    // A track currently on the phone that's STILL eligible stays
    // put (continuity). Drop already-evicted (no longer eligible)
    // from inventory — they'll show up in diff.need_remove.
    final phoneHeld = input.phoneCachedIntelUids;
    final preserved = <Track>[];
    final newCandidates = <Track>[];
    for (final entry in eligibleByIntelUid.entries) {
      if (phoneHeld.contains(entry.key)) {
        preserved.add(entry.value);
      } else {
        newCandidates.add(entry.value);
      }
    }

    // ── Stage 3: pin queue (FIFO) ─────────────────────────────────
    // Active pins are inventory rows with residency=pinned + the
    // intel_uid is in our eligible pool (otherwise the user
    // pinned something that's no longer available — that becomes
    // an exclusion). Pin order by pinned_at ASC (oldest first).
    final pinnedRows = input.currentInventory
        .where((r) => r.residency == ResidencyClass.pinned)
        .toList()
      ..sort((a, b) {
        final aT = a.pinnedAt?.millisecondsSinceEpoch ?? 0;
        final bT = b.pinnedAt?.millisecondsSinceEpoch ?? 0;
        return aT.compareTo(bT);
      });

    // pinned rows already get preserved-treatment if eligible;
    // separate them so capacity accounting walks them first.
    final pinnedIntelUids = pinnedRows.map((r) => r.intelUid).toSet();
    final preservedNonPinned =
        preserved.where((t) => !pinnedIntelUids.contains(t.intelUid!)).toList();
    final preservedPinned =
        preserved.where((t) => pinnedIntelUids.contains(t.intelUid!)).toList()
          ..sort((a, b) {
            // Re-sort by pinned_at to honor FIFO across the
            // preserved set.
            final ai = pinnedRows.indexWhere((r) => r.intelUid == a.intelUid);
            final bi = pinnedRows.indexWhere((r) => r.intelUid == b.intelUid);
            return ai.compareTo(bi);
          });

    // ── Stage 4: inventory policy ─────────────────────────────────
    // Slice 1: unreviewed-random. Seeded so the same inputs
    // produce the same shuffle. Pinned tracks are already in
    // preservedPinned; newCandidates is what randomization fills
    // remaining slots with. Apply recent-eviction-cooldown soft
    // deprioritization by partitioning + concatenating with
    // cooldown set placed at the end of the deck.
    final rng = Random(input.randomSeed);
    final cooldown = input.recentlyEvictedIntelUids;
    final fresh = <Track>[];
    final cooled = <Track>[];
    for (final t in newCandidates) {
      if (cooldown.contains(t.intelUid)) {
        cooled.add(t);
      } else {
        fresh.add(t);
      }
    }
    fresh.shuffle(rng);
    cooled.shuffle(rng);
    final randomDeck = [...fresh, ...cooled];

    // ── Stage 5: capacity budgeting ───────────────────────────────
    // Fill in priority order: pinned → preserved-non-pinned →
    // random deck. Stop when capacity exhausts. Anything that
    // doesn't fit gets a capacity_exceeded exclusion.
    //
    // Pinned that exceeds capacity goes to pinQueueOverflow (the
    // FIFO pin-queue contract from §3 — first N fit, rest queue).
    final cap = _CapacityBudget.forDevice(input.device);
    final selected = <_SelectedEntry>[];

    for (final t in preservedPinned) {
      final size = _approximateByteSize(t);
      if (!cap.tryAdd(size)) {
        exclusions.add(ExclusionRecord(
          intelUid: t.intelUid!,
          variantId: t.uid,
          reason: ExclusionReason.pinQueueOverflow,
          detail: 'pinned, capacity full',
        ));
        continue;
      }
      selected.add(_SelectedEntry(
        track: t,
        residency: ResidencyClass.pinned,
        priorityRank: 100,
        byteSize: size,
      ));
    }

    for (final t in preservedNonPinned) {
      final size = _approximateByteSize(t);
      if (!cap.tryAdd(size)) {
        exclusions.add(ExclusionRecord(
          intelUid: t.intelUid!,
          variantId: t.uid,
          reason: ExclusionReason.capacityExceeded,
          detail: 'preserved, capacity full',
        ));
        continue;
      }
      selected.add(_SelectedEntry(
        track: t,
        residency: ResidencyClass.rotating,
        priorityRank: 50,
        byteSize: size,
      ));
    }

    for (final t in randomDeck) {
      final size = _approximateByteSize(t);
      if (!cap.tryAdd(size)) {
        exclusions.add(ExclusionRecord(
          intelUid: t.intelUid!,
          variantId: t.uid,
          reason: ExclusionReason.capacityExceeded,
          detail: 'random fill, capacity full',
        ));
        continue;
      }
      final inCooldown = cooldown.contains(t.intelUid);
      if (inCooldown) {
        // Cooldown rows are included but tagged so the diagnostic
        // surface can show "we shipped a recently-evicted track
        // because the pool was thin."
        exclusions.add(ExclusionRecord(
          intelUid: t.intelUid!,
          variantId: t.uid,
          reason: ExclusionReason.recentEvictionCooldown,
          detail: 'included despite cooldown (low priority)',
        ));
      }
      selected.add(_SelectedEntry(
        track: t,
        residency: ResidencyClass.rotating,
        priorityRank: inCooldown ? 5 : 25,
        byteSize: size,
      ));
    }

    // ── Stage 6: emit ─────────────────────────────────────────────
    final entries = [
      for (final s in selected)
        ManifestEntry(
          identity: TrackIdentity(
            intelUid: s.track.intelUid!,
            variantId: s.track.uid,
            contentHash: s.track.contentHash!,
          ),
          title: s.track.title.isEmpty
              ? s.track.displayTitle
              : s.track.title,
          artist: s.track.artist.isEmpty
              ? s.track.displayArtist
              : s.track.artist,
          durationMs: s.track.duration.inMilliseconds,
          transportFormat: _transportFormatFor(s.track.filename),
          byteSize: s.byteSize,
          // Slice 1: transport hash = contentHash (the desktop's
          // 512KB heuristic). MP3 passthrough means the phone
          // receives exactly the bytes that hashed to this, so
          // mismatch on the phone-side re-hash means corruption
          // or a wrong-file-shipped bug. Slice 3+ swaps to full
          // sha256 of the transcoded output once the transport
          // cache abstraction lands.
          transportHash: s.track.contentHash!,
          residency: s.residency,
          priorityRank: s.priorityRank,
          favorite: s.track.favorite,
          reviewedAt: s.track.reviewedAt?.millisecondsSinceEpoch,
        ),
    ];

    final manifest = SyncManifest(
      manifestVersion: input.manifestVersion,
      deviceId: input.device.deviceId,
      generatedAt: input.generatedAtMs,
      capacity: input.device.capacity,
      entries: entries,
    );

    // Diff: phone needs to add anything in the new manifest that
    // it doesn't currently hold, and remove anything it currently
    // holds that isn't in the new manifest.
    final manifestIntelUids = {
      for (final e in entries) e.identity.intelUid: e,
    };
    final needAdd = <TrackIdentity>[];
    var needAddBytes = 0;
    for (final entry in entries) {
      if (!phoneHeld.contains(entry.identity.intelUid)) {
        needAdd.add(entry.identity);
        needAddBytes += entry.byteSize;
      }
    }
    final needRemove = <TrackIdentity>[];
    var needRemoveBytes = 0;
    for (final row in input.currentInventory) {
      if (!manifestIntelUids.containsKey(row.intelUid)) {
        needRemove.add(TrackIdentity(
          intelUid: row.intelUid,
          variantId: row.variantId,
          // The phone's current row has no content hash on the
          // desktop side — use empty string as a tombstone. (The
          // phone matches removes by intel_uid; content_hash is
          // not load-bearing for the remove path.)
          contentHash: '',
        ));
        needRemoveBytes += row.byteSize;
      }
    }

    final currentBytes = input.currentInventory
        .fold<int>(0, (s, r) => s + r.byteSize);

    final diff = ManifestDiff(
      needAdd: needAdd,
      needRemove: needRemove,
      needAddBytes: needAddBytes,
      needRemoveBytes: needRemoveBytes,
      currentInventoryBytes: currentBytes,
      currentTrackCount: input.currentInventory.length,
    );

    return ManifestBuilderResult(
      manifest: manifest,
      diff: diff,
      exclusions: exclusions,
    );
  }

  // ─── internals ────────────────────────────────────────────────────

  /// Slice 1: MP3 passthrough only. Other formats either need a
  /// sibling MP3 variant (caller would have to surface that) or
  /// transcoding (Slice 3+).
  bool _supportedFormat(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.mp3');
  }

  /// When two variants share an intelUid, prefer MP3. Tiebreak
  /// by larger filesize (better-quality master usually wins).
  Track _preferredVariant(Track a, Track b) {
    final aMp3 = _supportedFormat(a.filename);
    final bMp3 = _supportedFormat(b.filename);
    if (aMp3 != bMp3) return aMp3 ? a : b;
    if (a.filesize != b.filesize) return a.filesize > b.filesize ? a : b;
    // Deterministic tiebreak by uid string so the choice doesn't
    // wobble between calls.
    return a.uid.compareTo(b.uid) <= 0 ? a : b;
  }

  String _transportFormatFor(String filename) {
    // Slice 1: MP3 only. Future slices will return 'aac_256' /
    // 'opus_128' / etc based on the device's transport policy +
    // transcode-cache state.
    return 'mp3';
  }

  /// Byte size for capacity accounting. Slice 1 uses the
  /// original-file size since MP3 passthrough ships bytes as-is.
  /// Future slices will swap in the transcode-cache size.
  int _approximateByteSize(Track t) => t.filesize;
}

class _SelectedEntry {
  final Track track;
  final ResidencyClass residency;
  final int priorityRank;
  final int byteSize;
  const _SelectedEntry({
    required this.track,
    required this.residency,
    required this.priorityRank,
    required this.byteSize,
  });
}

/// Tracks remaining capacity. Knows whether it's bytes-based or
/// count-based and answers `tryAdd` accordingly.
class _CapacityBudget {
  factory _CapacityBudget.forDevice(MobileDevice device) {
    switch (device.capacity.mode) {
      case CapacityMode.songCount:
        return _CapacityBudget._(
          countRemaining: device.capacity.value,
          bytesRemaining: 1 << 62, // effectively unbounded
        );
      case CapacityMode.storageBudget:
        return _CapacityBudget._(
          countRemaining: 1 << 30, // effectively unbounded
          bytesRemaining: device.capacity.value,
        );
    }
  }

  _CapacityBudget._({
    required this.countRemaining,
    required this.bytesRemaining,
  });

  int countRemaining;
  int bytesRemaining;

  bool tryAdd(int byteSize) {
    if (countRemaining <= 0) return false;
    if (bytesRemaining < byteSize) return false;
    countRemaining -= 1;
    bytesRemaining -= byteSize;
    return true;
  }
}

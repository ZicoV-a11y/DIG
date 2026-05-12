import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Edge-case matrix for the file-availability state machine.
///
/// **Read this as a specification, not just coverage.** Each test
/// represents one rule of filesystem-truth semantics. Green tests
/// pin down the current 3-state behavior (`available` / `missing` /
/// `superseded`) as regression guards. Tests tagged `RED:` express
/// desired behavior the current state set cannot deliver — they
/// are the design punch-list for whether new states (or events, or
/// source-level fields) are needed.
///
/// See `~/.claude/projects/-Users-neomac-music-tracker/memory/`:
/// - `project_file_availability_state_machine.md`
/// - `project_availability_test_matrix_as_spec.md`
void main() {
  late AppDatabase appDb;
  late LibraryRepository repo;
  late Database raw;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = LibraryRepository(appDb);
    raw = appDb.db;
    // Two sources so cross-source scenarios are expressible.
    await raw.insert('sources', {
      'id': 'srcA',
      'display_name': 'Source A',
      'folder_path': '/srcA',
      'created_at': 0,
    });
    await raw.insert('sources', {
      'id': 'srcB',
      'display_name': 'Source B',
      'folder_path': '/srcB',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<void> seedFile({
    required String path,
    required String sourceId,
    required String fingerprint,
    required String uid,
    String? intelUid,
    String state = 'available',
    int filesize = 1024,
    int durationMs = 300000,
    String? contentHash,
  }) async {
    // Default to non-degenerate stat inputs so tests against
    // markCrossSourceMoves (which guards against filesize <= 0 /
    // duration_ms <= 0) can match by default. Tests that
    // specifically want to probe the junk-fingerprint guard
    // override filesize/durationMs to 0.
    //
    // contentHash defaults to null (legacy / pre-v10 row); tests
    // that exercise the Slice 5 strong path override.
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': sourceId,
      'filename': path.split('/').last,
      'filesize': filesize,
      'modified_at': 0,
      'duration_ms': durationMs,
      'fingerprint': fingerprint,
      'content_hash': contentHash,
      'uid': uid,
      'intel_uid': intelUid,
      'is_available': state == 'available' ? 1 : 0,
      'availability_state': state,
      'last_seen_at': 0,
      'title': 'T',
      'artist': 'A',
    });
  }

  Future<String?> stateOf(String path) async {
    final r = await raw.query('indexed_files',
        columns: ['availability_state'],
        where: 'path = ?',
        whereArgs: [path],
        limit: 1);
    return r.isEmpty ? null : r.first['availability_state'] as String?;
  }

  Future<bool> rowExists(String path) async {
    final r = await raw.query('indexed_files',
        where: 'path = ?', whereArgs: [path], limit: 1);
    return r.isNotEmpty;
  }

  /// One full scan pass on a source — mirrors the order in
  /// `LibraryController._scanIntoSource`:
  ///   1. markUnseenAvailability   (paths not in seenPaths → missing)
  ///   2. markMovedSupersessions   (missing + same-fp-as-available
  ///                                 in same source → superseded)
  ///   3. markCrossSourceMoves     (missing + EXACTLY ONE same-fp
  ///                                 available across ALL sources →
  ///                                 superseded; junk-fp rows excluded)
  Future<void> simulateScan(String sourceId, Set<String> seenPaths) async {
    await repo.markUnseenAvailability(sourceId, seenPaths);
    await repo.markMovedSupersessions(sourceId);
    await repo.markCrossSourceMoves();
  }

  // ───────────────────────────────────────────────────────────────────
  // CATEGORY 1 — File lifecycle within a single source.
  // The clearest test of which transitions the current state set
  // actually expresses.
  // ───────────────────────────────────────────────────────────────────
  group('1. File lifecycle (single source)', () {
    test('move within source: same fp at new path → old superseded, new available',
        () async {
      await seedFile(
          path: '/srcA/old.mp3', sourceId: 'srcA', fingerprint: 'fp1', uid: 'u1');
      await seedFile(
          path: '/srcA/new.mp3', sourceId: 'srcA', fingerprint: 'fp1', uid: 'u2');
      await simulateScan('srcA', {'/srcA/new.mp3'});
      expect(await stateOf('/srcA/old.mp3'), 'superseded');
      expect(await stateOf('/srcA/new.mp3'), 'available');
    });

    test('rename within source: behaves identical to move (same fp, new path)',
        () async {
      await seedFile(
          path: '/srcA/dir/old name.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u1');
      await seedFile(
          path: '/srcA/dir/new name.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u2');
      await simulateScan('srcA', {'/srcA/dir/new name.mp3'});
      expect(await stateOf('/srcA/dir/old name.mp3'), 'superseded');
      expect(await stateOf('/srcA/dir/new name.mp3'), 'available');
    });

    test('move + re-encode: different fp at new path → old stays missing (NOT superseded)',
        () async {
      // Fingerprint changes between MP3 and AIFF, so supersession
      // cannot match. The old MP3 is treated as truly gone.
      // Variant-bucket layer (identity by basename+title+artist+duration)
      // is what links these as one song; the availability layer
      // intentionally does not try to re-link across fingerprints.
      await seedFile(
          path: '/srcA/song.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-mp3',
          uid: 'u-mp3');
      await seedFile(
          path: '/srcA/song.aiff',
          sourceId: 'srcA',
          fingerprint: 'fp-aiff',
          uid: 'u-aiff');
      await simulateScan('srcA', {'/srcA/song.aiff'});
      expect(await stateOf('/srcA/song.mp3'), 'missing');
      expect(await stateOf('/srcA/song.aiff'), 'available');
    });

    test('copy-then-delete-original: dup keeps same fp, original gone → original superseded',
        () async {
      // User Cmd-D'd to /dup.mp3 then deleted /orig.mp3.
      // Scan sees only /dup.mp3 — original is correctly treated
      // as a move (same fp on a still-present row).
      await seedFile(
          path: '/srcA/orig.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-orig');
      await seedFile(
          path: '/srcA/dup.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-dup');
      await simulateScan('srcA', {'/srcA/dup.mp3'});
      expect(await stateOf('/srcA/orig.mp3'), 'superseded');
      expect(await stateOf('/srcA/dup.mp3'), 'available');
    });

    test('simultaneous duplicates (both seen, same fp): NO supersession churn',
        () async {
      // Critical: the detector must not flag a row as 'superseded'
      // just because a sibling with the same fingerprint exists.
      // It must require the candidate row to actually be missing.
      await seedFile(
          path: '/srcA/a.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-a');
      await seedFile(
          path: '/srcA/b.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-b');
      await simulateScan('srcA', {'/srcA/a.mp3', '/srcA/b.mp3'});
      expect(await stateOf('/srcA/a.mp3'), 'available');
      expect(await stateOf('/srcA/b.mp3'), 'available');
    });

    test('delete then restore: missing in scan N, back in scan N+1 → returns to available',
        () async {
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-x');
      await simulateScan('srcA', {});
      expect(await stateOf('/srcA/x.mp3'), 'missing');
      await simulateScan('srcA', {'/srcA/x.mp3'});
      expect(await stateOf('/srcA/x.mp3'), 'available');
    });

    test('lone delete (no successor): stays missing, not superseded', () async {
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-x');
      await simulateScan('srcA', {});
      expect(await stateOf('/srcA/x.mp3'), 'missing');
    });

    test('superseded row across re-scans: end state is stable (transient flap is fine)',
        () async {
      // Implementation detail worth pinning: markUnseenAvailability
      // resets ALL unseen rows to 'missing' (including superseded
      // ones), then markMovedSupersessions re-promotes. The row's
      // *end state* after each scan is stable — that's the contract.
      // A future refactor that batches both steps in one pass
      // should not regress this end-state invariant.
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u1');
      await seedFile(
          path: '/srcA/new.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u2');
      await simulateScan('srcA', {'/srcA/new.mp3'});
      await simulateScan('srcA', {'/srcA/new.mp3'});
      await simulateScan('srcA', {'/srcA/new.mp3'});
      expect(await stateOf('/srcA/old.mp3'), 'superseded');
      expect(await stateOf('/srcA/new.mp3'), 'available');
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // CATEGORY 2 — Source topology.
  // Probes which concerns are per-file vs per-source.
  // ───────────────────────────────────────────────────────────────────
  group('2. Source topology', () {
    test('source never scanned: rows retain last state — no implicit transition',
        () async {
      // Findings hypothesis (validated): `source_offline` is NOT
      // expressible per-file. Skipping the scan leaves every row
      // 'available' even when the source is unreachable. To
      // distinguish "files still there" from "we cannot see",
      // we'd need source-level state — not another column on
      // indexed_files.
      await seedFile(
          path: '/srcB/x.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          uid: 'u-x');
      await simulateScan('srcA', {}); // srcB skipped
      expect(await stateOf('/srcB/x.mp3'), 'available');
    });

    test('per-source supersession isolation: same-fp in OTHER source does NOT match',
        () async {
      // markMovedSupersessions(srcA) cannot use srcB's rows.
      // This is what makes "source not scanned" safe — rows in
      // an offline srcB cannot accidentally trigger supersessions
      // in srcA either.
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-srcA');
      await seedFile(
          path: '/srcB/x.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          uid: 'u-srcB');
      await repo.markUnseenAvailability('srcA', {});
      final supersededCount = await repo.markMovedSupersessions('srcA');
      expect(supersededCount, 0);
      expect(await stateOf('/srcA/x.mp3'), 'missing');
    });

    test(
        'cross-source move (file relocated srcA → srcB, same fp) → old row SUPERSEDED via uniqueness rule',
        () async {
      // Resolution of the earlier RED test. Once
      // markCrossSourceMoves shipped (uniqueness rule only,
      // strict on valid stat inputs), a file moved between
      // watched sources stops lingering as missing and gets
      // auto-resolved as the intake → prep → crate workflow
      // expects. The 4-condition rule (also temporal + small
      // overlap window) lives in project memory and ships in
      // a later phase once `first_seen_at` and `content_hash`
      // are in place.
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-old');
      await seedFile(
          path: '/srcB/x.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          uid: 'u-new');
      await simulateScan('srcA', {});
      await simulateScan('srcB', {'/srcB/x.mp3'});
      expect(await stateOf('/srcA/x.mp3'), 'superseded');
      expect(await stateOf('/srcB/x.mp3'), 'available');
    });

    test(
        'uniqueness rule: cross-source supersession blocked when 2+ available rows match',
        () async {
      // Critical safety valve. If the same fingerprint exists on
      // more than one available row globally, the relocation is
      // ambiguous — could be any of N candidates, or could be a
      // legitimate Cmd+D coexistence. Leave it missing; user can
      // manually relink via the Review dialog.
      //
      // Seed the missing row directly so the per-source
      // markMovedSupersessions pass (which has no uniqueness
      // guard yet) doesn't interfere with the test.
      await seedFile(
          path: '/srcA/missing.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcB/copy1.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          uid: 'u-c1');
      await seedFile(
          path: '/srcB/copy2.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          uid: 'u-c2');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/missing.mp3'), 'missing');
    });

    test(
        'junk fingerprint (filesize=0) on the missing row blocks supersession',
        () async {
      // The Surfeando-ghost scenario from the V2 DB: a row born
      // from a Dropbox-sync mid-scan glitch with filesize=-1 /
      // duration_ms=0 → junk fingerprint. Even if a same-fp
      // available row existed somewhere, the missing side must
      // not auto-supersede — its fingerprint is corrupted scan
      // state, not real identity evidence.
      await seedFile(
          path: '/srcA/ghost.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-junk',
          uid: 'u-ghost',
          state: 'missing',
          filesize: 0,
          durationMs: 0);
      await seedFile(
          path: '/srcB/real.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp-junk',
          uid: 'u-real');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/ghost.mp3'), 'missing');
    });

    test(
        'junk fingerprint on the available row blocks supersession',
        () async {
      // Symmetric guard — if the candidate "available" row was
      // born from a stat-failure, it doesn't count as evidence
      // for the missing row's relocation either.
      await seedFile(
          path: '/srcA/lost.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-junk',
          uid: 'u-lost',
          state: 'missing');
      await seedFile(
          path: '/srcB/garbage.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp-junk',
          uid: 'u-garbage',
          filesize: 0,
          durationMs: 0);
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/lost.mp3'), 'missing');
    });

    // ──────────────────────────────────────────────────────────────
    // Slice 5: content_hash matching takes precedence over
    // fingerprint when both rows have it. Catches the case the
    // tactical (fingerprint-only) path missed: rename-during-move.
    // ──────────────────────────────────────────────────────────────

    test(
        'cross-source move via content_hash — different fingerprint (rename across folders)',
        () async {
      // The case Slice 5 specifically exists to handle. User
      // copied a file, renamed it during the move, ended up in
      // a different watched source. Fingerprint (basename-based)
      // can't link them. content_hash (byte-based) can.
      await seedFile(
          path: '/srcA/old name.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-old-basename',
          contentHash: 'ch-bytes-1',
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcB/cleaner name.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp-new-basename',
          contentHash: 'ch-bytes-1',
          uid: 'u-new');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/old name.mp3'), 'superseded');
      expect(await stateOf('/srcB/cleaner name.mp3'), 'available');
    });

    test(
        'content_hash governs: matching fingerprint but DIFFERENT content_hash does NOT supersede',
        () async {
      // Two unrelated files happen to share a basename (and
      // therefore fingerprint, since fingerprint is basename-
      // based). content_hashes prove they are different byte
      // sequences. Don't auto-merge.
      await seedFile(
          path: '/srcA/song.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-collision',
          contentHash: 'ch-bytes-A',
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcB/song.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp-collision',
          contentHash: 'ch-bytes-B',
          uid: 'u-other');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/song.mp3'), 'missing',
          reason:
              'content_hash mismatch must block auto-merge even when fingerprints align');
    });

    test(
        'uniqueness rule on content_hash: 2+ same-content_hash available rows blocks supersession',
        () async {
      await seedFile(
          path: '/srcA/missing.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          contentHash: 'ch-dupes',
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcB/copy1.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp2',
          contentHash: 'ch-dupes',
          uid: 'u-c1');
      await seedFile(
          path: '/srcB/copy2.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp3',
          contentHash: 'ch-dupes',
          uid: 'u-c2');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/missing.mp3'), 'missing');
    });

    test(
        'asymmetric NULL: missing row HAS content_hash, available is NULL — no fingerprint fallback',
        () async {
      // When the missing row has a content_hash, we trust ONLY
      // content_hash. A NULL on the available side means we don't
      // know its bytes yet → can't be sure it's the same file →
      // do not auto-merge even if fingerprint matches. Backfill
      // worker will fill the available row's content_hash in
      // shortly; if it matches, the next call will supersede.
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          contentHash: 'ch-bytes',
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcB/new.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          // contentHash explicitly null — backfill hasn't run.
          uid: 'u-new');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/old.mp3'), 'missing');
    });

    test(
        'asymmetric NULL: missing row NULL, available has content_hash — fingerprint fallback fires',
        () async {
      // Legacy missing row (pre-v10) hasn't been visited by
      // backfill yet. Available row is freshly scanned with
      // content_hash. Fall back to fingerprint matching.
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          // contentHash null on the missing row (legacy).
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcB/new.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          contentHash: 'ch-bytes',
          uid: 'u-new');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/old.mp3'), 'superseded');
    });

    // ──────────────────────────────────────────────────────────────
    // External rename + intel migration. This block exists to
    // close the "I renamed my file and my plays vanished" bug:
    // a rename in Finder / Mp3tag / Rekordbox / etc produces a
    // new indexed_files row with intel_uid=NULL because
    // reconnect-by-fingerprint can't bridge the basename change.
    // markCrossSourceMoves must migrate the superseded row's
    // intel_uid onto the available successor so behavioural
    // history follows the file across the rename.
    // ──────────────────────────────────────────────────────────────

    test(
        'rename in same source → event narrates as auto_move_same_source',
        () async {
      // Caught by content_hash even though fingerprint differs
      // (basename changed). Successor sits in the SAME source as
      // the missing predecessor, so the event-type label should
      // reflect that — not the historical "cross_source" name.
      await seedFile(
          path: '/srcA/old name.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-old',
          contentHash: 'ch-bytes',
          uid: 'u-old',
          state: 'missing');
      await seedFile(
          path: '/srcA/new name.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-new',
          contentHash: 'ch-bytes',
          uid: 'u-new');
      await repo.markCrossSourceMoves();
      expect(await stateOf('/srcA/old name.mp3'), 'superseded');

      final events = await repo.loadRecentEvents();
      final supEvents = events
          .where((e) =>
              e.eventType == 'auto_move_same_source' ||
              e.eventType == 'auto_move_cross_source')
          .toList();
      expect(supEvents, hasLength(1));
      expect(supEvents.first.eventType, 'auto_move_same_source',
          reason:
              'successor is in the same source — narrate as same-source');
      expect(supEvents.first.payload['matched_on'], 'content_hash');
    });

    test('rename in same source → intel_uid migrates to successor',
        () async {
      // The behavioural-intel preservation contract for renames.
      // Without this migration the user's plays/favorites/review
      // state would silently disconnect from the renamed file.
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-old',
          contentHash: 'ch-bytes',
          uid: 'u-old',
          state: 'missing',
          intelUid: 'intel-X');
      await seedFile(
          path: '/srcA/new.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-new',
          contentHash: 'ch-bytes',
          uid: 'u-new');
      // Successor explicitly has intel_uid = NULL (its seedFile
      // call didn't pass one).

      await repo.markCrossSourceMoves();

      final row = await raw.query(
        'indexed_files',
        columns: ['intel_uid'],
        where: 'path = ?',
        whereArgs: ['/srcA/new.mp3'],
        limit: 1,
      );
      expect(row.first['intel_uid'], 'intel-X',
          reason:
              'intel from the superseded row must follow to the '
              'available successor across the rename');
    });

    test(
        'cross-source move → event narrates as auto_move_cross_source + intel migrates',
        () async {
      await seedFile(
          path: '/srcA/song.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-1',
          contentHash: 'ch-bytes',
          uid: 'u-old',
          state: 'missing',
          intelUid: 'intel-Y');
      await seedFile(
          path: '/srcB/song.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp-2',
          contentHash: 'ch-bytes',
          uid: 'u-new');

      await repo.markCrossSourceMoves();

      final events = await repo.loadRecentEvents();
      final supEvents = events
          .where((e) =>
              e.eventType == 'auto_move_same_source' ||
              e.eventType == 'auto_move_cross_source')
          .toList();
      expect(supEvents, hasLength(1));
      expect(supEvents.first.eventType, 'auto_move_cross_source');
      expect(supEvents.first.payload['successor_source_id'], 'srcB');

      final row = await raw.query(
        'indexed_files',
        columns: ['intel_uid'],
        where: 'path = ?',
        whereArgs: ['/srcB/song.mp3'],
        limit: 1,
      );
      expect(row.first['intel_uid'], 'intel-Y');
    });

    test(
        'successor that ALREADY has intel_uid is NOT overwritten',
        () async {
      // Safety guard. If the available successor was already
      // linked to some intel (e.g., via fingerprint reconnect on
      // an earlier scan, or via the in-app Copy operation that
      // shares intel deliberately), the migration must not
      // silently overwrite it — that would bridge two unrelated
      // intel rows.
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-old',
          contentHash: 'ch-bytes',
          uid: 'u-old',
          state: 'missing',
          intelUid: 'intel-MIGRATE');
      await seedFile(
          path: '/srcA/new.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-new',
          contentHash: 'ch-bytes',
          uid: 'u-new',
          intelUid: 'intel-EXISTING');

      await repo.markCrossSourceMoves();

      final row = await raw.query(
        'indexed_files',
        columns: ['intel_uid'],
        where: 'path = ?',
        whereArgs: ['/srcA/new.mp3'],
        limit: 1,
      );
      expect(row.first['intel_uid'], 'intel-EXISTING',
          reason: 'existing intel_uid on successor must be preserved');
    });

    test('markCrossSourceMoves is idempotent across repeated calls', () async {
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-old');
      await seedFile(
          path: '/srcB/x.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          uid: 'u-new');
      await simulateScan('srcA', {});
      // First call resolves it.
      expect(await stateOf('/srcA/x.mp3'), 'superseded');
      // Subsequent calls are no-ops; state stays superseded
      // (does NOT churn back to missing).
      for (var i = 0; i < 3; i++) {
        final n = await repo.markCrossSourceMoves();
        expect(n, 0);
        expect(await stateOf('/srcA/x.mp3'), 'superseded');
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // CATEGORY 3 — Variant semantics.
  // Availability layer's interaction with the song-identity layer.
  // The two layers should remain INDEPENDENT.
  // ───────────────────────────────────────────────────────────────────
  group('3. Variant semantics', () {
    test('one variant missing: other variant unaffected (different fp, no supersession)',
        () async {
      await seedFile(
          path: '/srcA/song.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-mp3',
          uid: 'u-mp3');
      await seedFile(
          path: '/srcA/song.aiff',
          sourceId: 'srcA',
          fingerprint: 'fp-aiff',
          uid: 'u-aiff');
      await simulateScan('srcA', {'/srcA/song.mp3'});
      expect(await stateOf('/srcA/song.mp3'), 'available');
      expect(await stateOf('/srcA/song.aiff'), 'missing');
    });

    test('all variants missing: each row → missing, intel row preserved', () async {
      await seedFile(
          path: '/srcA/song.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-mp3',
          uid: 'u-mp3',
          intelUid: 'intel-1');
      await seedFile(
          path: '/srcA/song.aiff',
          sourceId: 'srcA',
          fingerprint: 'fp-aiff',
          uid: 'u-aiff',
          intelUid: 'intel-1');
      await raw.insert('tracks', {
        'uid': 'intel-1',
        'fingerprint': 'fp-mp3',
        'created_at': 0,
        'favorite': 1,
        'play_count': 7,
        'cumulative_ms': 60000,
        'last_played_at': null,
      });
      await simulateScan('srcA', {});
      expect(await stateOf('/srcA/song.mp3'), 'missing');
      expect(await stateOf('/srcA/song.aiff'), 'missing');
      final rows =
          await raw.query('tracks', where: 'uid = ?', whereArgs: ['intel-1']);
      expect(rows, hasLength(1));
      expect(rows.first['play_count'], 7);
      expect(rows.first['favorite'], 1);
    });

    test('availability transition does NOT touch intel_uid (layer independence)',
        () async {
      // Going missing must not unlink a variant from its song
      // identity. When the file returns it must still be the
      // same song.
      await seedFile(
          path: '/srcA/song.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-mp3',
          uid: 'u-mp3',
          intelUid: 'intel-1');
      await simulateScan('srcA', {});
      final after = await raw.query(
        'indexed_files',
        columns: ['intel_uid'],
        where: 'path = ?',
        whereArgs: ['/srcA/song.mp3'],
        limit: 1,
      );
      expect(after.first['intel_uid'], 'intel-1');
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // CATEGORY 4 — Scan race conditions.
  // Probes where the current state set produces incorrect intermediates.
  // ───────────────────────────────────────────────────────────────────
  group('4. Scan race conditions', () {
    test('repeated scans on stable library: states do not flap', () async {
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-x');
      for (var i = 0; i < 3; i++) {
        await simulateScan('srcA', {'/srcA/x.mp3'});
      }
      expect(await stateOf('/srcA/x.mp3'), 'available');
    });

    test(
        'RED: partial/interrupted scan (only some paths seen) flips unseen rows to missing on a single pass — should require multi-scan confirmation',
        () async {
      // DESIGN QUESTION: A scan that crashes or gets cancelled
      // halfway emits a partial seenPaths set. Currently every
      // unseen path immediately becomes 'missing' — the UI then
      // surfaces them in the Review dialog as candidates to
      // purge. That's a false alarm.
      //
      // Hypothesis (matrix-as-spec): `missing` should split:
      //   - 'transient_missing' — first scan to miss it
      //   - 'missing' (durable) — confirmed missing across N
      //     consecutive scans, or after a successful full-source
      //     pass
      // Until that split exists, a single partial scan can pollute
      // the missing tally. Pin this test as the spec for what the
      // *desired* behavior should be once the state set grows.
      await seedFile(
          path: '/srcA/a.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-a',
          uid: 'u-a');
      await seedFile(
          path: '/srcA/b.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-b',
          uid: 'u-b');
      // Scanner only reports a.mp3 — interrupted before reaching b.
      await simulateScan('srcA', {'/srcA/a.mp3'});
      // CURRENT BEHAVIOR (green here): b is wrongly 'missing'.
      // DESIRED BEHAVIOR (red): b should stay 'available' (or land
      // in a transient bucket) on the first partial pass. Until
      // transient_missing exists, this assertion documents the
      // gap; flip it when the new state lands.
      expect(await stateOf('/srcA/b.mp3'), 'missing'); // current
      // expect(await stateOf('/srcA/b.mp3'), isNot('missing')); // desired
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // CATEGORY 5 — Future orchestration prep.
  // The app does not yet orchestrate moves/copies/deletes itself.
  // These tests pin the contract we want once the API exists, and
  // act as a checklist for what's missing.
  // ───────────────────────────────────────────────────────────────────
  group('5. Future orchestration prep', () {
    test(
        'purgeIndexedFiles hard-deletes today (no `deleted` tombstone state)',
        () async {
      // Pinning current behavior. Whether `deleted` should be a
      // tombstone state vs just absence is an open design question.
      // Argument for tombstone: audit trail, undo, "did I purge
      // this on purpose?" Argument against: clutter, eventually
      // every long-running library accumulates them.
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-x',
          state: 'missing');
      await repo.purgeIndexedFiles(['/srcA/x.mp3']);
      expect(await rowExists('/srcA/x.mp3'), isFalse);
      // RED alternative — if we adopt tombstones:
      //   expect(await stateOf('/srcA/x.mp3'), 'deleted');
      //   expect(await rowExists('/srcA/x.mp3'), isTrue);
    });

    test(
        'purge then re-scan with same fp: intel survives via fingerprint reconnect',
        () async {
      // Today's resurrection contract: tracks rows are never
      // touched by purge, so when the file reappears (same fp)
      // reconnectIntelligenceBySource re-links it. Verifying the
      // full cycle. If a future `deleted` tombstone state ships,
      // this contract must still hold.
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-x',
          intelUid: 'intel-1');
      await raw.insert('tracks', {
        'uid': 'intel-1',
        'fingerprint': 'fp1',
        'created_at': 0,
        'favorite': 1,
        'play_count': 11,
        'cumulative_ms': 0,
        'last_played_at': null,
      });
      await repo.purgeIndexedFiles(['/srcA/x.mp3']);
      // tracks row is untouched.
      final tr = await raw.query('tracks', where: 'uid = ?', whereArgs: ['intel-1']);
      expect(tr, hasLength(1));
      // File reappears at the same path with same fp.
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          uid: 'u-x');
      await repo.reconnectIntelligenceBySource('srcA');
      final after = await raw.query('indexed_files',
          columns: ['intel_uid'],
          where: 'path = ?',
          whereArgs: ['/srcA/x.mp3']);
      expect(after.first['intel_uid'], 'intel-1');
    });

    test('TODO: app-initiated move via moveFile(old, new)', () {
      // No moveFile API on the repo yet. Once it ships, expected:
      //   - new path becomes 'available'
      //   - old path is PURGED (not marked 'superseded') because
      //     the app knows it caused the move — no ghost needed
      //   - intel_uid carries over to the new row
      //   - DB write + FS rename are transactional
      // Without an API there is nothing to assert against.
    }, skip: 'No moveFile API yet — see project_file_availability_state_machine.md');

    test('TODO: app-initiated copy via copyFile(src, dst)', () {
      // Once it ships:
      //   - dst row 'available'
      //   - dst.intel_uid = src.intel_uid (variant attached on
      //     creation, not via post-hoc consolidate)
      //   - src untouched
    }, skip: 'No copyFile API yet');

    test('TODO: source_offline (source-level, not per-file)', () {
      // Hypothesis from Category 2: source_offline belongs on
      // the `sources` table, not on `indexed_files`. Once added:
      //   - marking a source offline does NOT mutate any
      //     indexed_files row's availability_state
      //   - reads filter offline sources out of the active table
      //     but do not lose intel
      //   - bringing it back online resumes normal scan semantics
    }, skip: 'No sources.offline column yet — hypothesis still pending');
  });
}

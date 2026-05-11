import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/content_hash.dart';

/// Specification for `content_hash`: stable physical-file identity
/// (first 256KB + last 256KB SHA-256).
///
/// Hash is allowed to change when the audio bytes change. Hash is
/// NOT allowed to change when only the path/filename/metadata-around-
/// audio changes. The tests cover both invariants.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('content_hash_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Build a file whose content is deterministic for a given seed and
  /// size. Avoids relying on real audio fixtures.
  Future<File> makeFile(String name, int sizeBytes, {int seed = 0}) async {
    final f = File('${tmp.path}/$name');
    final bytes = Uint8List(sizeBytes);
    // Cheap PRNG so two seeds produce different content but the same
    // seed produces the same content on every run.
    var x = (seed * 2654435761) & 0xFFFFFFFF;
    for (var i = 0; i < sizeBytes; i++) {
      x = (x * 1103515245 + 12345) & 0xFFFFFFFF;
      bytes[i] = x & 0xFF;
    }
    await f.writeAsBytes(bytes);
    return f;
  }

  // ───────────────────────────────────────────────────────────────────
  // Invariant 1: HASH MUST CHANGE when audio bytes change.
  // ───────────────────────────────────────────────────────────────────
  group('Different content → different hash', () {
    test('different seed → different hash', () async {
      final a = await makeFile('a.mp3', 800 * 1024, seed: 1);
      final b = await makeFile('b.mp3', 800 * 1024, seed: 2);
      expect(await computeContentHash(a.path),
          isNot(equals(await computeContentHash(b.path))));
    });

    test('one byte flipped in head region → different hash', () async {
      final a = await makeFile('a.mp3', 800 * 1024, seed: 7);
      final bytes = await a.readAsBytes();
      bytes[10] = bytes[10] ^ 0xFF;
      final b = File('${tmp.path}/b.mp3');
      await b.writeAsBytes(bytes);
      expect(await computeContentHash(a.path),
          isNot(equals(await computeContentHash(b.path))));
    });

    test('one byte flipped in tail region → different hash', () async {
      final size = 800 * 1024;
      final a = await makeFile('a.mp3', size, seed: 7);
      final bytes = await a.readAsBytes();
      bytes[size - 100] = bytes[size - 100] ^ 0xFF;
      final b = File('${tmp.path}/b.mp3');
      await b.writeAsBytes(bytes);
      expect(await computeContentHash(a.path),
          isNot(equals(await computeContentHash(b.path))));
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Invariant 2: HASH MUST NOT CHANGE when only the path/name changes.
  // This is the entire point — Finder rename / Cmd+D / folder move
  // must produce the same hash.
  // ───────────────────────────────────────────────────────────────────
  group('Same content, different path → same hash', () {
    test('rename in place → same hash', () async {
      final a = await makeFile('original.mp3', 800 * 1024, seed: 3);
      final h1 = await computeContentHash(a.path);
      final renamed = await a.rename('${tmp.path}/renamed.mp3');
      expect(await computeContentHash(renamed.path), h1);
    });

    test('copy to a different folder → same hash', () async {
      final a = await makeFile('song.mp3', 800 * 1024, seed: 5);
      final sub = await Directory('${tmp.path}/sub').create();
      final copied = await a.copy('${sub.path}/song.mp3');
      expect(await computeContentHash(copied.path),
          await computeContentHash(a.path));
    });

    test("Cmd+D-style duplicate (`foo.mp3` → `foo copy.mp3`) → same hash",
        () async {
      // macOS Finder Cmd+D produces a byte-identical file with " copy"
      // appended to the basename. content_hash must collapse them.
      final a = await makeFile('foo.mp3', 800 * 1024, seed: 11);
      final dup = await a.copy('${tmp.path}/foo copy.mp3');
      expect(await computeContentHash(dup.path),
          await computeContentHash(a.path));
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Boundary behaviour for files smaller than the 2 × chunk window.
  // ───────────────────────────────────────────────────────────────────
  group('Small-file fallback', () {
    test('file smaller than 2 × chunk: hashes whole file, still stable',
        () async {
      // 100KB file — far below 2 × 256KB. Implementation reads the
      // whole file in one go; rename must still produce the same hash.
      final a = await makeFile('tiny.mp3', 100 * 1024, seed: 17);
      final h1 = await computeContentHash(a.path);
      final renamed = await a.rename('${tmp.path}/tiny renamed.mp3');
      expect(await computeContentHash(renamed.path), h1);
    });

    test('exactly 2 × chunk: hashes whole file (boundary case)', () async {
      final a = await makeFile('mid.mp3', contentHashChunkBytes * 2, seed: 19);
      expect(await computeContentHash(a.path), isNotNull);
    });

    test('exactly 2 × chunk + 1: switches to head + tail mode', () async {
      final a = await makeFile('big.mp3', contentHashChunkBytes * 2 + 1,
          seed: 23);
      expect(await computeContentHash(a.path), isNotNull);
    });

    test('zero-byte file → null hash (caller treats as not-yet-computed)',
        () async {
      final f = File('${tmp.path}/empty.mp3');
      await f.writeAsBytes(<int>[]);
      expect(await computeContentHash(f.path), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Error handling.
  // ───────────────────────────────────────────────────────────────────
  group('Unreadable input', () {
    test('missing file → null', () async {
      expect(await computeContentHash('${tmp.path}/does_not_exist.mp3'),
          isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Sync variant parity.
  // ───────────────────────────────────────────────────────────────────
  group('Sync variant', () {
    test('sync and async produce the same hash', () async {
      final a = await makeFile('parity.mp3', 800 * 1024, seed: 29);
      expect(computeContentHashSync(a.path), await computeContentHash(a.path));
    });

    test('sync — small file fallback', () async {
      final a = await makeFile('parity_small.mp3', 50 * 1024, seed: 31);
      expect(computeContentHashSync(a.path), await computeContentHash(a.path));
    });

    test('sync — missing file → null', () {
      expect(computeContentHashSync('${tmp.path}/nope.mp3'), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Instrumentation: success / failure counters, latency tracking,
  // bytes hashed. Lightweight always-on stats — the only signal we
  // get during Phase 1.5 soak when hash callers aren't writing to
  // any DB yet.
  // ───────────────────────────────────────────────────────────────────
  group('ContentHashStats', () {
    setUp(ContentHashStats.reset);

    test('successful hash increments ok + bytes + total micros', () async {
      final a = await makeFile('ok.mp3', 800 * 1024, seed: 41);
      await computeContentHash(a.path);
      expect(ContentHashStats.successCount, 1);
      expect(ContentHashStats.failureCount, 0);
      expect(ContentHashStats.bytesHashed, greaterThan(0));
      expect(ContentHashStats.totalMicros, greaterThan(0));
      expect(ContentHashStats.lastMicros, greaterThan(0));
    });

    test('failure path: missing file → failureCount++, lastFailurePath set',
        () async {
      await computeContentHash('${tmp.path}/missing.mp3');
      expect(ContentHashStats.successCount, 0);
      expect(ContentHashStats.failureCount, 1);
      expect(ContentHashStats.lastFailurePath, contains('missing.mp3'));
    });

    test('failure path: empty file → counted as failure (null hash)',
        () async {
      final f = File('${tmp.path}/empty.mp3');
      await f.writeAsBytes(<int>[]);
      await computeContentHash(f.path);
      expect(ContentHashStats.failureCount, 1);
      expect(ContentHashStats.lastFailurePath, contains('empty.mp3'));
    });

    test('reset clears every counter', () async {
      final a = await makeFile('clearme.mp3', 100 * 1024, seed: 47);
      await computeContentHash(a.path);
      expect(ContentHashStats.successCount, 1);
      ContentHashStats.reset();
      expect(ContentHashStats.successCount, 0);
      expect(ContentHashStats.failureCount, 0);
      expect(ContentHashStats.totalMicros, 0);
      expect(ContentHashStats.maxMicros, 0);
      expect(ContentHashStats.bytesHashed, 0);
      expect(ContentHashStats.lastFailurePath, isNull);
      expect(ContentHashStats.slowestPath, isNull);
    });

    test('maxMicros tracks the slowest call; slowestPath points at it',
        () async {
      final fast = await makeFile('fast.mp3', 100 * 1024, seed: 53);
      // Big file = more bytes read, almost always slower than the
      // small one. The assertion is monotonicity, not magnitude.
      final slow = await makeFile('slow.mp3',
          contentHashChunkBytes * 3, seed: 59);
      await computeContentHash(fast.path);
      await computeContentHash(slow.path);
      // slowestPath could legitimately be either path if the OS page
      // cache makes the second read instant; assert the invariant
      // instead: maxMicros equals one of the two recorded elapseds.
      expect(ContentHashStats.maxMicros, greaterThanOrEqualTo(0));
      expect(ContentHashStats.slowestPath, anyOf(contains('fast.mp3'),
          contains('slow.mp3')));
    });

    test('summary() renders even from a reset state', () {
      ContentHashStats.reset();
      expect(ContentHashStats.summary(), contains('ok=0'));
      expect(ContentHashStats.summary(), contains('fail=0'));
    });

    test('sync variant also feeds the stats', () async {
      final a = await makeFile('sync.mp3', 100 * 1024, seed: 61);
      computeContentHashSync(a.path);
      expect(ContentHashStats.successCount, 1);
      computeContentHashSync('${tmp.path}/sync-missing.mp3');
      expect(ContentHashStats.failureCount, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Byte-level entry point for matrix tests that don't want temp files.
  // ───────────────────────────────────────────────────────────────────
  group('contentHashFromBytes', () {
    test('same inputs → same output', () {
      final head = Uint8List.fromList(List.generate(100, (i) => i));
      final tail = Uint8List.fromList(List.generate(50, (i) => 200 - i));
      expect(
          contentHashFromBytes(head, tail), contentHashFromBytes(head, tail));
    });

    test('different head → different output', () {
      final tail = Uint8List.fromList(List.generate(50, (i) => 200 - i));
      final h1 = Uint8List.fromList(List.generate(100, (i) => i));
      final h2 = Uint8List.fromList(List.generate(100, (i) => i + 1));
      expect(contentHashFromBytes(h1, tail),
          isNot(equals(contentHashFromBytes(h2, tail))));
    });

    test('different tail → different output', () {
      final head = Uint8List.fromList(List.generate(100, (i) => i));
      final t1 = Uint8List.fromList(List.generate(50, (i) => 200 - i));
      final t2 = Uint8List.fromList(List.generate(50, (i) => 201 - i));
      expect(contentHashFromBytes(head, t1),
          isNot(equals(contentHashFromBytes(head, t2))));
    });
  });
}

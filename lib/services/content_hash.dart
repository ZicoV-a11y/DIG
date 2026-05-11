import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Stable physical-file identity. Reads up to [_chunkBytes] from the
/// start of the file and up to [_chunkBytes] from the end, concatenates
/// the two byte ranges, and returns `sha256(chunks)` as a hex string.
///
/// This replaces the legacy `fingerprint` (basename + filesize + duration
/// SHA-256), which conflated **heuristic similarity** with **content
/// identity**. The legacy hash broke on any rename — including Finder
/// Cmd+D's `… copy.mp3` suffix — even when the audio bytes were
/// identical. content_hash survives:
///   - rename
///   - folder move
///   - ID3 / Vorbis tag edits (covered by hashing both ends; tag blocks
///     cluster at file head AND tail, so edits to either still flip the
///     hash if they reach into the chunk window — but pure rename
///     leaves both windows untouched)
///   - source relocation
///   - Cmd+D copies that produce byte-identical files
///
/// And still distinguishes:
///   - different masters / edits / transcodes / renders
///   - re-encodes that change audio bytes
///   - format conversions (different byte layout in the chunk window)
///
/// **NOT** used for behavioural state mutations yet. Phase 1 only
/// populates the column. Supersession, intel transfer, ghost cleanup,
/// and auto-merge continue to consume the legacy `fingerprint` until a
/// later phase wires content_hash in as the authority.
///
/// See `project_content_hash_separation.md` in project memory.

/// Bytes read from each end of the file.
const int _chunkBytes = 256 * 1024;

/// A hash slower than this threshold (microseconds) gets a one-line
/// debug log so external SSDs, NAS volumes, or slow-Dropbox cases
/// surface in console output without needing a histogram. 200 ms
/// — fast SSD reads of 512 KB are typically <10 ms; anything beyond
/// 200 ms is worth a look.
const int _slowHashMicros = 200 * 1000;

/// Lightweight, always-on instrumentation for the hashing pipeline.
/// Counters + max latency only — no histograms, no per-call
/// allocations. Cost is a few field writes; safe to leave enabled
/// in release builds.
///
/// Process-wide singleton state — single-isolate use only for now;
/// revisit if hashing ever moves to a background isolate.
class ContentHashStats {
  static int _ok = 0;
  static int _fail = 0;
  static int _totalMicros = 0;
  static int _maxMicros = 0;
  static int _lastMicros = 0;
  static int _bytesHashed = 0;
  static String? _lastFailurePath;
  static String? _slowestPath;

  static int get successCount => _ok;
  static int get failureCount => _fail;
  static int get totalCount => _ok + _fail;
  static int get totalMicros => _totalMicros;
  static int get maxMicros => _maxMicros;
  static int get lastMicros => _lastMicros;
  static int get bytesHashed => _bytesHashed;
  static String? get lastFailurePath => _lastFailurePath;
  static String? get slowestPath => _slowestPath;
  static double get meanMs =>
      _ok == 0 ? 0.0 : (_totalMicros / _ok) / 1000.0;

  static void reset() {
    _ok = 0;
    _fail = 0;
    _totalMicros = 0;
    _maxMicros = 0;
    _lastMicros = 0;
    _bytesHashed = 0;
    _lastFailurePath = null;
    _slowestPath = null;
  }

  /// One-line human-readable summary. Hand to debugPrint at scan
  /// boundaries or backfill checkpoints.
  static String summary() =>
      '[content_hash] ok=$_ok fail=$_fail '
      'mean=${meanMs.toStringAsFixed(1)}ms '
      'max=${(_maxMicros / 1000).toStringAsFixed(1)}ms '
      'bytes=${(_bytesHashed / 1024 / 1024).toStringAsFixed(1)}MB';

  static void _recordSuccess(int micros, int bytes, String path) {
    _ok++;
    _totalMicros += micros;
    _lastMicros = micros;
    if (micros > _maxMicros) {
      _maxMicros = micros;
      _slowestPath = path;
    }
    _bytesHashed += bytes;
    if (micros > _slowHashMicros) {
      debugPrint(
        '[content_hash] slow: ${(micros / 1000).toStringAsFixed(0)}ms · $path',
      );
    }
  }

  static void _recordFailure(String path) {
    _fail++;
    _lastFailurePath = path;
  }
}

/// Compute the content hash for the file at [path].
///
/// Returns `null` if the file is unreadable (missing, permission
/// denied, etc.). Callers should treat null as "leave content_hash
/// column null and re-try on a future scan" — never as a sentinel
/// value that ends up in the DB.
///
/// Pure I/O + crypto; safe to call from a background isolate.
Future<String?> computeContentHash(String path) async {
  final start = DateTime.now().microsecondsSinceEpoch;
  try {
    final file = File(path);
    final length = await file.length();
    if (length <= 0) {
      ContentHashStats._recordFailure(path);
      return null;
    }
    final bytes = await _readChunks(file, length);
    final hash = _hash(bytes);
    final elapsed = DateTime.now().microsecondsSinceEpoch - start;
    ContentHashStats._recordSuccess(elapsed, bytes.length, path);
    return hash;
  } on FileSystemException {
    ContentHashStats._recordFailure(path);
    return null;
  }
}

/// Synchronous variant. Useful in the scan upsert path where we
/// already hold a stat'd file and don't want to add another async hop.
String? computeContentHashSync(String path) {
  final start = DateTime.now().microsecondsSinceEpoch;
  try {
    final file = File(path);
    final length = file.lengthSync();
    if (length <= 0) {
      ContentHashStats._recordFailure(path);
      return null;
    }
    final bytes = _readChunksSync(file, length);
    final hash = _hash(bytes);
    final elapsed = DateTime.now().microsecondsSinceEpoch - start;
    ContentHashStats._recordSuccess(elapsed, bytes.length, path);
    return hash;
  } on FileSystemException {
    ContentHashStats._recordFailure(path);
    return null;
  }
}

/// Test-only entry point: compute the hash from a raw byte sequence.
/// Lets the matrix prove that two paths with byte-identical content
/// produce the same hash without writing temp files, and that any
/// flipped byte in the chunk window produces a different hash.
String contentHashFromBytes(Uint8List head, Uint8List tail) {
  // Caller is responsible for trimming to <= _chunkBytes per side.
  final builder = BytesBuilder(copy: false)
    ..add(head)
    ..add(tail);
  return _hash(builder.toBytes());
}

/// Number of bytes hashed per side. Exposed for tests + diagnostics.
int get contentHashChunkBytes => _chunkBytes;

Future<Uint8List> _readChunks(File file, int length) async {
  // Files smaller than 2 * chunkBytes get read in full — there's no
  // distinct "tail" region, and hashing the whole file is cheaper than
  // two seeks. This also avoids head/tail overlap counting bytes twice.
  if (length <= _chunkBytes * 2) {
    return await file.readAsBytes();
  }
  final raf = await file.open();
  try {
    final head = await raf.read(_chunkBytes);
    await raf.setPosition(length - _chunkBytes);
    final tail = await raf.read(_chunkBytes);
    final builder = BytesBuilder(copy: false)
      ..add(head)
      ..add(tail);
    return builder.toBytes();
  } finally {
    await raf.close();
  }
}

Uint8List _readChunksSync(File file, int length) {
  if (length <= _chunkBytes * 2) {
    return file.readAsBytesSync();
  }
  final raf = file.openSync();
  try {
    final head = raf.readSync(_chunkBytes);
    raf.setPositionSync(length - _chunkBytes);
    final tail = raf.readSync(_chunkBytes);
    final builder = BytesBuilder(copy: false)
      ..add(head)
      ..add(tail);
    return builder.toBytes();
  } finally {
    raf.closeSync();
  }
}

String _hash(Uint8List bytes) => sha256.convert(bytes).toString();

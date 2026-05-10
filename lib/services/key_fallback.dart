import 'dart:convert';
import 'dart:io';

/// Minimal embedded-ID3v2 + Vorbis-comment scanner used **only**
/// when the high-level [audio_metadata_reader] doesn't surface a
/// musical key for the file.
///
/// Why this exists: `RiffMetadata` (returned for AIFF/WAV) and
/// `VorbisMetadata` (returned for FLAC) intentionally omit the
/// initial-key field, so even when those formats embed an ID3v2
/// chunk with a valid `TKEY` frame, the package quietly drops it.
/// We re-open the file, locate the chunk ourselves, and pull just
/// the key value. Everything else (title, artist, album, …) keeps
/// going through the package as normal.
///
/// All operations are isolate-safe sync I/O over a small,
/// bounded read window.
class KeyFallback {
  /// Try to extract a musical key from a non-MP3 audio file.
  /// Returns `null` if no key was found or the file isn't a
  /// supported container.
  static String? read(String path) {
    final file = File(path);
    RandomAccessFile? raf;
    try {
      raf = file.openSync(mode: FileMode.read);
      final hdr = raf.readSync(12);
      if (hdr.length < 12) return null;
      final formId = _ascii(hdr, 0, 4);
      if (formId == 'FORM') {
        // AIFF / AIFC: chunk sizes are big-endian.
        return _scanRiff(raf, _bigEndian, _ascii(hdr, 8, 4));
      }
      if (formId == 'RIFF') {
        // WAV: chunk sizes are little-endian.
        return _scanRiff(raf, _littleEndian, _ascii(hdr, 8, 4));
      }
      if (formId == 'fLaC') {
        return _scanFlac(raf);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  // ---------- RIFF / AIFF ----------

  /// Iterate top-level chunks looking for an `ID3 ` chunk. Inside
  /// it, find the `TKEY` frame and decode the text.
  static String? _scanRiff(
    RandomAccessFile raf,
    int Function(List<int> bytes, int offset) endian,
    String containerType,
  ) {
    if (containerType != 'AIFF' &&
        containerType != 'AIFC' &&
        containerType != 'WAVE') {
      return null;
    }
    final length = raf.lengthSync();
    var pos = 12;
    while (pos + 8 <= length) {
      raf.setPositionSync(pos);
      final hdr = raf.readSync(8);
      if (hdr.length < 8) break;
      final chunkId = _ascii(hdr, 0, 4);
      final chunkSize = endian(hdr, 4);
      if (chunkSize < 0 || pos + 8 + chunkSize > length) break;
      if (chunkId == 'ID3 ' || chunkId == 'id3 ') {
        raf.setPositionSync(pos + 8);
        final id3 = raf.readSync(chunkSize);
        return _findTkeyInId3(id3);
      }
      // RIFF chunks are zero-padded to even byte alignment.
      var advance = 8 + chunkSize;
      if (advance.isOdd) advance += 1;
      pos += advance;
    }
    return null;
  }

  /// Parse an ID3v2 payload (header + frames) and return the
  /// `TKEY` frame's text content, if present.
  static String? _findTkeyInId3(List<int> bytes) {
    if (bytes.length < 10) return null;
    if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) {
      return null; // not "ID3"
    }
    final majorVersion = bytes[3];
    if (majorVersion < 2 || majorVersion > 4) return null;
    final flags = bytes[5];
    final hasExtendedHeader = (flags & 0x40) != 0;
    final tagSize = _syncSafeUint32(bytes, 6);
    if (tagSize <= 0 || tagSize + 10 > bytes.length) return null;

    var pos = 10;
    if (hasExtendedHeader && majorVersion >= 3 && pos + 4 <= bytes.length) {
      final extSize = majorVersion == 4
          ? _syncSafeUint32(bytes, pos)
          : _bigEndian(bytes, pos);
      pos += extSize + 4;
    }

    final end = 10 + tagSize;
    while (pos + 10 <= end && pos + 10 <= bytes.length) {
      final frameId = _ascii(bytes, pos, 4);
      if (frameId.codeUnitAt(0) == 0) break; // padding
      final frameSize = majorVersion == 4
          ? _syncSafeUint32(bytes, pos + 4)
          : _bigEndian(bytes, pos + 4);
      if (frameSize < 0 || pos + 10 + frameSize > bytes.length) break;
      if (frameId == 'TKEY' && frameSize >= 1) {
        final encoding = bytes[pos + 10];
        final text = bytes.sublist(pos + 11, pos + 10 + frameSize);
        final decoded = _decodeId3Text(encoding, text);
        if (decoded.isNotEmpty) return decoded;
      }
      pos += 10 + frameSize;
    }
    return null;
  }

  // ---------- FLAC (Vorbis comments) ----------

  /// Scan a FLAC file's metadata blocks for the Vorbis-comment
  /// block, then look for an `INITIALKEY` (or `KEY`) entry.
  static String? _scanFlac(RandomAccessFile raf) {
    raf.setPositionSync(4); // skip "fLaC" magic
    while (true) {
      final hdr = raf.readSync(4);
      if (hdr.length < 4) return null;
      final isLast = (hdr[0] & 0x80) != 0;
      final blockType = hdr[0] & 0x7F;
      final blockSize = (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
      if (blockType == 4) {
        // VORBIS_COMMENT
        final body = raf.readSync(blockSize);
        return _findKeyInVorbisComments(body);
      }
      raf.setPositionSync(raf.positionSync() + blockSize);
      if (isLast) return null;
    }
  }

  static String? _findKeyInVorbisComments(List<int> bytes) {
    if (bytes.length < 4) return null;
    var pos = 0;
    final vendorLen = _littleEndian(bytes, pos);
    pos += 4 + vendorLen;
    if (pos + 4 > bytes.length) return null;
    final commentCount = _littleEndian(bytes, pos);
    pos += 4;
    for (var i = 0; i < commentCount; i++) {
      if (pos + 4 > bytes.length) return null;
      final len = _littleEndian(bytes, pos);
      pos += 4;
      if (len < 0 || pos + len > bytes.length) return null;
      final entry = utf8.decode(
        bytes.sublist(pos, pos + len),
        allowMalformed: true,
      );
      pos += len;
      final eq = entry.indexOf('=');
      if (eq <= 0) continue;
      final key = entry.substring(0, eq).toUpperCase();
      if (key == 'INITIALKEY' || key == 'KEY') {
        final value = entry.substring(eq + 1).trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  // ---------- helpers ----------

  static int _bigEndian(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _littleEndian(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  /// Sync-safe 28-bit integer (each byte's high bit is 0).
  static int _syncSafeUint32(List<int> b, int o) =>
      ((b[o] & 0x7F) << 21) |
      ((b[o + 1] & 0x7F) << 14) |
      ((b[o + 2] & 0x7F) << 7) |
      (b[o + 3] & 0x7F);

  static String _ascii(List<int> b, int o, int n) =>
      String.fromCharCodes(b.sublist(o, o + n));

  /// Decode an ID3v2 text frame's bytes given its encoding byte.
  /// 0 = ISO-8859-1, 1 = UTF-16 with BOM, 2 = UTF-16BE, 3 = UTF-8.
  static String _decodeId3Text(int encoding, List<int> bytes) {
    // Strip a single trailing terminator byte (or two for UTF-16).
    var end = bytes.length;
    if ((encoding == 1 || encoding == 2) &&
        end >= 2 &&
        bytes[end - 1] == 0 &&
        bytes[end - 2] == 0) {
      end -= 2;
    } else if (end >= 1 && bytes[end - 1] == 0) {
      end -= 1;
    }
    final slice = bytes.sublist(0, end);
    try {
      switch (encoding) {
        case 0:
          return latin1.decode(slice, allowInvalid: true).trim();
        case 1:
          return _decodeUtf16WithBom(slice).trim();
        case 2:
          return _decodeUtf16Be(slice).trim();
        case 3:
          return utf8.decode(slice, allowMalformed: true).trim();
      }
    } catch (_) {/* fall through */}
    return '';
  }

  static String _decodeUtf16WithBom(List<int> bytes) {
    if (bytes.length < 2) return '';
    final big = bytes[0] == 0xFE && bytes[1] == 0xFF;
    final little = bytes[0] == 0xFF && bytes[1] == 0xFE;
    final body = (big || little) ? bytes.sublist(2) : bytes;
    return little ? _decodeUtf16Le(body) : _decodeUtf16Be(body);
  }

  static String _decodeUtf16Be(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static String _decodeUtf16Le(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
}

import 'dart:io';

import 'package:crypto/crypto.dart';

/// First-and-last-256KB SHA-256 over the file at [path] —
/// matches the desktop's `contentHash` convention so the phone
/// can verify it received the exact bytes the manifest entry
/// promised.
///
/// Files smaller than 512KB hash the entire content (single
/// read pass). This matches the desktop's same fallback.
///
/// Used by [InventoryService.verifyGeneration] — generation-
/// scoped, never a global cache lookup.
Future<String> computeTransportHash(String path) async {
  const window = 256 * 1024;
  final file = File(path);
  final length = await file.length();

  final raf = await file.open();
  try {
    List<int> bytes;
    if (length <= window * 2) {
      bytes = await raf.read(length);
    } else {
      final head = await raf.read(window);
      await raf.setPosition(length - window);
      final tail = await raf.read(window);
      bytes = [...head, ...tail];
    }
    return sha256.convert(bytes).toString();
  } finally {
    await raf.close();
  }
}

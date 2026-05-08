import 'dart:io';

import 'package:flutter/foundation.dart';

class AudioScanner {
  static const audioExtensions = <String>{
    'mp3',
    'wav',
    'flac',
    'm4a',
    'aiff',
    'aif',
  };

  static Future<List<String>> scan(String rootPath) {
    return compute(_scanInIsolate, rootPath);
  }
}

@pragma('vm:entry-point')
List<String> _scanInIsolate(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) return const [];
  final files = <String>[];
  try {
    for (final entity in root.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final p = entity.path;
      final sepIdx = p.lastIndexOf(Platform.pathSeparator);
      final name = sepIdx < 0 ? p : p.substring(sepIdx + 1);
      if (name.startsWith('.')) continue;
      final dotIdx = name.lastIndexOf('.');
      if (dotIdx <= 0 || dotIdx == name.length - 1) continue;
      final ext = name.substring(dotIdx + 1).toLowerCase();
      if (AudioScanner.audioExtensions.contains(ext)) {
        files.add(p);
      }
    }
  } on FileSystemException {
    // best-effort: ignore inaccessible subtrees and return what we have
  }
  return files;
}

String filenameWithoutExtension(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  final base = sep < 0 ? path : path.substring(sep + 1);
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

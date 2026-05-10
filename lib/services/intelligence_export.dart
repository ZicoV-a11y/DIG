import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/intelligence_record.dart';

/// JSON file format for portable intelligence exports.
///
/// File shape:
/// ```jsonc
/// {
///   "format": "music-tracker.intelligence",
///   "version": 1,
///   "exportedAt": <epoch ms>,
///   "machineLabel": "<optional>",
///   "records": [ IntelligenceRecord, ... ]
/// }
/// ```
///
/// Older versions of the format will be read by future code via the
/// `version` gate. For now, only `version: 1` is accepted.
class IntelligenceExportFile {
  static const String formatTag = 'music-tracker.intelligence';
  static const int version = 1;

  /// Serialise [records] to a pretty-printed JSON file at [filePath].
  /// Creates parent directories as needed. Returns the written file.
  static Future<File> writeTo({
    required String filePath,
    required List<IntelligenceRecord> records,
    String? machineLabel,
  }) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final payload = <String, Object?>{
      'format': formatTag,
      'version': version,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      if (machineLabel != null && machineLabel.isNotEmpty)
        'machineLabel': machineLabel,
      'records': [for (final r in records) r.toJson()],
    };
    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload));
    return file;
  }

  /// Parse [file] and return its records.
  ///
  /// Throws [FormatException] on missing/invalid `format` or `version`,
  /// or any malformed JSON. Individual record parse failures are
  /// collected in [errors] (when supplied) rather than aborting the
  /// whole load — callers may still proceed with the records that did
  /// parse.
  static Future<List<IntelligenceRecord>> readFrom(
    File file, {
    List<String>? errors,
  }) async {
    final raw = await file.readAsString();
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Not a JSON file: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Top-level JSON must be an object');
    }
    final fmt = decoded['format'];
    if (fmt != formatTag) {
      throw FormatException(
        'Not an intelligence export file (format=$fmt; expected $formatTag)',
      );
    }
    final ver = decoded['version'];
    if (ver is! int || ver != version) {
      throw FormatException(
        'Unsupported export version (got $ver; this build supports $version)',
      );
    }
    final list = decoded['records'];
    if (list is! List) {
      throw const FormatException('records must be a JSON array');
    }
    final out = <IntelligenceRecord>[];
    for (var i = 0; i < list.length; i++) {
      final raw = list[i];
      if (raw is! Map<String, Object?>) {
        errors?.add('record[$i] is not an object');
        continue;
      }
      try {
        out.add(IntelligenceRecord.fromJson(raw));
      } on FormatException catch (e) {
        errors?.add('record[$i]: ${e.message}');
      }
    }
    return out;
  }

  /// Resolve the default location: `~/Documents/Music Tracker/`.
  static Future<Directory> defaultExportDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Music Tracker');
    await dir.create(recursive: true);
    return dir;
  }

  /// Stable filename used by the in-app `SAVE` button. Always
  /// overwrites the same file so the user has one canonical
  /// "current state" snapshot they can restore from. The
  /// timestamped variant ([defaultFilename]) is reserved for the
  /// `EXPORT` (picker) path where keeping multiple snapshots
  /// matters (e.g. archiving by date).
  static const canonicalFilename = 'intelligence.json';

  /// Format `intelligence-YYYYMMDD-HHmm.json` for the given moment.
  static String defaultFilename([DateTime? at]) {
    final t = at ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
    return 'intelligence-$stamp.json';
  }
}

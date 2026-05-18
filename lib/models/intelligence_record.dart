/// One row of portable workflow intelligence.
///
/// This is the over-the-wire representation of a `tracks` row plus
/// enough human-readable hints (basename / filesize / durationMs) to
/// inspect an export file by eye. Importers key only on `uid` and
/// `fingerprint`; the human-readable fields are never used to merge.
class IntelligenceRecord {
  final String uid;
  final String fingerprint;
  final String basename;
  final int filesize;
  final int durationMs;
  final int createdAt;
  final bool favorite;
  final int playCount;
  final int cumulativeMs;
  final int? lastPlayedAt;
  final int? reviewedAt;
  final int? favoriteToggledAt;

  const IntelligenceRecord({
    required this.uid,
    required this.fingerprint,
    required this.basename,
    required this.filesize,
    required this.durationMs,
    required this.createdAt,
    required this.favorite,
    required this.playCount,
    required this.cumulativeMs,
    required this.lastPlayedAt,
    this.reviewedAt,
    this.favoriteToggledAt,
  });

  Map<String, Object?> toJson() => {
        'uid': uid,
        'fingerprint': fingerprint,
        'basename': basename,
        'filesize': filesize,
        'durationMs': durationMs,
        'createdAt': createdAt,
        'favorite': favorite,
        'playCount': playCount,
        'cumulativeMs': cumulativeMs,
        'lastPlayedAt': lastPlayedAt,
        if (reviewedAt != null) 'reviewedAt': reviewedAt,
        if (favoriteToggledAt != null) 'favoriteToggledAt': favoriteToggledAt,
      };

  static IntelligenceRecord fromJson(Map<String, Object?> j) {
    final uid = j['uid'];
    if (uid is! String || uid.isEmpty) {
      throw const FormatException('record missing uid');
    }
    final fp = j['fingerprint'];
    if (fp is! String) {
      throw const FormatException('record missing fingerprint');
    }
    return IntelligenceRecord(
      uid: uid,
      fingerprint: fp,
      basename: (j['basename'] as String?) ?? '',
      filesize: _asInt(j['filesize']) ?? 0,
      durationMs: _asInt(j['durationMs']) ?? 0,
      createdAt: _asInt(j['createdAt']) ?? 0,
      favorite: (j['favorite'] as bool?) ?? false,
      playCount: _asInt(j['playCount']) ?? 0,
      cumulativeMs: _asInt(j['cumulativeMs']) ?? 0,
      lastPlayedAt: _asInt(j['lastPlayedAt']),
      reviewedAt: _asInt(j['reviewedAt']),
      favoriteToggledAt: _asInt(j['favoriteToggledAt']),
    );
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Outcome of an import. Counts are mutually exclusive: each input
/// record contributes to exactly one bucket (or `skippedErrors` if
/// it failed to parse).
class ImportSummary {
  final int recordsRead;
  final int mergedByUid;
  final int mergedByFingerprint;
  final int insertedAsGhost;
  final List<String> skippedErrors;

  const ImportSummary({
    required this.recordsRead,
    required this.mergedByUid,
    required this.mergedByFingerprint,
    required this.insertedAsGhost,
    required this.skippedErrors,
  });
}

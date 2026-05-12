import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

import 'key_fallback.dart';

class TrackMetadata {
  final String path;
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final String? musicalKey;
  final double? bpm;
  final Duration? duration;
  final bool hasArtwork;
  final bool readSucceeded;

  const TrackMetadata({
    required this.path,
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.musicalKey,
    this.bpm,
    this.duration,
    this.hasArtwork = false,
    this.readSucceeded = true,
  });

  const TrackMetadata.empty(this.path)
      : title = null,
        artist = null,
        album = null,
        genre = null,
        musicalKey = null,
        bpm = null,
        duration = null,
        hasArtwork = false,
        readSucceeded = false;
}

class MetadataExtractor {
  static Future<List<TrackMetadata>> extractBatch(List<String> paths) {
    return compute(_extractInIsolate, paths);
  }
}

@pragma('vm:entry-point')
List<TrackMetadata> _extractInIsolate(List<String> paths) {
  final results = <TrackMetadata>[];
  var existCount = 0;
  var parseErrors = 0;
  final firstErrors = <String>[];
  // Per-file slow-read tracking — if any single file's read takes
  // longer than 1500ms we log it. On Dropbox CloudStorage these are
  // almost always cloud-only files being materialised on demand.
  // Knowing which files block lets us teach the user (or future
  // logic) to defer them.
  final slow = <String>[];
  final overallSw = Stopwatch()..start();
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      results.add(TrackMetadata.empty(path));
      continue;
    }
    existCount++;
    final sw = Stopwatch()..start();
    try {
      // `getImage: false` skips reading the embedded artwork bytes
      // (we don't display picture data here — the playback deck
      // uses a deterministic color seed). On large AIFF/FLAC files
      // with multi-MB cover art this avoids forcing a full download
      // through Dropbox FileProvider just to compute hasArtwork.
      // We accept that `hasArtwork` will default to false during
      // bulk extraction; a future on-demand pass can refresh it
      // for the currently-playing track.
      final raw = readAllMetadata(file, getImage: false);
      results.add(_mapToTrackMetadata(path, raw));
    } catch (e) {
      parseErrors++;
      if (firstErrors.length < 3) {
        firstErrors.add('$path → $e');
      }
      results.add(TrackMetadata.empty(path));
    }
    if (sw.elapsedMilliseconds > 1500 && slow.length < 5) {
      slow.add('${sw.elapsedMilliseconds}ms ${path.split('/').last}');
    }
  }
  debugPrint(
    '[meta isolate] processed ${paths.length} in ${overallSw.elapsedMilliseconds}ms '
    '(existed=$existCount parseErrors=$parseErrors)',
  );
  for (final err in firstErrors) {
    debugPrint('[meta isolate] err: $err');
  }
  for (final s in slow) {
    debugPrint('[meta isolate] slow: $s');
  }
  return results;
}

TrackMetadata _mapToTrackMetadata(String path, Object raw) {
  String? title;
  String? artist;
  String? album;
  String? genre;
  String? musicalKey;
  double? bpm;
  Duration? duration;
  bool hasArtwork = false;

  if (raw is Mp3Metadata) {
    title = raw.songName;
    // TPE1 (leadPerformer) is what Mp3tag / Rekordbox / Serato /
    // any user-facing "Artist" field writes to. TPE2
    // (bandOrOrchestra) is the "Album Artist" slot — often empty,
    // sometimes "Various" on compilations, sometimes a duplicate
    // of TPE1. The old order preferred TPE2 first, which meant
    // any stale TPE2 data silently overrode a fresh TPE1 edit:
    // the user fixed their artist in Mp3tag, scan ran,
    // re-enrichment ran, but the displayed artist stayed wrong
    // because the parser kept reading the unedited TPE2.
    artist = raw.leadPerformer ?? raw.bandOrOrchestra ?? raw.originalArtist;
    album = raw.album;
    genre = raw.genres.isNotEmpty ? raw.genres.first : null;
    bpm = double.tryParse(raw.bpm ?? '');
    musicalKey = raw.initialKey;
    duration = raw.duration;
    hasArtwork = raw.pictures.isNotEmpty;
  } else if (raw is Mp4Metadata) {
    title = raw.title;
    artist = raw.artist;
    album = raw.album;
    genre = raw.genre;
    duration = raw.duration;
    hasArtwork = raw.picture != null;
  } else if (raw is VorbisMetadata) {
    title = raw.title.isNotEmpty ? raw.title.first : null;
    artist = raw.artist.isNotEmpty ? raw.artist.first : null;
    album = raw.album.isNotEmpty ? raw.album.first : null;
    genre = raw.genres.isNotEmpty ? raw.genres.first : null;
    duration = raw.duration;
    hasArtwork = raw.pictures.isNotEmpty;
  } else if (raw is RiffMetadata) {
    title = raw.title;
    artist = raw.artist;
    album = raw.album;
    genre = raw.genre;
    duration = raw.duration;
    hasArtwork = raw.pictures.isNotEmpty;
  } else if (raw is ApeMetadata) {
    title = raw.title;
    artist = raw.artist;
    album = raw.album;
    genre = raw.genres.isNotEmpty ? raw.genres.first : null;
    duration = raw.duration;
    hasArtwork = raw.pictures.isNotEmpty;
  }

  // Audio_metadata_reader's RiffMetadata (AIFF/WAV) and
  // VorbisMetadata (FLAC) intentionally don't expose
  // `initialKey` even when the underlying ID3v2 / Vorbis-comment
  // parser saw a TKEY / INITIALKEY value. Pull just the key out
  // ourselves so the Key column populates for those formats.
  // Skipped when the standard reader already yielded a key (most
  // MP3s) — no extra file I/O on the common path.
  if ((musicalKey == null || musicalKey.trim().isEmpty) &&
      (raw is RiffMetadata || raw is VorbisMetadata)) {
    final fallback = KeyFallback.read(path);
    if (fallback != null && fallback.trim().isNotEmpty) {
      musicalKey = fallback.trim();
    }
  }

  return TrackMetadata(
    path: path,
    title: _trimToNull(title),
    artist: _trimToNull(artist),
    album: _trimToNull(album),
    genre: _trimToNull(genre),
    musicalKey: _trimToNull(musicalKey),
    bpm: bpm,
    duration: duration,
    hasArtwork: hasArtwork,
    readSucceeded: true,
  );
}

String? _trimToNull(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isEmpty ? null : t;
}

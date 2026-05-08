import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

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
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      results.add(TrackMetadata.empty(path));
      continue;
    }
    existCount++;
    try {
      final raw = readAllMetadata(file, getImage: true);
      results.add(_mapToTrackMetadata(path, raw));
    } catch (e) {
      parseErrors++;
      if (firstErrors.length < 3) {
        firstErrors.add('$path → $e');
      }
      results.add(TrackMetadata.empty(path));
    }
  }
  debugPrint(
    '[meta isolate] processed ${paths.length} (existed=$existCount parseErrors=$parseErrors)',
  );
  for (final err in firstErrors) {
    debugPrint('[meta isolate] err: $err');
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
    artist = raw.bandOrOrchestra ?? raw.leadPerformer ?? raw.originalArtist;
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

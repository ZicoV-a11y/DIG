class Track {
  final String id;
  final String folderPath;

  String title;
  String artist;
  String album;
  String genre;
  String musicalKey;
  double? bpm;
  Duration duration;
  bool favorite;
  Duration cumulativeListened;
  int playCount;
  bool hasArtwork;
  DateTime? metadataReadAt;

  Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.folderPath,
    required this.duration,
    this.album = '',
    this.genre = '',
    this.musicalKey = '',
    this.bpm,
    this.favorite = false,
    this.cumulativeListened = Duration.zero,
    this.playCount = 0,
    this.hasArtwork = false,
    this.metadataReadAt,
  });

  bool get reviewed => cumulativeListened.inSeconds >= 3;
}

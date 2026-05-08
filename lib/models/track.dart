class Track {
  final String id;
  final String title;
  final String artist;
  final String folderPath;

  Duration duration;
  bool favorite;
  Duration cumulativeListened;
  int playCount;

  Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.folderPath,
    required this.duration,
    this.favorite = false,
    this.cumulativeListened = Duration.zero,
    this.playCount = 0,
  });

  bool get reviewed => cumulativeListened.inSeconds >= 3;
}

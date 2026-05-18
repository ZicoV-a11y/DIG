import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Persisted pairing credentials for one MACNEO desktop.
///
/// PR2.7 baseline: a single companion app is paired with ONE
/// desktop at a time. Multi-desktop (work + home) is deferred
/// per the architecture plan — when it lands, this row becomes
/// a per-desktop record keyed by `server_install_id`.
///
/// Slice 1 stores the plaintext token in a local sqflite DB.
/// PR2.7+ should move to the iOS keychain via the
/// `flutter_secure_storage` package; this layer is left
/// intentionally swappable behind the [TokenStorage] interface.
class PairedDesktop {
  final String host;
  final int port;
  final String deviceId;
  final String friendlyName;
  final String token;
  final DateTime pairedAt;

  const PairedDesktop({
    required this.host,
    required this.port,
    required this.deviceId,
    required this.friendlyName,
    required this.token,
    required this.pairedAt,
  });

  Uri get baseUri => Uri.parse('http://$host:$port');
}

abstract class TokenStorage {
  Future<PairedDesktop?> load();
  Future<void> save(PairedDesktop pairing);
  Future<void> clear();
}

/// sqflite-backed implementation. Single-row table —
/// `pairing` always holds at most one row in PR2.7. Future
/// multi-desktop will add a `server_install_id` PK + read all.
class SqfliteTokenStorage implements TokenStorage {
  SqfliteTokenStorage(this._db);

  final Database _db;

  static Future<SqfliteTokenStorage> open(String dbPath) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE pairing (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              host TEXT NOT NULL,
              port INTEGER NOT NULL,
              device_id TEXT NOT NULL,
              friendly_name TEXT NOT NULL,
              token TEXT NOT NULL,
              paired_at INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
    return SqfliteTokenStorage(db);
  }

  @override
  Future<PairedDesktop?> load() async {
    final rows = await _db.query('pairing', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return PairedDesktop(
      host: r['host'] as String,
      port: r['port'] as int,
      deviceId: r['device_id'] as String,
      friendlyName: r['friendly_name'] as String,
      token: r['token'] as String,
      pairedAt:
          DateTime.fromMillisecondsSinceEpoch(r['paired_at'] as int),
    );
  }

  @override
  Future<void> save(PairedDesktop pairing) async {
    await _db.insert(
      'pairing',
      {
        'id': 1,
        'host': pairing.host,
        'port': pairing.port,
        'device_id': pairing.deviceId,
        'friendly_name': pairing.friendlyName,
        'token': pairing.token,
        'paired_at': pairing.pairedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> clear() async {
    await _db.delete('pairing');
  }

  Future<void> close() => _db.close();
}

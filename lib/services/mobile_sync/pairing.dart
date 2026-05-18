import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_core/shared_core.dart';
import 'package:uuid/uuid.dart';

import 'mobile_device.dart';
import 'mobile_sync_repository.dart';

/// A pending pairing the desktop is offering. Holds the 6-digit
/// code the user types into the phone + the pre-allocated
/// device_id that becomes the persistent identity after a
/// successful exchange.
///
/// Slice 1: held in memory only. A pending challenge dies with the
/// desktop process. That's the right trust boundary — pairing only
/// makes sense while both apps are running and the user is
/// physically initiating it.
class PairingChallenge {
  /// The 6-digit numeric code the user reads off the desktop and
  /// types into the phone. Always exactly 6 chars, leading zeros
  /// preserved (e.g. "048217").
  final String code;

  /// The device_id this challenge will materialize into on
  /// successful exchange. Generated up front so the desktop can
  /// pre-render "Waiting for Zico iPhone…" with a stable id.
  final String deviceId;

  /// Optional pre-set friendly name. If the phone supplies its own
  /// at exchange time, that wins. Useful when the user types a
  /// device name into the desktop modal before starting pairing.
  final String? friendlyName;

  final DateTime createdAt;
  final DateTime expiresAt;

  const PairingChallenge({
    required this.code,
    required this.deviceId,
    required this.createdAt,
    required this.expiresAt,
    this.friendlyName,
  });

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// Returned to the phone after a successful `exchangeCode`. The
/// plaintext [token] is the only time it ever exists outside the
/// phone's keychain — the desktop persists only the salted hash.
class PairingResult {
  final String deviceId;
  final String friendlyName;

  /// Plaintext auth token. 32 random bytes hex-encoded. The phone
  /// stores this in iOS keychain and presents it on every
  /// subsequent HTTP request via Bearer auth.
  final String token;

  const PairingResult({
    required this.deviceId,
    required this.friendlyName,
    required this.token,
  });
}

/// Why a pairing exchange failed. Surfaced to the desktop modal so
/// the user can see "Wrong code" vs "Code expired" vs "Already
/// used" rather than a generic failure.
enum PairingExchangeError {
  unknownCode,
  codeExpired,
  codeAlreadyUsed;

  /// Stable wire string used in HTTP error-response bodies. The
  /// phone keys off this to render specific UI ("Code expired —
  /// regenerate" vs "Wrong code — try again").
  String get wireName => switch (this) {
        PairingExchangeError.unknownCode => 'unknown_code',
        PairingExchangeError.codeExpired => 'code_expired',
        PairingExchangeError.codeAlreadyUsed => 'code_already_used',
      };
}

class PairingException implements Exception {
  final PairingExchangeError error;
  final String message;
  const PairingException(this.error, this.message);
  @override
  String toString() => 'PairingException($error): $message';
}

/// Owns the pairing flow end-to-end:
///   1. Desktop calls [createChallenge] → shows the 6-digit code.
///   2. Phone POSTs /api/v1/pair with (code, name, capacity).
///   3. Server handler calls [exchangeCode] → persists the device
///      row with hashed token + returns the plaintext token to the
///      phone.
///   4. Future HTTP requests authenticate via [verifyToken].
///
/// Slice 1: in-memory pending challenges, no rate limiting. Slice
/// 2+ may add per-IP throttling on `/api/v1/pair` if abuse becomes
/// a concern; not needed yet because the server is local-only.
class PairingService {
  PairingService(
    this._repo, {
    Random? random,
    Duration? challengeTtl,
    DateTime Function()? now,
  })  : _random = random ?? Random.secure(),
        _challengeTtl = challengeTtl ?? const Duration(minutes: 5),
        _now = now ?? DateTime.now;

  final MobileSyncRepository _repo;
  final Random _random;
  final Duration _challengeTtl;
  final DateTime Function() _now;

  /// Active challenges keyed by code. Codes are unique per
  /// generation; we drop expired entries lazily on lookup +
  /// proactively when a new code is minted.
  final Map<String, PairingChallenge> _pending = {};

  static const _uuid = Uuid();

  /// Mint a fresh challenge. The returned code is what the user
  /// types into the phone.
  ///
  /// [ttl] overrides the default 5-minute expiry for tests.
  PairingChallenge createChallenge({
    String? friendlyName,
    Duration? ttl,
  }) {
    _gcExpired();
    final code = _generateCode();
    final deviceId = _uuid.v4();
    final createdAt = _now();
    final expiresAt = createdAt.add(ttl ?? _challengeTtl);
    final challenge = PairingChallenge(
      code: code,
      deviceId: deviceId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      friendlyName: friendlyName,
    );
    _pending[code] = challenge;
    return challenge;
  }

  /// Returns currently-pending challenges (for diagnostics — the
  /// desktop UI may want to render the active code if the modal
  /// re-mounts mid-pairing).
  List<PairingChallenge> activeChallenges() {
    _gcExpired();
    return _pending.values.toList();
  }

  /// Cancel a pending challenge (e.g., user closed the pairing
  /// modal). Idempotent.
  void cancelChallenge(String code) {
    _pending.remove(code);
  }

  /// Phone-side handshake: trade a code for a (deviceId, token).
  ///
  /// On success the desktop persists a new `mobile_devices` row
  /// with the hashed token + capacity + sync recipe, and the
  /// challenge is consumed. Throws [PairingException] on failure
  /// so the HTTP handler can map to a 4xx with a clear reason.
  Future<PairingResult> exchangeCode({
    required String code,
    required String friendlyName,
    required CapacityPolicy capacity,
    String? transportFormatPolicy,
    String? syncRecipeJson,
  }) async {
    final challenge = _pending[code];
    if (challenge == null) {
      throw const PairingException(
        PairingExchangeError.unknownCode,
        'No pending challenge matches that code.',
      );
    }
    if (challenge.isExpiredAt(_now())) {
      _pending.remove(code);
      throw const PairingException(
        PairingExchangeError.codeExpired,
        'Pairing code expired. Generate a new one.',
      );
    }

    // Consume the challenge before persisting so a concurrent
    // exchange call can't double-use the same code.
    _pending.remove(code);

    final token = _generateToken();
    final salt = _generateSalt();
    final tokenHash = _hashToken(token: token, salt: salt);
    final storedHash = '$salt:$tokenHash';

    final device = MobileDevice(
      deviceId: challenge.deviceId,
      friendlyName: friendlyName,
      pairedAt: _now(),
      capacity: capacity,
      tokenHash: storedHash,
      transportFormatPolicy:
          transportFormatPolicy ?? 'prefer_mp3_else_aac_256',
      syncRecipeJson: syncRecipeJson ?? '{"type":"manual"}',
    );
    await _repo.insertDevice(device);

    return PairingResult(
      deviceId: challenge.deviceId,
      friendlyName: friendlyName,
      token: token,
    );
  }

  /// Verify the plaintext token a phone presents on an
  /// authenticated request. Returns `true` only when the device
  /// exists AND the token matches the stored hash. Constant-time
  /// hash comparison to avoid leaking partial-match info via
  /// response timing.
  Future<bool> verifyToken({
    required String deviceId,
    required String token,
  }) async {
    final device = await _repo.getDevice(deviceId);
    if (device == null) return false;
    final stored = device.tokenHash;
    final sep = stored.indexOf(':');
    if (sep <= 0 || sep == stored.length - 1) return false;
    final salt = stored.substring(0, sep);
    final expected = stored.substring(sep + 1);
    final actual = _hashToken(token: token, salt: salt);
    return _constantTimeEquals(actual, expected);
  }

  /// Revoke a paired device. Cascades to inventory + eviction
  /// history via the FK.
  Future<void> revokeDevice(String deviceId) async {
    await _repo.deleteDevice(deviceId);
  }

  // ─── internals ────────────────────────────────────────────────────

  /// 6-digit numeric code with leading zeros preserved. Drawn from
  /// [Random.secure] so codes aren't predictable. 1,000,000
  /// possibilities + 5-min TTL + local-only network is enough
  /// entropy for the threat model.
  String _generateCode() {
    final n = _random.nextInt(1000000);
    return n.toString().padLeft(6, '0');
  }

  /// 32 random bytes hex-encoded → 64 chars. High enough entropy
  /// that brute force isn't a concern even over many sessions.
  String _generateToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return _hexEncode(bytes);
  }

  /// 16 random bytes hex-encoded. Salt is per-device so token-hash
  /// collisions across devices don't help an attacker.
  String _generateSalt() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return _hexEncode(bytes);
  }

  /// Salted SHA-256 of the token. Stored as `salt:hex(hash)` so
  /// verification only needs the stored string. Chosen over bcrypt
  /// because the input is a 32-byte high-entropy token, not a
  /// human-derived password — bcrypt's work factor buys nothing
  /// against brute force here, and the dep is heavier than needed.
  String _hashToken({required String token, required String salt}) {
    final bytes = utf8.encode('$salt|$token');
    return _hexEncode(sha256.convert(bytes).bytes);
  }

  /// Constant-time equality on hex strings. Returns immediately
  /// only when the lengths differ — otherwise it loops through
  /// every byte regardless of mismatch position.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String _hexEncode(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  void _gcExpired() {
    final now = _now();
    _pending.removeWhere((_, c) => c.isExpiredAt(now));
  }
}

// PairingService contract tests.
//
// What "pairing" buys us:
//   1. The 6-digit code is the only thing that crosses the
//      human-typed boundary; everything else (device_id, token,
//      hash, salt) is machine-generated and high-entropy.
//   2. The plaintext token is returned to the phone exactly once.
//      Desktop persists only `salt:sha256(salt|token)` so a DB
//      leak doesn't compromise paired devices.
//   3. A code is single-use: the first successful exchange
//      consumes it; the second attempt sees "unknownCode."
//   4. Expired challenges can't be exchanged — and the failure
//      message tells the user to generate a fresh code.
//   5. `verifyToken` uses constant-time comparison so an attacker
//      can't binary-search the hash via response timing.
//
// These are the contracts the HTTP /api/v1/pair handler (PR2.2)
// will build on.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/pairing.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDb;
  late MobileSyncRepository repo;
  late PairingService pairing;
  // Mutable clock the tests can advance to exercise TTL logic.
  late DateTime now;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = MobileSyncRepository(appDb);
    now = DateTime(2026, 1, 1, 12, 0, 0);
    pairing = PairingService(
      repo,
      now: () => now,
      challengeTtl: const Duration(minutes: 5),
    );
  });

  tearDown(() async {
    await appDb.close();
  });

  group('createChallenge', () {
    test('generates a 6-digit numeric code', () {
      final challenge = pairing.createChallenge();
      expect(challenge.code, hasLength(6));
      expect(RegExp(r'^\d{6}$').hasMatch(challenge.code), isTrue,
          reason: 'code must be exactly 6 digits, got "${challenge.code}"');
    });

    test('preserves leading zeros', () {
      // With a deterministic RNG seeded to land on a small number,
      // verify the padding is right.
      final seeded = PairingService(
        repo,
        random: _PredictableRandom([42]),
        now: () => now,
      );
      final c = seeded.createChallenge();
      expect(c.code, '000042');
    });

    test('generates a UUID-shaped device_id', () {
      final c = pairing.createChallenge();
      expect(c.deviceId, hasLength(36));
      expect(c.deviceId.split('-'), hasLength(5));
    });

    test('expires_at is created_at + TTL', () {
      final c = pairing.createChallenge();
      expect(c.expiresAt.difference(c.createdAt),
          const Duration(minutes: 5));
    });

    test('two challenges in a row have different codes', () {
      // Probabilistic — with secure RNG and 1M code space the
      // collision rate is 1/1M, well below test flakiness floor.
      final c1 = pairing.createChallenge();
      final c2 = pairing.createChallenge();
      expect(c1.code, isNot(c2.code));
      expect(c1.deviceId, isNot(c2.deviceId));
    });

    test('garbage-collects expired challenges on the next mint', () {
      final stale = pairing.createChallenge();
      now = now.add(const Duration(minutes: 6));
      pairing.createChallenge();
      expect(
        pairing.activeChallenges().map((c) => c.code).toSet(),
        isNot(contains(stale.code)),
      );
    });
  });

  group('exchangeCode happy path', () {
    test('returns a hex token + persists the device row', () async {
      final challenge = pairing.createChallenge();
      final result = await pairing.exchangeCode(
        code: challenge.code,
        friendlyName: 'Zico iPhone',
        capacity: const CapacityPolicy.songs(100),
      );

      expect(result.deviceId, challenge.deviceId);
      expect(result.friendlyName, 'Zico iPhone');
      // 32-byte token, hex-encoded → 64 chars.
      expect(result.token, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(result.token), isTrue);

      // Device row persisted.
      final device = await repo.getDevice(challenge.deviceId);
      expect(device, isNotNull);
      expect(device!.friendlyName, 'Zico iPhone');
      expect(device.capacity.value, 100);
      // Plaintext token MUST NOT appear anywhere in the stored hash.
      expect(device.tokenHash.contains(result.token), isFalse);
      // Stored hash is `salt:hash` shape.
      expect(device.tokenHash.contains(':'), isTrue);
    });

    test('consumes the challenge — second exchange fails', () async {
      final challenge = pairing.createChallenge();
      await pairing.exchangeCode(
        code: challenge.code,
        friendlyName: 'Zico iPhone',
        capacity: const CapacityPolicy.songs(100),
      );

      expect(
        () => pairing.exchangeCode(
          code: challenge.code,
          friendlyName: 'Replay attempt',
          capacity: const CapacityPolicy.songs(100),
        ),
        throwsA(isA<PairingException>().having(
          (e) => e.error,
          'error',
          PairingExchangeError.unknownCode,
        )),
      );
    });

    test('honors custom transport_format_policy + sync_recipe', () async {
      final challenge = pairing.createChallenge();
      await pairing.exchangeCode(
        code: challenge.code,
        friendlyName: 'Zico iPhone',
        capacity: const CapacityPolicy.bytes(5 * 1024 * 1024 * 1024),
        transportFormatPolicy: 'aac_256',
        syncRecipeJson: '{"type":"unreviewed_random","count":150}',
      );
      final device = await repo.getDevice(challenge.deviceId);
      expect(device!.transportFormatPolicy, 'aac_256');
      expect(device.syncRecipeJson,
          '{"type":"unreviewed_random","count":150}');
    });
  });

  group('exchangeCode rejections', () {
    test('unknownCode for never-minted code', () async {
      expect(
        () => pairing.exchangeCode(
          code: '999999',
          friendlyName: 'x',
          capacity: const CapacityPolicy.songs(1),
        ),
        throwsA(isA<PairingException>().having(
          (e) => e.error,
          'error',
          PairingExchangeError.unknownCode,
        )),
      );
    });

    test('codeExpired after TTL elapses + consumes the challenge',
        () async {
      final challenge = pairing.createChallenge();
      now = now.add(const Duration(minutes: 6));
      expect(
        () => pairing.exchangeCode(
          code: challenge.code,
          friendlyName: 'x',
          capacity: const CapacityPolicy.songs(1),
        ),
        throwsA(isA<PairingException>().having(
          (e) => e.error,
          'error',
          PairingExchangeError.codeExpired,
        )),
      );
      // After expiry the challenge is dropped — repeat attempts see
      // unknownCode, not codeExpired (the difference matters for the
      // UI: expired → "regenerate", unknown → "double-check your
      // typing").
      expect(
        () => pairing.exchangeCode(
          code: challenge.code,
          friendlyName: 'x',
          capacity: const CapacityPolicy.songs(1),
        ),
        throwsA(isA<PairingException>().having(
          (e) => e.error,
          'error',
          PairingExchangeError.unknownCode,
        )),
      );
    });

    test('cancelChallenge drops a pending code', () async {
      final challenge = pairing.createChallenge();
      pairing.cancelChallenge(challenge.code);
      expect(
        () => pairing.exchangeCode(
          code: challenge.code,
          friendlyName: 'x',
          capacity: const CapacityPolicy.songs(1),
        ),
        throwsA(isA<PairingException>()),
      );
    });

    test('cancelChallenge is idempotent', () {
      pairing.cancelChallenge('never-existed');
      pairing.cancelChallenge('never-existed');
      // No throw; succeeds silently.
    });
  });

  group('verifyToken', () {
    late PairingResult result;

    setUp(() async {
      final challenge = pairing.createChallenge();
      result = await pairing.exchangeCode(
        code: challenge.code,
        friendlyName: 'Zico iPhone',
        capacity: const CapacityPolicy.songs(100),
      );
    });

    test('correct token validates', () async {
      expect(
        await pairing.verifyToken(
          deviceId: result.deviceId,
          token: result.token,
        ),
        isTrue,
      );
    });

    test('wrong token rejects', () async {
      expect(
        await pairing.verifyToken(
          deviceId: result.deviceId,
          token: 'a' * 64,
        ),
        isFalse,
      );
    });

    test('unknown device rejects', () async {
      expect(
        await pairing.verifyToken(
          deviceId: 'unknown',
          token: result.token,
        ),
        isFalse,
      );
    });

    test('two pairings produce different stored hashes for the same token',
        () async {
      // Salt is per-device, so even if two devices coincidentally got
      // the same token (1-in-2^256), the stored hashes differ. This
      // is the security property we get from per-device salting.
      final c2 = pairing.createChallenge();
      final r2 = await pairing.exchangeCode(
        code: c2.code,
        friendlyName: 'Zico iPhone 2',
        capacity: const CapacityPolicy.songs(100),
      );
      final d1 = await repo.getDevice(result.deviceId);
      final d2 = await repo.getDevice(r2.deviceId);
      // The tokens themselves are different too (entropy), but the
      // load-bearing assertion is that the SALTS differ — every new
      // device gets a fresh one.
      final salt1 = d1!.tokenHash.split(':')[0];
      final salt2 = d2!.tokenHash.split(':')[0];
      expect(salt1, isNot(salt2));
    });
  });

  group('revokeDevice', () {
    test('removes the device row + cascades inventory', () async {
      final challenge = pairing.createChallenge();
      final result = await pairing.exchangeCode(
        code: challenge.code,
        friendlyName: 'Zico iPhone',
        capacity: const CapacityPolicy.songs(100),
      );

      await pairing.revokeDevice(result.deviceId);
      expect(await repo.getDevice(result.deviceId), isNull);
      // Subsequent verifyToken against the revoked device must
      // fail even if the phone replays its last token.
      expect(
        await pairing.verifyToken(
          deviceId: result.deviceId,
          token: result.token,
        ),
        isFalse,
      );
    });
  });
}

/// Deterministic Random for tests that need to assert exact code
/// output (e.g., leading-zero padding). Returns the next value from
/// the supplied sequence each `nextInt` call, modulo the requested
/// `max`. Throws on overflow so a test that exhausts the sequence
/// fails loudly.
class _PredictableRandom implements Random {
  _PredictableRandom(this._values);
  final List<int> _values;
  int _i = 0;

  @override
  int nextInt(int max) {
    if (_i >= _values.length) {
      throw StateError(
          'PredictableRandom exhausted (sequence: $_values, i=$_i)');
    }
    final v = _values[_i++];
    return v % max;
  }

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);
}

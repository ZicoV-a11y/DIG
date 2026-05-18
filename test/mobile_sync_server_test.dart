// MobileSyncServer handler-level tests.
//
// What "handler-level" means: we call MobileSyncServer.buildHandler()
// directly with synthetic shelf Requests and assert on the Responses.
// No real port is bound. That keeps the tests fast + deterministic +
// makes assertion failures point at the route logic instead of
// network plumbing.
//
// What this slice's contracts buy:
//   1. /api/v1/pair is the ONLY public route. Everything else
//      requires a valid (X-Device-Id, Bearer token) pair.
//   2. The pair endpoint maps PairingException error variants to
//      4xx status codes with stable `error` wire names so the phone
//      can render specific UI ("Code expired — regenerate" vs
//      "Wrong code — try again").
//   3. Auth middleware touches last_seen on every authenticated
//      request — the sidebar's "device online" indicator stays
//      fresh without a separate heartbeat polling loop.
//   4. The /api/v1/manifest stub returns a valid SyncManifest with
//      monotonically-incrementing version + the device's capacity
//      policy + an empty entries list. PR2.3's real builder
//      replaces only the entries computation.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/pairing.dart';
import 'package:music_tracker/services/mobile_sync/server.dart';
import 'package:music_tracker/services/mobile_sync/sync_orchestrator.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:music_tracker/services/mobile_sync/telemetry_reconciler.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shelf/shelf.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDb;
  late MobileSyncRepository repo;
  late LibraryRepository libraryRepo;
  late PairingService pairing;
  late TelemetryReconciler telemetry;
  late SyncSessionStore sessions;
  late SyncOrchestrator orchestrator;
  late MobileSyncServer server;
  late Handler handler;
  late DateTime now;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = MobileSyncRepository(appDb);
    libraryRepo = LibraryRepository(appDb);
    now = DateTime(2026, 5, 17, 12, 0, 0);
    pairing = PairingService(
      repo,
      now: () => now,
      challengeTtl: const Duration(minutes: 5),
    );
    sessions = SyncSessionStore(appDb: appDb, now: () => now);
    orchestrator = SyncOrchestrator(
      sessionStore: sessions,
      now: () => now,
    );
    telemetry = TelemetryReconciler(
      appDb: appDb,
      libraryRepo: libraryRepo,
      sessionStore: sessions,
      orchestrator: orchestrator,
      now: () => now,
    );
    server = MobileSyncServer(
      pairing: pairing,
      repo: repo,
      libraryRepo: libraryRepo,
      telemetry: telemetry,
      orchestrator: orchestrator,
      now: () => now,
    );
    handler = server.buildHandler();
  });

  tearDown(() async {
    await appDb.close();
  });

  // ─── Helpers ──────────────────────────────────────────────────────

  Request post(
    String path,
    Object body, {
    Map<String, String> headers = const {},
  }) {
    return Request(
      'POST',
      Uri.parse('http://test$path'),
      headers: {'content-type': 'application/json', ...headers},
      body: jsonEncode(body),
    );
  }

  Request get(
    String path, {
    Map<String, String> headers = const {},
  }) {
    return Request(
      'GET',
      Uri.parse('http://test$path'),
      headers: headers,
    );
  }

  Future<Map<String, Object?>> readJson(Response response) async {
    final raw = await response.readAsString();
    return jsonDecode(raw) as Map<String, Object?>;
  }

  /// Run the pairing handshake and return the resulting auth headers.
  /// Most tests need an already-paired device to exercise the
  /// authed routes.
  Future<({String deviceId, String token, Map<String, String> auth})>
      pair() async {
    final challenge = pairing.createChallenge();
    final response = await handler(post('/api/v1/pair', {
      'code': challenge.code,
      'friendly_name': 'Zico iPhone',
      'capacity': const CapacityPolicy.songs(100).toJson(),
    }));
    expect(response.statusCode, 200);
    final body = await readJson(response);
    final deviceId = body['device_id'] as String;
    final token = body['token'] as String;
    return (
      deviceId: deviceId,
      token: token,
      auth: {
        'authorization': 'Bearer $token',
        'x-device-id': deviceId,
      },
    );
  }

  // ─── POST /api/v1/pair ────────────────────────────────────────────

  group('POST /api/v1/pair', () {
    test('happy path: valid code → 200 + device row + token', () async {
      final challenge = pairing.createChallenge();
      final response = await handler(post('/api/v1/pair', {
        'code': challenge.code,
        'friendly_name': 'Zico iPhone',
        'capacity': const CapacityPolicy.songs(100).toJson(),
      }));
      expect(response.statusCode, 200);
      final body = await readJson(response);
      expect(body['device_id'], challenge.deviceId);
      expect(body['friendly_name'], 'Zico iPhone');
      expect(body['token'], hasLength(64));
      expect(await repo.getDevice(challenge.deviceId), isNotNull);
    });

    test('unknown code → 404 with unknown_code wire name', () async {
      final response = await handler(post('/api/v1/pair', {
        'code': '999999',
        'friendly_name': 'x',
        'capacity': const CapacityPolicy.songs(1).toJson(),
      }));
      expect(response.statusCode, 404);
      final body = await readJson(response);
      expect(body['error'], 'unknown_code');
    });

    test('expired code → 410 with code_expired wire name', () async {
      final challenge = pairing.createChallenge();
      now = now.add(const Duration(minutes: 6));
      final response = await handler(post('/api/v1/pair', {
        'code': challenge.code,
        'friendly_name': 'x',
        'capacity': const CapacityPolicy.songs(1).toJson(),
      }));
      expect(response.statusCode, 410);
      final body = await readJson(response);
      expect(body['error'], 'code_expired');
    });

    test('missing code field → 400 missing_field', () async {
      final response = await handler(post('/api/v1/pair', {
        'friendly_name': 'x',
        'capacity': const CapacityPolicy.songs(1).toJson(),
      }));
      expect(response.statusCode, 400);
      final body = await readJson(response);
      expect(body['error'], 'missing_field');
    });

    test('missing capacity → 400 missing_field', () async {
      final challenge = pairing.createChallenge();
      final response = await handler(post('/api/v1/pair', {
        'code': challenge.code,
        'friendly_name': 'x',
      }));
      expect(response.statusCode, 400);
    });

    test('malformed capacity → 400 malformed_capacity', () async {
      final challenge = pairing.createChallenge();
      final response = await handler(post('/api/v1/pair', {
        'code': challenge.code,
        'friendly_name': 'x',
        'capacity': {'mode': 'invalid_mode', 'value': 1},
      }));
      expect(response.statusCode, 400);
      final body = await readJson(response);
      expect(body['error'], 'malformed_capacity');
    });
  });

  // ─── Auth middleware ──────────────────────────────────────────────

  group('Auth middleware', () {
    test('missing X-Device-Id → 401 missing_device_id', () async {
      final response = await handler(get(
        '/api/v1/manifest',
        headers: {'authorization': 'Bearer some-token'},
      ));
      expect(response.statusCode, 401);
      final body = await readJson(response);
      expect(body['error'], 'missing_device_id');
    });

    test('missing Authorization → 401 missing_token', () async {
      final response = await handler(get(
        '/api/v1/manifest',
        headers: {'x-device-id': 'someone'},
      ));
      expect(response.statusCode, 401);
      final body = await readJson(response);
      expect(body['error'], 'missing_token');
    });

    test('malformed Authorization (no Bearer prefix) → 401', () async {
      final response = await handler(get(
        '/api/v1/manifest',
        headers: {
          'authorization': 'some-token',
          'x-device-id': 'someone',
        },
      ));
      expect(response.statusCode, 401);
      final body = await readJson(response);
      expect(body['error'], 'missing_token');
    });

    test('unknown device → 401 invalid_credentials', () async {
      final response = await handler(get(
        '/api/v1/manifest',
        headers: {
          'authorization': 'Bearer ${'a' * 64}',
          'x-device-id': 'nope',
        },
      ));
      expect(response.statusCode, 401);
      final body = await readJson(response);
      expect(body['error'], 'invalid_credentials');
    });

    test('wrong token → 401 invalid_credentials', () async {
      final paired = await pair();
      final response = await handler(get(
        '/api/v1/manifest',
        headers: {
          'authorization': 'Bearer ${'b' * 64}',
          'x-device-id': paired.deviceId,
        },
      ));
      expect(response.statusCode, 401);
      final body = await readJson(response);
      expect(body['error'], 'invalid_credentials');
    });

    test('authenticated request touches last_seen', () async {
      final paired = await pair();
      final before = await repo.getDevice(paired.deviceId);
      expect(before!.lastSeenAt, isNull);

      now = now.add(const Duration(minutes: 5));
      await handler(get('/api/v1/manifest', headers: paired.auth));

      final after = await repo.getDevice(paired.deviceId);
      expect(after!.lastSeenAt, isNotNull);
    });
  });

  // ─── POST /api/v1/sync/heartbeat ──────────────────────────────────

  group('POST /api/v1/sync/heartbeat', () {
    test('authenticated heartbeat → 200 ok + last_seen stamped',
        () async {
      final paired = await pair();
      now = now.add(const Duration(seconds: 30));
      final response = await handler(post(
        '/api/v1/sync/heartbeat',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final body = await readJson(response);
      expect(body['ok'], isTrue);
      final device = await repo.getDevice(paired.deviceId);
      expect(device!.lastSeenAt, isNotNull);
    });

    test('unauthenticated heartbeat → 401', () async {
      final response = await handler(
          post('/api/v1/sync/heartbeat', const <String, Object?>{}));
      expect(response.statusCode, 401);
    });
  });

  // ─── GET /api/v1/manifest ─────────────────────────────────────────

  group('GET /api/v1/manifest (PR2.4 — real builder)', () {
    test('returns empty manifest when library has no eligible tracks',
        () async {
      final paired = await pair();
      final response = await handler(get(
        '/api/v1/manifest',
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final manifest = SyncManifest.fromJson(await readJson(response));
      expect(manifest.deviceId, paired.deviceId);
      expect(manifest.entries, isEmpty);
      expect(manifest.capacity.value, 100);
    });

    test('exposes a real ManifestEntry with content_hash + transport_hash',
        () async {
      final paired = await pair();
      // Seed the schema directly. The manifest builder needs a
      // track with intel_uid + content_hash + filename ending in
      // .mp3 + availability_state = 'available'.
      await appDb.db.insert('sources', {
        'id': 'src-test',
        'display_name': 'test',
        'folder_path': '/tmp',
        'created_at': 0,
      });
      await appDb.db.insert('indexed_files', {
        'path': '/tmp/eligible.mp3',
        'source_id': 'src-test',
        'filename': 'eligible.mp3',
        'filesize': 1234,
        'modified_at': 0,
        'duration_ms': 240000,
        'fingerprint': 'fp-test',
        'content_hash': 'hash-test-512kb',
        'uid': 'uid-test',
        'intel_uid': 'intel-test',
        'is_available': 1,
        'availability_state': 'available',
        'last_seen_at': 0,
        'title': 'Test Title',
        'artist': 'Test Artist',
      });

      final response = await handler(get(
        '/api/v1/manifest',
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final manifest = SyncManifest.fromJson(await readJson(response));
      expect(manifest.entries, hasLength(1));
      final entry = manifest.entries.single;
      expect(entry.identity.intelUid, 'intel-test');
      expect(entry.identity.variantId, 'uid-test');
      expect(entry.identity.contentHash, 'hash-test-512kb');
      // Slice 1 contract: transport_hash equals content_hash.
      expect(entry.transportHash, 'hash-test-512kb');
      expect(entry.transportFormat, 'mp3');
      expect(entry.byteSize, 1234);
    });
  });

  // ─── POST /api/v1/sync/request + /api/v1/sync/complete (PR2.7) ────

  group('POST /api/v1/sync/request', () {
    test('opens a session + returns session_id + manifest + diff',
        () async {
      final paired = await pair();

      // Seed one eligible track so the manifest isn't empty —
      // the diff numbers exercise the response shape.
      await appDb.db.insert('sources', {
        'id': 'src-test',
        'display_name': 'test',
        'folder_path': '/tmp',
        'created_at': 0,
      });
      await appDb.db.insert('indexed_files', {
        'path': '/tmp/eligible.mp3',
        'source_id': 'src-test',
        'filename': 'eligible.mp3',
        'filesize': 1234,
        'modified_at': 0,
        'duration_ms': 240000,
        'fingerprint': 'fp-test',
        'content_hash': 'hash-test',
        'uid': 'variant-test',
        'intel_uid': 'intel-test',
        'is_available': 1,
        'availability_state': 'available',
        'last_seen_at': 0,
        'title': 'Eligible',
        'artist': 'Artist',
      });

      final response = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{'current_inventory': []},
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final body = await readJson(response);
      expect(body['session_id'], isA<String>());
      expect(body['manifest'], isA<Map>());
      expect(body['diff'], isA<Map>());

      // Orchestrator state should now be transferring — the
      // request handler walks through negotiating → approving
      // → preparingManifest → transferring before responding so
      // the phone can show "Uploading…" immediately.
      expect(orchestrator.activeSession?.currentState,
          SyncState.transferring);
      expect(orchestrator.activeSession?.deviceId, paired.deviceId);
    });

    test('409 session_in_flight when one is already open', () async {
      final paired = await pair();
      // Open one session via the endpoint.
      final r1 = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      expect(r1.statusCode, 200);

      // Second request without completing — orchestrator refuses.
      final r2 = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      expect(r2.statusCode, 409);
      final body = await readJson(r2);
      expect(body['error'], 'session_in_flight');
    });

    test('honors phone-reported current_inventory in diff', () async {
      final paired = await pair();
      // Seed two eligible tracks; phone claims to already hold one.
      await appDb.db.insert('sources', {
        'id': 'src-test',
        'display_name': 'test',
        'folder_path': '/tmp',
        'created_at': 0,
      });
      for (final intel in const ['intel-A', 'intel-B']) {
        await appDb.db.insert('indexed_files', {
          'path': '/tmp/$intel.mp3',
          'source_id': 'src-test',
          'filename': '$intel.mp3',
          'filesize': 1000,
          'modified_at': 0,
          'duration_ms': 1000,
          'fingerprint': 'fp-$intel',
          'content_hash': 'hash-$intel',
          'uid': 'variant-$intel',
          'intel_uid': intel,
          'is_available': 1,
          'availability_state': 'available',
          'last_seen_at': 0,
          'title': intel,
          'artist': 'A',
        });
      }

      final response = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{
          'current_inventory': ['intel-A'],
        },
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final body = await readJson(response);
      // intel-A already on phone → only intel-B needs adding.
      final diff = body['diff'] as Map<String, Object?>;
      final needAdd = (diff['need_add'] as List)
          .map((e) => (e as Map<String, Object?>)['intel_uid'])
          .toList();
      expect(needAdd, equals(['intel-B']));
    });
  });

  group('POST /api/v1/sync/complete', () {
    test('success path walks the rest of the spine to rotationComplete',
        () async {
      final paired = await pair();
      final openResp = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      final sessionId =
          (await readJson(openResp))['session_id'] as String;

      final response = await handler(post(
        '/api/v1/sync/complete',
        {'session_id': sessionId},
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final body = await readJson(response);
      expect(body['final_state'], 'rotation_complete');
      expect(orchestrator.activeSession?.currentState,
          SyncState.rotationComplete);
      expect(orchestrator.activeSession?.isSuccessful, isTrue);
    });

    test('failure path persists granular code + terminal state',
        () async {
      final paired = await pair();
      final openResp = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      final sessionId =
          (await readJson(openResp))['session_id'] as String;

      final response = await handler(post(
        '/api/v1/sync/complete',
        {
          'session_id': sessionId,
          'failure_code': 'transfer_failed',
          'terminal_state': 'transfer_failed',
          'reason': '3 tracks unreachable',
        },
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      final body = await readJson(response);
      expect(body['final_state'], 'transfer_failed');
      final snap = orchestrator.activeSession;
      expect(snap?.failureState, 'transfer_failed');
      expect(snap?.failureReason, '3 tracks unreachable');
      expect(snap?.isSuccessful, isFalse);
    });

    test('granular code distinct from terminal state', () async {
      // manifestInvalid lands in transferFailed terminal — the
      // snapshot keeps the granular code so the UI can render
      // "Manifest version mismatch" instead of generic
      // "Transfer interrupted."
      final paired = await pair();
      final openResp = await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      final sessionId =
          (await readJson(openResp))['session_id'] as String;

      final response = await handler(post(
        '/api/v1/sync/complete',
        {
          'session_id': sessionId,
          'failure_code': 'manifest_invalid',
          'terminal_state': 'transfer_failed',
          'reason': 'phone manifest_version diverged from desktop',
        },
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      expect(orchestrator.activeSession?.failureState, 'manifest_invalid');
    });

    test('session_mismatch when session_id does not match active',
        () async {
      final paired = await pair();
      await handler(post(
        '/api/v1/sync/request',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      final response = await handler(post(
        '/api/v1/sync/complete',
        {'session_id': 'wrong-id'},
        headers: paired.auth,
      ));
      expect(response.statusCode, 409);
      final body = await readJson(response);
      expect(body['error'], 'session_mismatch');
    });

    test('missing session_id → 400', () async {
      final paired = await pair();
      final response = await handler(post(
        '/api/v1/sync/complete',
        const <String, Object?>{},
        headers: paired.auth,
      ));
      expect(response.statusCode, 400);
    });

    test('unauthenticated request → 401', () async {
      final response = await handler(
          post('/api/v1/sync/complete', const <String, Object?>{}));
      expect(response.statusCode, 401);
    });
  });

  // ─── GET /api/v1/track/<variant_id> ───────────────────────────────

  group('GET /api/v1/track/<variant_id>', () {
    late Directory tempDir;
    late File audioFile;
    late List<int> audioBytes;

    Future<({String deviceId, String token, Map<String, String> auth})>
        seedTrackedFile() async {
      // Build a real audio fixture on disk so the server has
      // bytes to serve. 4 KB of incrementing bytes — small but
      // bigger than typical Range request offsets so we can
      // exercise mid-file resumption.
      tempDir = await Directory.systemTemp.createTemp('mt_pr24_');
      audioFile = File('${tempDir.path}/fixture.mp3');
      audioBytes = List.generate(4096, (i) => i & 0xFF);
      await audioFile.writeAsBytes(audioBytes);

      await appDb.db.insert('sources', {
        'id': 'src-test',
        'display_name': 'test',
        'folder_path': tempDir.path,
        'created_at': 0,
      });
      await appDb.db.insert('indexed_files', {
        'path': audioFile.path,
        'source_id': 'src-test',
        'filename': 'fixture.mp3',
        'filesize': audioBytes.length,
        'modified_at': 0,
        'duration_ms': 240000,
        'fingerprint': 'fp-test',
        'content_hash': 'hash-fixture',
        'uid': 'variant-fixture',
        'intel_uid': 'intel-fixture',
        'is_available': 1,
        'availability_state': 'available',
        'last_seen_at': 0,
        'title': 'Fixture',
        'artist': 'Test',
      });

      return await pair();
    }

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('full file: 200 + correct bytes + integrity headers', () async {
      final paired = await seedTrackedFile();
      final response = await handler(get(
        '/api/v1/track/variant-fixture',
        headers: paired.auth,
      ));
      expect(response.statusCode, 200);
      expect(response.headers['x-transport-hash'], 'hash-fixture');
      expect(response.headers['x-variant-id'], 'variant-fixture');
      expect(response.headers['x-intel-uid'], 'intel-fixture');
      expect(response.headers['content-type'], 'audio/mpeg');
      expect(response.headers['accept-ranges'], 'bytes');
      expect(response.headers['content-length'], '${audioBytes.length}');
      final bytes = await response.read().fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
      expect(bytes, equals(audioBytes));
    });

    test('partial file (Range): 206 + correct slice + Content-Range',
        () async {
      // Resume from byte 1000 to 1499 — 500 bytes mid-file.
      final paired = await seedTrackedFile();
      final response = await handler(get(
        '/api/v1/track/variant-fixture',
        headers: {...paired.auth, 'range': 'bytes=1000-1499'},
      ));
      expect(response.statusCode, 206);
      expect(response.headers['content-range'],
          'bytes 1000-1499/${audioBytes.length}');
      expect(response.headers['content-length'], '500');
      final bytes = await response.read().fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
      expect(bytes, equals(audioBytes.sublist(1000, 1500)));
    });

    test('open-ended Range (bytes=N-) serves to end of file', () async {
      // Used by simple resume clients: "I have N bytes already,
      // send me the rest."
      final paired = await seedTrackedFile();
      final response = await handler(get(
        '/api/v1/track/variant-fixture',
        headers: {...paired.auth, 'range': 'bytes=4000-'},
      ));
      expect(response.statusCode, 206);
      expect(response.headers['content-range'],
          'bytes 4000-${audioBytes.length - 1}/${audioBytes.length}');
      final bytes = await response.read().fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
      expect(bytes, equals(audioBytes.sublist(4000)));
    });

    test('invalid Range → 416 with Content-Range: bytes */<size>',
        () async {
      final paired = await seedTrackedFile();
      final response = await handler(get(
        '/api/v1/track/variant-fixture',
        headers: {...paired.auth, 'range': 'bytes=99999-100000'},
      ));
      expect(response.statusCode, 416);
      expect(response.headers['content-range'],
          'bytes */${audioBytes.length}');
    });

    test('unknown variant_id → 404 not_found', () async {
      final paired = await pair();
      final response = await handler(get(
        '/api/v1/track/no-such-variant',
        headers: paired.auth,
      ));
      expect(response.statusCode, 404);
      final body = await readJson(response);
      expect(body['error'], 'not_found');
    });

    test('row exists but file deleted → 404 file_missing', () async {
      final paired = await seedTrackedFile();
      await audioFile.delete();
      final response = await handler(get(
        '/api/v1/track/variant-fixture',
        headers: paired.auth,
      ));
      expect(response.statusCode, 404);
      final body = await readJson(response);
      expect(body['error'], 'file_missing');
    });

    test('unauthenticated → 401', () async {
      final response = await handler(get('/api/v1/track/whatever'));
      expect(response.statusCode, 401);
    });
  });

  // ─── GET /api/v1/artwork/<intel_uid> ──────────────────────────────

  group('GET /api/v1/artwork/<intel_uid> (opportunistic)', () {
    test('Slice 1 returns 404 not_available — phone falls back to placeholder',
        () async {
      // Per the PR2.4 contract: audio is required, artwork is
      // opportunistic. An artwork 404 must NOT propagate as a
      // sync failure on the phone — it just uses its local
      // placeholder. The 404 + structured error code keeps that
      // signal explicit.
      final paired = await pair();
      final response = await handler(get(
        '/api/v1/artwork/intel-anything',
        headers: paired.auth,
      ));
      expect(response.statusCode, 404);
      final body = await readJson(response);
      expect(body['error'], 'not_available');
    });

    test('unauthenticated artwork → 401', () async {
      final response = await handler(get('/api/v1/artwork/whatever'));
      expect(response.statusCode, 401);
    });
  });
}


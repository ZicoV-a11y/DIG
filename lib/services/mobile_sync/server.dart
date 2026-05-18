import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../library_repository.dart';
import 'manifest_builder.dart';
import 'mobile_device.dart';
import 'mobile_sync_repository.dart';
import 'pairing.dart';
import 'sync_orchestrator.dart';
import 'telemetry_reconciler.dart';

/// HTTP boundary for the mobile-sync subsystem.
///
/// What this file owns:
///   - Server lifecycle (start / stop), binding to a port on the
///     local network.
///   - The Bearer-token auth middleware: every route except
///     `/api/v1/pair` requires the phone to present
///     `Authorization: Bearer <token>` + `X-Device-Id: <id>`. The
///     handler stashes the resolved device on the request via
///     `Request.context['mobile_device']` so downstream handlers
///     can read it without re-validating.
///   - Route table.
///
/// What this file deliberately does NOT own:
///   - Manifest construction (PR2.3 `MobileManifestBuilder`).
///   - File transport (PR2.4 `/track/:id`, `/artwork/:id`).
///   - Telemetry reconciliation (PR2.5 `TelemetryReconciler`).
///
/// All handlers are pure `Request → FutureOr<Response>` functions
/// so tests can drive them directly without binding a port. The
/// `start` / `stop` lifecycle is a separate concern — only
/// integration tests need it.
class MobileSyncServer {
  MobileSyncServer({
    required this.pairing,
    required this.repo,
    required this.libraryRepo,
    required this.telemetry,
    required this.orchestrator,
    ManifestBuilder builder = const ManifestBuilder(),
    DateTime Function()? now,
  })  : _builder = builder,
        _now = now ?? DateTime.now;

  final PairingService pairing;
  final MobileSyncRepository repo;

  /// Read-side of the desktop library. The server queries it to
  /// build the manifest snapshot — the builder is pure, so the
  /// server owns the I/O. Never written to from this layer; all
  /// mutations go through [TelemetryReconciler] (PR2.5).
  final LibraryRepository libraryRepo;

  /// PR2.5 telemetry merge layer. Owns the per-event atomic
  /// transaction + UUID dedup + clock-skew clamp + intel_uid
  /// reconciliation rules. Phone events come in via
  /// `POST /api/v1/telemetry`, get reconciled here, and the ACK
  /// envelope tells the phone what landed.
  final TelemetryReconciler telemetry;

  /// PR2.6.C deterministic state-machine driver. The endpoints
  /// `POST /api/v1/sync/request` + `POST /api/v1/sync/complete`
  /// open and close sessions through here so every legal-
  /// transition rule + counter persistence applies uniformly.
  final SyncOrchestrator orchestrator;

  final ManifestBuilder _builder;
  final DateTime Function() _now;

  HttpServer? _server;

  /// The actual host:port the server is bound to once [start] has
  /// resolved. `null` before start / after stop. Surfaced to the
  /// desktop UI so the pairing modal can render "Enter MAC_IP:PORT
  /// on your iPhone."
  ({InternetAddress address, int port})? get boundAddress {
    final s = _server;
    if (s == null) return null;
    return (address: s.address, port: s.port);
  }

  /// Bind on [host] / [port]. `port: 0` asks the OS for a free
  /// port — the actual port comes back via [boundAddress].
  Future<void> start({
    Object host = '0.0.0.0',
    int port = 0,
  }) async {
    if (_server != null) {
      throw StateError('MobileSyncServer already running');
    }
    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(buildHandler());
    _server = await shelf_io.serve(handler, host, port);
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) await s.close(force: false);
  }

  /// Public routes that bypass the auth middleware. Listed here
  /// rather than as a separate Router because shelf's Cascade
  /// falls through on legitimate 404s (e.g. a wrong pairing code)
  /// → tests saw 401 instead of 404 for an unknown_code response
  /// because Cascade routed past the pair handler when it 404'd
  /// the body. One router + a path-aware middleware avoids that.
  static const _publicPaths = {'/api/v1/pair'};

  /// Public for tests: returns the composed handler exactly as
  /// `start` wires it. Drive it from tests by passing a `Request`
  /// and awaiting the `Response`.
  Handler buildHandler() {
    final router = Router()
      ..post('/api/v1/pair', _handlePair)
      ..get('/api/v1/manifest', _handleManifest)
      ..post('/api/v1/sync/request', _handleSyncRequest)
      ..post('/api/v1/sync/complete', _handleSyncComplete)
      ..post('/api/v1/sync/heartbeat', _handleHeartbeat)
      ..post('/api/v1/telemetry', _handleTelemetry)
      ..get('/api/v1/track/<variantId>', _handleTrack)
      ..get('/api/v1/artwork/<intelUid>', _handleArtwork);

    return const Pipeline()
        .addMiddleware(_authMiddleware())
        .addHandler(router.call);
  }

  // ─── Middleware ───────────────────────────────────────────────────

  /// Per-request auth: requires both `Authorization: Bearer <token>`
  /// and `X-Device-Id: <id>`. Validates the token against the
  /// stored hash via PairingService (constant-time). On success
  /// attaches the resolved MobileDevice to `request.context`.
  ///
  /// Public paths in [_publicPaths] bypass entirely.
  Middleware _authMiddleware() {
    return (Handler inner) {
      return (Request request) async {
        if (_publicPaths.contains('/${request.url.path}')) {
          return inner(request);
        }
        final deviceId = request.headers['x-device-id'];
        if (deviceId == null || deviceId.isEmpty) {
          return _errorResponse(
            401,
            'missing_device_id',
            'X-Device-Id header required.',
          );
        }
        final auth = request.headers['authorization'];
        if (auth == null || !auth.startsWith('Bearer ')) {
          return _errorResponse(
            401,
            'missing_token',
            'Authorization: Bearer <token> required.',
          );
        }
        final token = auth.substring('Bearer '.length).trim();
        if (token.isEmpty) {
          return _errorResponse(
            401,
            'missing_token',
            'Bearer token must not be empty.',
          );
        }

        final ok = await pairing.verifyToken(
          deviceId: deviceId,
          token: token,
        );
        if (!ok) {
          return _errorResponse(
            401,
            'invalid_credentials',
            'Device id / token rejected.',
          );
        }

        // Touch last_seen on every authenticated request — gives
        // the desktop sidebar near-real-time "device online" state
        // without a separate heartbeat path for routine traffic.
        await repo.touchLastSeen(deviceId);

        final device = await repo.getDevice(deviceId);
        if (device == null) {
          // Race: device deleted between verify and getDevice.
          return _errorResponse(
            401,
            'invalid_credentials',
            'Device no longer exists.',
          );
        }
        return inner(request.change(context: {
          ...request.context,
          'mobile_device': device,
        }));
      };
    };
  }

  // ─── Route handlers ───────────────────────────────────────────────

  /// `POST /api/v1/pair` — phone exchanges a 6-digit code for a
  /// persistent (device_id, token) pair.
  ///
  /// Request body (JSON):
  ///   {
  ///     "code": "048217",
  ///     "friendly_name": "Zico iPhone",
  ///     "capacity": {"mode":"song_count","value":100},
  ///     "transport_format_policy": "prefer_mp3_else_aac_256",
  ///     "sync_recipe": "{\"type\":\"manual\"}"
  ///   }
  ///
  /// Response body (JSON, 200):
  ///   { "device_id": "uuid", "friendly_name": "...", "token": "hex64" }
  ///
  /// Error responses use [PairingExchangeError.wireName] as the
  /// `error` code so the phone can map to a specific UI message.
  Future<Response> _handlePair(Request request) async {
    final body = await _readJson(request);
    if (body is! Map<String, Object?>) {
      return _errorResponse(400, 'malformed_body', 'JSON object required.');
    }
    final code = body['code'];
    final friendlyName = body['friendly_name'];
    final capacityJson = body['capacity'];
    if (code is! String || code.isEmpty) {
      return _errorResponse(400, 'missing_field', 'code required.');
    }
    if (friendlyName is! String || friendlyName.isEmpty) {
      return _errorResponse(
        400,
        'missing_field',
        'friendly_name required.',
      );
    }
    if (capacityJson is! Map<String, Object?>) {
      return _errorResponse(400, 'missing_field', 'capacity required.');
    }

    CapacityPolicy capacity;
    try {
      capacity = CapacityPolicy.fromJson(capacityJson);
    } on FormatException catch (e) {
      return _errorResponse(400, 'malformed_capacity', e.message);
    }

    try {
      final result = await pairing.exchangeCode(
        code: code,
        friendlyName: friendlyName,
        capacity: capacity,
        transportFormatPolicy:
            body['transport_format_policy'] as String?,
        syncRecipeJson: body['sync_recipe'] as String?,
      );
      return _jsonResponse(200, {
        'device_id': result.deviceId,
        'friendly_name': result.friendlyName,
        'token': result.token,
      });
    } on PairingException catch (e) {
      final status = switch (e.error) {
        PairingExchangeError.unknownCode => 404,
        PairingExchangeError.codeExpired => 410,
        PairingExchangeError.codeAlreadyUsed => 409,
      };
      return _errorResponse(status, e.error.wireName, e.message);
    }
  }

  /// `POST /api/v1/sync/heartbeat` — phone pings the desktop to
  /// indicate it's still on the network. Stamps `last_seen_at`
  /// via the auth middleware (already done); this endpoint exists
  /// so the phone can ping explicitly when it doesn't have any
  /// other reason to make a request.
  Future<Response> _handleHeartbeat(Request request) async {
    // last_seen already touched by middleware — body is just an
    // ack so the phone can detect "server reachable" cleanly.
    return _jsonResponse(200, {'ok': true});
  }

  /// `GET /api/v1/manifest` — invokes the pure-function
  /// [ManifestBuilder] over a fresh library snapshot for this
  /// device. The builder reads no DB state; the server owns
  /// snapshot I/O.
  Future<Response> _handleManifest(Request request) async {
    final device = request.context['mobile_device'] as MobileDevice;
    final libraryTracks = await libraryRepo.loadTracks();
    final inventory = await repo.listInventory(device.deviceId);
    final inventoryRows = [
      for (final r in inventory)
        PhoneInventoryRow(
          intelUid: r.intelUid,
          variantId: r.variantId,
          residency: r.residency,
          byteSize: 0, // Slice 1 doesn't persist per-row byte size
          pinnedAt: r.pinnedAt,
          pendingPin: r.pendingPin,
        ),
    ];
    final phoneCached = inventoryRows.map((r) => r.intelUid).toSet();
    final recentEvictions = await repo.recentlyEvicted(
      deviceId: device.deviceId,
      cooldownDays: device.recentEvictionCooldownDays,
    );
    final nowMs = _now().millisecondsSinceEpoch;
    final result = _builder.build(ManifestBuilderInput(
      libraryTracks: libraryTracks,
      device: device,
      currentInventory: inventoryRows,
      phoneCachedIntelUids: phoneCached,
      recentlyEvictedIntelUids: recentEvictions,
      randomSeed: nowMs,
      generatedAtMs: nowMs,
      manifestVersion: device.lastManifestVersion + 1,
    ));
    return _jsonResponse(200, result.manifest.toJson());
  }

  /// `POST /api/v1/sync/request` — phone opens a sync session.
  ///
  /// Request body (JSON):
  ///   {
  ///     "current_inventory": ["intelUid1", "intelUid2", ...]  // optional
  ///   }
  ///
  /// Response body (200, JSON):
  ///   {
  ///     "session_id": "uuid",
  ///     "manifest": {...SyncManifest...},
  ///     "diff": {...ManifestDiff...}
  ///   }
  ///
  /// Per PR2.7 thin scope: this is the canonical entry point
  /// that gives the phone a session_id. The phone carries it on
  /// every subsequent telemetry POST so the reconciler bumps the
  /// session's counters; the desktop drives the state machine
  /// in parallel (manifest preview → transferring) using the
  /// orchestrator.
  ///
  /// 409 if a session is already in flight for this orchestrator
  /// instance (Slice 1 supports one device-orchestrator pair at
  /// a time).
  Future<Response> _handleSyncRequest(Request request) async {
    final device = request.context['mobile_device'] as MobileDevice;
    final body = await _readJson(request);
    final phoneInventory = <String>{};
    if (body is Map<String, Object?>) {
      final list = body['current_inventory'];
      if (list is List) {
        for (final v in list) {
          if (v is String) phoneInventory.add(v);
        }
      }
    }

    // Open the session via the orchestrator. The 409 path lets
    // the phone recover from a stale state (e.g., previous
    // session abandoned mid-flight) by retrying after a
    // heartbeat — the manifest endpoint reads the same
    // orchestrator instance.
    final SyncSession session;
    try {
      session = await orchestrator.beginSession(
        deviceId: device.deviceId,
        initiatedBy: SyncInitiator.phone,
      );
    } on StateError catch (e) {
      return _errorResponse(409, 'session_in_flight', e.message);
    }

    // Walk the orchestrator through to preparingManifest so the
    // builder runs while the phone is still waiting on this
    // response. Slice 1 baseline: auto-approve when
    // device.autoApproveSync, otherwise stay in negotiating
    // and let the desktop UI's approval modal drive the next
    // transition. For the thin PR2.7 we skip approval (returns
    // straight to preparingManifest); a full UX layer lights up
    // in PR2.6.E with the modal.
    await orchestrator.transitionTo(SyncState.approving);
    await orchestrator.transitionTo(SyncState.preparingManifest);

    final libraryTracks = await libraryRepo.loadTracks();
    final inventory = await repo.listInventory(device.deviceId);
    final inventoryRows = [
      for (final r in inventory)
        PhoneInventoryRow(
          intelUid: r.intelUid,
          variantId: r.variantId,
          residency: r.residency,
          byteSize: 0,
          pinnedAt: r.pinnedAt,
          pendingPin: r.pendingPin,
        ),
    ];
    final recentEvictions = await repo.recentlyEvicted(
      deviceId: device.deviceId,
      cooldownDays: device.recentEvictionCooldownDays,
    );
    final nowMs = _now().millisecondsSinceEpoch;
    // Phone's reported inventory takes precedence over the
    // desktop's view (the phone is the ground truth for what
    // bytes it actually holds).
    final cachedIntelUids = phoneInventory.isNotEmpty
        ? phoneInventory
        : inventoryRows.map((r) => r.intelUid).toSet();
    final result = _builder.build(ManifestBuilderInput(
      libraryTracks: libraryTracks,
      device: device,
      currentInventory: inventoryRows,
      phoneCachedIntelUids: cachedIntelUids,
      recentlyEvictedIntelUids: recentEvictions,
      randomSeed: nowMs,
      generatedAtMs: nowMs,
      manifestVersion: device.lastManifestVersion + 1,
    ));

    // Stamp the manifest version on the session + advance to
    // transferring so the phone's progress UI can move past
    // "Preparing review crate…" the moment it gets the response.
    await orchestrator.recordProgress(
      manifestVersion: result.manifest.manifestVersion,
    );
    await orchestrator.transitionTo(SyncState.transferring);

    return _jsonResponse(200, {
      'session_id': session.sessionId,
      'manifest': result.manifest.toJson(),
      'diff': result.diff.toJson(),
    });
  }

  /// `POST /api/v1/sync/complete` — phone signals end of sync.
  ///
  /// Request body (JSON):
  ///   Success:
  ///     { "session_id": "uuid" }
  ///   Failure:
  ///     {
  ///       "session_id": "uuid",
  ///       "failure_code": "transfer_failed",  // SyncFailureCode wire name
  ///       "terminal_state": "transfer_failed", // SyncState wire name
  ///       "reason": "human-readable text"     // optional
  ///     }
  ///
  /// Walks the orchestrator through receivingTelemetry →
  /// applyingTelemetry → finalizingRotation → rotationComplete
  /// for the success path. (Slice 1 baseline: the phone confirms
  /// all phases in one shot at the end. A streaming variant
  /// would emit each transition separately; the state machine is
  /// the same.)
  ///
  /// 200 on accepted, 400 on missing fields, 409 if the
  /// orchestrator's active session doesn't match the body's
  /// session_id (defensive — prevents a stale phone from
  /// completing a different session).
  Future<Response> _handleSyncComplete(Request request) async {
    final body = await _readJson(request);
    if (body is! Map<String, Object?>) {
      return _errorResponse(400, 'malformed_body', 'JSON object required.');
    }
    final sessionId = body['session_id'];
    if (sessionId is! String || sessionId.isEmpty) {
      return _errorResponse(
        400, 'missing_field', 'session_id required.');
    }
    final active = orchestrator.activeSession;
    if (active == null || active.sessionId != sessionId) {
      return _errorResponse(
        409,
        'session_mismatch',
        'No active session matches the provided session_id.',
      );
    }

    final failureCodeWire = body['failure_code'];
    if (failureCodeWire is String && failureCodeWire.isNotEmpty) {
      // Failure path. Phone reports a granular code + the
      // terminal SyncState its lifecycle landed in.
      final terminalWire = body['terminal_state'];
      if (terminalWire is! String) {
        return _errorResponse(
          400, 'missing_field', 'terminal_state required for failure.');
      }
      try {
        await orchestrator.completeFailure(
          code: SyncFailureCode.fromWire(failureCodeWire),
          terminalState: syncStateFromWire(terminalWire),
          reason: body['reason'] as String?,
        );
      } on IllegalSyncTransitionException catch (e) {
        return _errorResponse(409, 'illegal_transition', e.toString());
      } on FormatException catch (e) {
        return _errorResponse(400, 'malformed_failure', e.message);
      } on StateError catch (e) {
        return _errorResponse(409, 'illegal_terminal', e.message);
      }
      return _jsonResponse(200, {
        'session_id': sessionId,
        'final_state': orchestrator.activeSession?.currentState.wireName,
      });
    }

    // Success path. Phone confirms it finished transfer +
    // telemetry; walk the rest of the spine.
    try {
      if (active.currentState == SyncState.transferring) {
        await orchestrator.transitionTo(SyncState.receivingTelemetry);
      }
      if (orchestrator.activeSession!.currentState ==
          SyncState.receivingTelemetry) {
        await orchestrator.transitionTo(SyncState.applyingTelemetry);
      }
      if (orchestrator.activeSession!.currentState ==
          SyncState.applyingTelemetry) {
        await orchestrator.transitionTo(SyncState.finalizingRotation);
      }
      await orchestrator.completeSuccess();
    } on IllegalSyncTransitionException catch (e) {
      return _errorResponse(409, 'illegal_transition', e.toString());
    }
    return _jsonResponse(200, {
      'session_id': sessionId,
      'final_state': SyncState.rotationComplete.wireName,
    });
  }

  /// `POST /api/v1/telemetry` — phone uploads a batch of events.
  ///
  /// Body: [TelemetryBatch] JSON.
  /// Response: [TelemetryAck] JSON.
  ///
  /// Per-event atomic + UUID-dedup'd by the reconciler. The phone
  /// trims its local queue based on `accepted_event_ids` in the
  /// response — events NOT in that list stay pending for retry.
  /// The batch never rolls back; partial success is the design.
  ///
  /// The device_id in the batch envelope MUST match the
  /// authenticated device. (The auth middleware already verified
  /// the (device_id, token) pair, but we re-check here to prevent
  /// a paired-but-misbehaving device from posting telemetry as
  /// another device id.)
  Future<Response> _handleTelemetry(Request request) async {
    final device = request.context['mobile_device'] as MobileDevice;
    final body = await _readJson(request);
    if (body is! Map<String, Object?>) {
      return _errorResponse(
        400,
        'malformed_body',
        'JSON object required.',
      );
    }
    TelemetryBatch batch;
    try {
      batch = TelemetryBatch.fromJson(body);
    } on FormatException catch (e) {
      return _errorResponse(400, 'malformed_batch', e.message);
    }
    if (batch.deviceId != device.deviceId) {
      return _errorResponse(
        403,
        'device_id_mismatch',
        'Batch device_id does not match the authenticated device.',
      );
    }
    final ack = await telemetry.reconcile(batch);
    return _jsonResponse(200, ack.toJson());
  }

  /// `GET /api/v1/track/<variant_id>` — serve the raw audio
  /// bytes for a previously-manifested variant.
  ///
  /// Correctness over speed (PR2.4 guidance):
  ///   - Look up the file by `Track.uid` (= variant_id). Variant
  ///     resolution is fully deterministic — the phone GETs
  ///     exactly the bytes the manifest pointed at.
  ///   - Support HTTP Range so partial-completed transfers can
  ///     resume via byte offset.
  ///   - Send `X-Transport-Hash` header so the phone can verify
  ///     it received bytes from the variant it expected.
  ///   - 404 if the file is gone (missing/superseded) — phone
  ///     treats this as a transfer-failure for that one entry,
  ///     other entries proceed.
  Future<Response> _handleTrack(Request request, String variantId) async {
    final track = await libraryRepo.findTrackByUid(variantId);
    if (track == null) {
      return _errorResponse(404, 'not_found',
          'No track variant matches variant_id=$variantId.');
    }
    final file = File(track.path);
    if (!file.existsSync()) {
      return _errorResponse(404, 'file_missing',
          'Variant resolved but the file is no longer on disk.');
    }

    final totalSize = await file.length();
    final hashHeader = {
      'x-transport-hash': track.contentHash ?? '',
      'x-variant-id': track.uid,
      'x-intel-uid': track.intelUid ?? '',
      'accept-ranges': 'bytes',
      'content-type': _mimeForFilename(track.filename),
    };

    final rangeHeader = request.headers['range'];
    if (rangeHeader == null) {
      return Response(
        200,
        body: file.openRead(),
        headers: {
          ...hashHeader,
          'content-length': '$totalSize',
        },
      );
    }

    // Parse a single byte range. Multi-range responses are out
    // of scope — Slice 1 phone client only ever issues one
    // contiguous resume request.
    final parsed = _parseSingleByteRange(rangeHeader, totalSize);
    if (parsed == null) {
      return Response(
        416,
        body: jsonEncode({
          'error': 'invalid_range',
          'message': 'Range header could not be parsed.',
        }),
        headers: {
          ...hashHeader,
          'content-range': 'bytes */$totalSize',
          'content-type': 'application/json',
        },
      );
    }
    final (:start, :end) = parsed;
    final length = end - start + 1;
    return Response(
      206,
      body: file.openRead(start, end + 1),
      headers: {
        ...hashHeader,
        'content-range': 'bytes $start-$end/$totalSize',
        'content-length': '$length',
      },
    );
  }

  /// `GET /api/v1/artwork/<intel_uid>` — opportunistic art.
  ///
  /// Per the PR2.4 guidance: audio is REQUIRED, artwork is
  /// best-effort. Slice 1 returns 404 across the board so the
  /// phone falls back to its local placeholder; this preserves
  /// the "audio failures break sync, artwork failures don't"
  /// distinction. Slice 3+ adds real artwork extraction +
  /// caching here.
  Future<Response> _handleArtwork(Request request, String intelUid) async {
    return _errorResponse(404, 'not_available',
        'Artwork extraction ships in Slice 3+. Phone uses local placeholder.');
  }

  ({int start, int end})? _parseSingleByteRange(String header, int totalSize) {
    // Accept only `bytes=START-END` or `bytes=START-` (open-ended).
    // Multi-range / suffix-range left out of scope.
    if (!header.startsWith('bytes=')) return null;
    final spec = header.substring('bytes='.length).trim();
    if (spec.contains(',')) return null;
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final startStr = spec.substring(0, dash).trim();
    final endStr = spec.substring(dash + 1).trim();
    if (startStr.isEmpty) return null;
    final start = int.tryParse(startStr);
    if (start == null || start < 0 || start >= totalSize) return null;
    int end;
    if (endStr.isEmpty) {
      end = totalSize - 1;
    } else {
      final parsedEnd = int.tryParse(endStr);
      if (parsedEnd == null) return null;
      end = parsedEnd;
    }
    if (end >= totalSize) end = totalSize - 1;
    if (end < start) return null;
    return (start: start, end: end);
  }

  String _mimeForFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.aac') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.aiff') || lower.endsWith('.aif')) return 'audio/aiff';
    return 'application/octet-stream';
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<Object?> _readJson(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return _MalformedJsonSentinel.instance;
    }
  }

  Response _jsonResponse(int status, Object body) {
    return Response(
      status,
      body: jsonEncode(body),
      headers: const {'content-type': 'application/json'},
    );
  }

  Response _errorResponse(int status, String code, String message) {
    return _jsonResponse(status, {'error': code, 'message': message});
  }
}

/// Sentinel for malformed JSON — _readJson returns it so callers
/// can distinguish "no body" (null) from "body present but garbage."
class _MalformedJsonSentinel {
  const _MalformedJsonSentinel._();
  static const _MalformedJsonSentinel instance = _MalformedJsonSentinel._();
}

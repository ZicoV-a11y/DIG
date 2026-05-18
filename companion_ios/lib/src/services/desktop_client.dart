import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_core/shared_core.dart';

import 'operational_log.dart';

/// HTTP client for the MACNEO desktop's mobile-sync API.
///
/// Owns ONLY the wire boundary — every call returns parsed
/// `shared_core` types so the rest of the companion app stays
/// transport-agnostic. Authentication is presented as
/// `Authorization: Bearer <token>` + `X-Device-Id: <id>`; the
/// caller (typically a session manager) holds the credentials.
///
/// Per PR2.7 thin scope: the client speaks every endpoint the
/// thin orchestration wiring exposes, plus the pairing and
/// transport endpoints from earlier slices. No retry, no
/// backoff, no progress reporting — those layer on top.
class DesktopClient {
  DesktopClient({
    required this.baseUri,
    required this.deviceId,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// `http://192.168.1.42:<port>` — the MACNEO server root.
  /// Provided by the pairing flow; persisted in the device's
  /// token storage so subsequent launches skip re-discovery.
  final Uri baseUri;

  final String deviceId;
  final String token;
  final http.Client _http;

  Map<String, String> get _authHeaders => {
        'authorization': 'Bearer $token',
        'x-device-id': deviceId,
        'content-type': 'application/json',
      };

  void close() => _http.close();

  // ─── Pairing (no auth — token is what this call yields) ───────────

  /// Exchange a 6-digit code for a (device_id, token).
  /// Caller provides the [baseUri] when constructing the client
  /// for the pre-pair flow; the device_id + token in the ctor
  /// are placeholders (any non-empty strings) since the server
  /// ignores them on `/pair`.
  Future<({String deviceId, String friendlyName, String token})> pair({
    required String code,
    required String friendlyName,
    required CapacityPolicy capacity,
  }) async {
    OperationalLog.emit('pair',
        'POST /api/v1/pair name="$friendlyName" '
        'capacity=${capacity.mode.wireName}:${capacity.value}');
    final response = await _http.post(
      baseUri.resolve('/api/v1/pair'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'code': code,
        'friendly_name': friendlyName,
        'capacity': capacity.toJson(),
      }),
    );
    _checkOk(response);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    final deviceId = body['device_id'] as String;
    OperationalLog.emit('pair', 'success device_id=$deviceId');
    return (
      deviceId: deviceId,
      friendlyName: body['friendly_name'] as String,
      token: body['token'] as String,
    );
  }

  // ─── Sync lifecycle ───────────────────────────────────────────────

  /// Open a sync session. Phone passes its current inventory of
  /// `intel_uid`s so the desktop's `ManifestDiff` is computed
  /// against ground truth. Response carries `session_id`,
  /// `manifest`, and `diff`.
  Future<({String sessionId, SyncManifest manifest, ManifestDiff diff})>
      openSession({
    required Set<String> currentInventory,
  }) async {
    OperationalLog.emit('sync',
        'POST /api/v1/sync/request '
        'inventory_count=${currentInventory.length}');
    final response = await _http.post(
      baseUri.resolve('/api/v1/sync/request'),
      headers: _authHeaders,
      body: jsonEncode({
        'current_inventory': currentInventory.toList(),
      }),
    );
    _checkOk(response);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    final sessionId = body['session_id'] as String;
    final manifest = SyncManifest.fromJson(
        body['manifest'] as Map<String, Object?>);
    final diff = ManifestDiff.fromJson(body['diff'] as Map<String, Object?>);
    OperationalLog.emit('manifest',
        'received v${manifest.manifestVersion} '
        'entries=${manifest.entries.length} '
        'add=${diff.needAdd.length} remove=${diff.needRemove.length} '
        'session=$sessionId');
    return (sessionId: sessionId, manifest: manifest, diff: diff);
  }

  /// Close a sync session — success path.
  Future<void> completeSessionSuccess(String sessionId) async {
    OperationalLog.emit('sync',
        'POST /api/v1/sync/complete session=$sessionId success');
    final response = await _http.post(
      baseUri.resolve('/api/v1/sync/complete'),
      headers: _authHeaders,
      body: jsonEncode({'session_id': sessionId}),
    );
    _checkOk(response);
    OperationalLog.emit('reconciled', 'session=$sessionId rotationComplete');
  }

  /// Close a sync session — failure path. Granular [code] +
  /// terminal lifecycle [terminalState] + optional [reason].
  Future<void> completeSessionFailure({
    required String sessionId,
    required SyncFailureCode code,
    required SyncState terminalState,
    String? reason,
  }) async {
    final response = await _http.post(
      baseUri.resolve('/api/v1/sync/complete'),
      headers: _authHeaders,
      body: jsonEncode({
        'session_id': sessionId,
        'failure_code': code.wireName,
        'terminal_state': terminalState.wireName,
        'reason': ?reason,
      }),
    );
    _checkOk(response);
  }

  /// Heartbeat — server stamps `last_seen_at` on the device row.
  Future<void> heartbeat() async {
    final response = await _http.post(
      baseUri.resolve('/api/v1/sync/heartbeat'),
      headers: _authHeaders,
      body: '{}',
    );
    _checkOk(response);
  }

  // ─── Transport ────────────────────────────────────────────────────

  /// Stream the audio bytes for a given variant. Caller writes
  /// to disk + verifies the `X-Transport-Hash` header matches
  /// the manifest entry's `transportHash` before committing the
  /// file to the local cache.
  Future<http.StreamedResponse> downloadTrack(
    String variantId, {
    int? rangeStart,
  }) async {
    final request = http.Request(
      'GET',
      baseUri.resolve('/api/v1/track/$variantId'),
    );
    request.headers.addAll(_authHeaders);
    if (rangeStart != null && rangeStart > 0) {
      request.headers['range'] = 'bytes=$rangeStart-';
    }
    return _http.send(request);
  }

  // ─── Telemetry ────────────────────────────────────────────────────

  /// POST a batch of phone-emitted telemetry events. Returns the
  /// ack so the caller can mark events `acknowledged` in its
  /// local queue.
  Future<TelemetryAck> postTelemetry(TelemetryBatch batch) async {
    OperationalLog.emit('telemetry',
        'POST /api/v1/telemetry '
        'events=${batch.events.length} '
        'session=${batch.syncSessionId ?? "<ambient>"}');
    final response = await _http.post(
      baseUri.resolve('/api/v1/telemetry'),
      headers: _authHeaders,
      body: jsonEncode(batch.toJson()),
    );
    _checkOk(response);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    final ack = TelemetryAck.fromJson(body);
    OperationalLog.emit('telemetry',
        'ack applied=${ack.eventsApplied} '
        'deduped=${ack.eventsDeduped} '
        'skipped=${ack.eventsSkipped} '
        'clock_clamped=${ack.eventsClockClamped}');
    return ack;
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  void _checkOk(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    Map<String, Object?>? errorBody;
    try {
      errorBody = jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      // Non-JSON body — fall through to a generic message.
    }
    throw DesktopClientException(
      statusCode: response.statusCode,
      error: errorBody?['error'] as String?,
      message:
          errorBody?['message'] as String? ?? response.body,
    );
  }
}

/// Specific failure surface for desktop calls. Phone-side UI maps
/// HTTP status + `error` wire codes to user-facing messages
/// (e.g., `code_expired` → "Pairing code expired. Generate a new
/// one.").
class DesktopClientException implements Exception {
  final int statusCode;

  /// Stable wire string from the desktop's error envelope —
  /// `unknown_code`, `code_expired`, `session_in_flight`,
  /// `session_mismatch`, `invalid_credentials`, etc.
  final String? error;

  /// Human-readable message from the desktop. Useful for logs;
  /// phone-side UI prefers the localized text keyed off [error].
  final String message;

  const DesktopClientException({
    required this.statusCode,
    required this.message,
    this.error,
  });

  @override
  String toString() =>
      'DesktopClientException(status: $statusCode, error: $error, message: $message)';
}

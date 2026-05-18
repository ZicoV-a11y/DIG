/// **Operational** state of a paired device. NOT social identity,
/// NOT decorative status — these are the states the sidebar
/// Devices panel renders so the user sees, at a glance, what the
/// system is ready to do with each device.
///
/// Per the PR2.6 guidance: think "sync operations console," not
/// "phone integration features." Every state name is a verb-tense
/// answer to "can I sync right now?"
enum DeviceOperationalState {
  /// Heartbeat received within the recent window. Phone is on
  /// the LAN, server reachable, but no sync is in flight.
  online,

  /// `online` + the phone has indicated it's ready to begin a
  /// sync handshake (preview manifest fetched, awaiting user
  /// confirmation locally). Distinct from [awaitingApproval]:
  /// here the phone is the one deliberating; there the desktop is.
  availableForSync,

  /// A sync request arrived; the desktop's approval modal is up
  /// (or, if [autoApproveSync], internally awaiting the auto-tick
  /// before transitioning to [syncing]).
  awaitingApproval,

  /// Active protocol session — manifest being computed,
  /// transferring, telemetry applying. The floating progress
  /// window is bound to a device in this state.
  syncing,

  /// Heartbeat missing past threshold. Device was paired and
  /// recently seen, but right now we can't reach it. Distinct
  /// from [offline]: stale means "expected to come back" (e.g.,
  /// phone is sleeping); offline means "we've waited long enough
  /// that we don't expect it soon."
  stale,

  /// Long-disconnected. Sidebar de-emphasizes; sync attempts
  /// require fresh discovery / pairing.
  offline;

  String get wireName {
    switch (this) {
      case DeviceOperationalState.online:
        return 'online';
      case DeviceOperationalState.availableForSync:
        return 'available_for_sync';
      case DeviceOperationalState.awaitingApproval:
        return 'awaiting_approval';
      case DeviceOperationalState.syncing:
        return 'syncing';
      case DeviceOperationalState.stale:
        return 'stale';
      case DeviceOperationalState.offline:
        return 'offline';
    }
  }

  static DeviceOperationalState fromWire(String s) {
    switch (s) {
      case 'online':
        return DeviceOperationalState.online;
      case 'available_for_sync':
        return DeviceOperationalState.availableForSync;
      case 'awaiting_approval':
        return DeviceOperationalState.awaitingApproval;
      case 'syncing':
        return DeviceOperationalState.syncing;
      case 'stale':
        return DeviceOperationalState.stale;
      case 'offline':
        return DeviceOperationalState.offline;
      default:
        throw FormatException(
            'Unknown DeviceOperationalState: $s');
    }
  }
}

/// Pure function — given the heartbeat/session inputs, return the
/// derived operational state. UI binds to the OUTPUT, never
/// computes it. Keeps state-derivation testable + consistent
/// across desktop and phone surfaces.
///
/// Inputs:
///   - [lastSeenAt]: ms since epoch from `mobile_devices.last_seen_at`,
///     null if never seen.
///   - [now]: ms since epoch wall-clock at the moment of derivation.
///   - [activeSessionState]: if a sync_session row exists for this
///     device that hasn't completed, its [SyncSession.currentState]
///     (or equivalent) — drives the awaitingApproval / syncing
///     branches.
///   - [heartbeatStaleAfter]: how long after a heartbeat we
///     start showing [stale]. Default 30 seconds.
///   - [heartbeatOfflineAfter]: how long after a heartbeat we
///     show [offline]. Default 5 minutes.
DeviceOperationalState deriveDeviceState({
  required int? lastSeenAt,
  required int now,
  required ActiveSyncSessionState? activeSessionState,
  Duration heartbeatStaleAfter = const Duration(seconds: 30),
  Duration heartbeatOfflineAfter = const Duration(minutes: 5),
}) {
  // Active session always wins — even if the heartbeat clock has
  // ticked past stale, a syncing session is real evidence the
  // device is right here.
  if (activeSessionState != null) {
    switch (activeSessionState) {
      case ActiveSyncSessionState.awaitingApproval:
        return DeviceOperationalState.awaitingApproval;
      case ActiveSyncSessionState.syncing:
        return DeviceOperationalState.syncing;
      case ActiveSyncSessionState.availableForSync:
        return DeviceOperationalState.availableForSync;
    }
  }

  if (lastSeenAt == null) {
    return DeviceOperationalState.offline;
  }
  final delta = now - lastSeenAt;
  if (delta <= heartbeatStaleAfter.inMilliseconds) {
    return DeviceOperationalState.online;
  }
  if (delta <= heartbeatOfflineAfter.inMilliseconds) {
    return DeviceOperationalState.stale;
  }
  return DeviceOperationalState.offline;
}

/// Projection of a sync_sessions row's currentState down to the
/// three values [deriveDeviceState] cares about. Callers map
/// their full [SyncState] to this enum at the boundary so the
/// derivation stays a pure function of inputs.
enum ActiveSyncSessionState {
  availableForSync,
  awaitingApproval,
  syncing,
}

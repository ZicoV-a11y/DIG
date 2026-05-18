import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database.dart';
import 'mobile_device.dart';

/// Mobile-sync persistence layer. Keeps mobile-sync DB writes out
/// of the main [LibraryRepository] so that file lives focused on
/// the desktop library + intelligence ontology, while this file
/// carries the per-device pairing / inventory / eviction state.
///
/// Per the user's PR2 guidance: shared_core holds DTOs/contracts;
/// SQLite-shaped models stay desktop-side. The wire boundary lives
/// at `lib/services/mobile_sync/server.dart` (next sub-slice).
class MobileSyncRepository {
  final AppDatabase _appDb;
  MobileSyncRepository(this._appDb);

  Database get _db => _appDb.db;

  // ─── mobile_devices CRUD ───────────────────────────────────────────

  /// Insert a freshly-paired device. Caller is responsible for
  /// generating [deviceId] (UUID) + hashing the auth token.
  Future<void> insertDevice(MobileDevice device) async {
    await _db.insert('mobile_devices', {
      'device_id': device.deviceId,
      'friendly_name': device.friendlyName,
      'paired_at': device.pairedAt.millisecondsSinceEpoch,
      'last_seen_at': device.lastSeenAt?.millisecondsSinceEpoch,
      'last_sync_at': device.lastSyncAt?.millisecondsSinceEpoch,
      'last_manifest_version': device.lastManifestVersion,
      'capacity_mode': device.capacity.mode.wireName,
      'capacity_value': device.capacity.value,
      'transport_format_policy': device.transportFormatPolicy,
      'sync_recipe': device.syncRecipeJson,
      'recent_eviction_cooldown_days': device.recentEvictionCooldownDays,
      'auto_approve_sync': device.autoApproveSync ? 1 : 0,
      'token_hash': device.tokenHash,
    });
  }

  /// Set or clear the per-device "remember my choice" auto-approve
  /// flag. When true the desktop skips its approval modal for
  /// subsequent sync requests from this device.
  Future<void> setAutoApprove(String deviceId, bool autoApprove) async {
    await _db.update(
      'mobile_devices',
      {'auto_approve_sync': autoApprove ? 1 : 0},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<List<MobileDevice>> listDevices() async {
    final rows = await _db.query('mobile_devices', orderBy: 'paired_at DESC');
    return rows.map(MobileDevice.fromRow).toList();
  }

  Future<MobileDevice?> getDevice(String deviceId) async {
    final rows = await _db.query(
      'mobile_devices',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MobileDevice.fromRow(rows.first);
  }

  Future<void> updateDeviceCapacity(
    String deviceId,
    CapacityPolicy capacity,
  ) async {
    await _db.update(
      'mobile_devices',
      {
        'capacity_mode': capacity.mode.wireName,
        'capacity_value': capacity.value,
      },
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<void> updateDeviceTransportPolicy(
    String deviceId,
    String transportFormatPolicy,
  ) async {
    await _db.update(
      'mobile_devices',
      {'transport_format_policy': transportFormatPolicy},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  /// Stamp `last_seen_at = now`. Cheap; called on every heartbeat
  /// from the phone.
  Future<void> touchLastSeen(String deviceId) async {
    await _db.update(
      'mobile_devices',
      {'last_seen_at': DateTime.now().millisecondsSinceEpoch},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  /// Stamp `last_sync_at = now` AND bump `last_manifest_version`.
  /// Called at the close of a successful handshake.
  Future<void> markSynced(String deviceId, int manifestVersion) async {
    await _db.update(
      'mobile_devices',
      {
        'last_sync_at': DateTime.now().millisecondsSinceEpoch,
        'last_manifest_version': manifestVersion,
      },
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  /// Cascade-deletes the device's inventory + eviction history via
  /// the FK ON DELETE CASCADE on those tables.
  Future<void> deleteDevice(String deviceId) async {
    await _db.delete(
      'mobile_devices',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  // ─── mobile_sync_inventory CRUD ────────────────────────────────────

  /// Add a track to a device's inventory. Idempotent on
  /// (device_id, intel_uid) — re-sending the same identity is a
  /// no-op (ConflictAlgorithm.ignore) rather than an error, so
  /// callers can retry safely.
  Future<void> upsertInventory(MobileInventoryEntry entry) async {
    await _db.insert(
      'mobile_sync_inventory',
      {
        'device_id': entry.deviceId,
        'intel_uid': entry.intelUid,
        'variant_id': entry.variantId,
        'content_hash': entry.contentHash,
        'residency': entry.residency.wireName,
        'sync_origin': entry.syncOrigin,
        'priority_rank': entry.priorityRank,
        'pinned_at': entry.pinnedAt?.millisecondsSinceEpoch,
        'pending_pin': entry.pendingPin ? 1 : 0,
        'added_at': entry.addedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MobileInventoryEntry>> listInventory(String deviceId) async {
    final rows = await _db.query(
      'mobile_sync_inventory',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      orderBy: 'priority_rank DESC, added_at ASC',
    );
    return rows.map(MobileInventoryEntry.fromRow).toList();
  }

  /// Active (non-pending) inventory only — what the phone actually
  /// holds. Excludes pin-queue overflow rows.
  Future<List<MobileInventoryEntry>> listActiveInventory(
    String deviceId,
  ) async {
    final rows = await _db.query(
      'mobile_sync_inventory',
      where: 'device_id = ? AND pending_pin = 0',
      whereArgs: [deviceId],
      orderBy: 'priority_rank DESC, added_at ASC',
    );
    return rows.map(MobileInventoryEntry.fromRow).toList();
  }

  Future<void> removeFromInventory(String deviceId, String intelUid) async {
    await _db.delete(
      'mobile_sync_inventory',
      where: 'device_id = ? AND intel_uid = ?',
      whereArgs: [deviceId, intelUid],
    );
  }

  /// Promote the next FIFO-pin row to active when capacity frees up.
  /// Returns the promoted intel_uid (if any). Idempotent — runs as
  /// a no-op when the queue is empty or no slots are free.
  Future<String?> promoteNextPendingPin(String deviceId) async {
    final next = await _db.query(
      'mobile_sync_inventory',
      where: 'device_id = ? AND pending_pin = 1',
      whereArgs: [deviceId],
      orderBy: 'pinned_at ASC',
      limit: 1,
    );
    if (next.isEmpty) return null;
    final intelUid = next.first['intel_uid'] as String;
    await _db.update(
      'mobile_sync_inventory',
      {'pending_pin': 0},
      where: 'device_id = ? AND intel_uid = ?',
      whereArgs: [deviceId, intelUid],
    );
    return intelUid;
  }

  // ─── mobile_eviction_history append + read ─────────────────────────

  /// Append an eviction event. Used by the rotation engine when a
  /// `rotating` / `hybrid_fill` track gets dropped, and by the
  /// "Recent eviction cooldown" rule that deprioritizes recently
  /// rotated tracks from random recipes.
  Future<void> recordEviction({
    required String deviceId,
    required String intelUid,
    required String reason,
    DateTime? evictedAt,
  }) async {
    await _db.insert('mobile_eviction_history', {
      'device_id': deviceId,
      'intel_uid': intelUid,
      'evicted_at':
          (evictedAt ?? DateTime.now()).millisecondsSinceEpoch,
      'reason': reason,
    });
  }

  /// intel_uids evicted from [deviceId] within the last
  /// [cooldownDays]. Used as a deprioritization set for random
  /// recipes — caller multiplies their weight by 0.1 instead of
  /// excluding outright.
  Future<Set<String>> recentlyEvicted({
    required String deviceId,
    required int cooldownDays,
  }) async {
    final cutoff = DateTime.now()
        .subtract(Duration(days: cooldownDays))
        .millisecondsSinceEpoch;
    final rows = await _db.query(
      'mobile_eviction_history',
      columns: ['intel_uid'],
      where: 'device_id = ? AND evicted_at >= ?',
      whereArgs: [deviceId, cutoff],
    );
    return {for (final r in rows) r['intel_uid'] as String};
  }
}

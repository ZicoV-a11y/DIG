import 'package:shared_core/shared_core.dart';

/// In-memory representation of a `mobile_devices` row. Distinct from
/// the wire types in `shared_core` because this carries the
/// desktop-only `tokenHash` and other operational fields the phone
/// must never see.
///
/// `shared_core` deliberately doesn't define this shape — per the
/// PR2 ontology guidance, persistence stays out of the shared
/// package; only contracts cross the boundary.
class MobileDevice {
  final String deviceId;
  final String friendlyName;
  final DateTime pairedAt;
  final DateTime? lastSeenAt;
  final DateTime? lastSyncAt;
  final int lastManifestVersion;
  final CapacityPolicy capacity;

  /// Wire string — `'aac_256'`, `'prefer_mp3_else_aac_256'`, …
  /// Kept as a String here (rather than an enum) because the
  /// transport-policy vocabulary is still evolving across slices;
  /// the column is the source of truth, the in-memory class just
  /// passes it through.
  final String transportFormatPolicy;

  /// Slice 1 stores raw JSON of the device's sync recipe. Slice 2+
  /// will parse it into a typed `SyncRecipe` class; for now we
  /// hold the string verbatim.
  final String syncRecipeJson;

  final int recentEvictionCooldownDays;

  /// When true the desktop skips the "Approve & Sync" modal for
  /// this device and acts on incoming sync requests directly.
  /// Set via the "Remember my choice for this device" toggle on
  /// the approval modal (mockup confirms). Default false — first
  /// pairing always requires approval. iPhone's "Require Approval"
  /// settings toggle is a separate phone-side opt-in for showing
  /// its own confirmation step.
  final bool autoApproveSync;

  /// bcrypt-hashed auth token. The plaintext token only exists
  /// during the pairing flow; once persisted we hold only the hash
  /// so a DB leak doesn't compromise paired devices.
  final String tokenHash;

  const MobileDevice({
    required this.deviceId,
    required this.friendlyName,
    required this.pairedAt,
    required this.capacity,
    required this.tokenHash,
    this.lastSeenAt,
    this.lastSyncAt,
    this.lastManifestVersion = 0,
    this.transportFormatPolicy = 'prefer_mp3_else_aac_256',
    this.syncRecipeJson = '{"type":"manual"}',
    this.recentEvictionCooldownDays = 14,
    this.autoApproveSync = false,
  });

  static MobileDevice fromRow(Map<String, Object?> r) {
    return MobileDevice(
      deviceId: r['device_id'] as String,
      friendlyName: r['friendly_name'] as String,
      pairedAt: DateTime.fromMillisecondsSinceEpoch(r['paired_at'] as int),
      lastSeenAt: r['last_seen_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['last_seen_at'] as int),
      lastSyncAt: r['last_sync_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['last_sync_at'] as int),
      lastManifestVersion: (r['last_manifest_version'] as int?) ?? 0,
      capacity: CapacityPolicy(
        mode: CapacityMode.fromWire(r['capacity_mode'] as String),
        value: r['capacity_value'] as int,
      ),
      transportFormatPolicy: r['transport_format_policy'] as String,
      syncRecipeJson: r['sync_recipe'] as String,
      recentEvictionCooldownDays:
          (r['recent_eviction_cooldown_days'] as int?) ?? 14,
      autoApproveSync: ((r['auto_approve_sync'] as int?) ?? 0) != 0,
      tokenHash: r['token_hash'] as String,
    );
  }
}

/// One row from `mobile_sync_inventory` — which intel_uid is on
/// which device, with the policy that determines whether it rotates.
class MobileInventoryEntry {
  final String deviceId;
  final String intelUid;
  final String variantId;
  final String contentHash;
  final ResidencyClass residency;

  /// Where this row came from — `'manual'`, `'pinned'`,
  /// `'unreviewed_random'`, etc. Used by the eviction-priority
  /// calculator and by the operational journal for narration.
  final String syncOrigin;

  final int priorityRank;
  final DateTime? pinnedAt;

  /// `true` when this row is queued behind capacity overflow
  /// (FIFO pin fulfillment). Cleared when an earlier-pinned slot
  /// frees up.
  final bool pendingPin;

  final DateTime addedAt;

  const MobileInventoryEntry({
    required this.deviceId,
    required this.intelUid,
    required this.variantId,
    required this.contentHash,
    required this.residency,
    required this.syncOrigin,
    required this.priorityRank,
    required this.addedAt,
    this.pinnedAt,
    this.pendingPin = false,
  });

  static MobileInventoryEntry fromRow(Map<String, Object?> r) {
    return MobileInventoryEntry(
      deviceId: r['device_id'] as String,
      intelUid: r['intel_uid'] as String,
      variantId: r['variant_id'] as String,
      contentHash: r['content_hash'] as String,
      residency: ResidencyClass.fromWire(r['residency'] as String),
      syncOrigin: r['sync_origin'] as String,
      priorityRank: r['priority_rank'] as int,
      pinnedAt: r['pinned_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['pinned_at'] as int),
      pendingPin: ((r['pending_pin'] as int?) ?? 0) != 0,
      addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
    );
  }
}

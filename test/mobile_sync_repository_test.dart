// Schema v16 + MobileSyncRepository CRUD + recordEvent origin column.
//
// These pin the desktop-side persistence contracts that the
// MobileSyncServer (next sub-slice) will build on:
//
//   1. v16 schema exists with the right columns + indexes.
//   2. Device pairing inserts + reads round-trip cleanly (including
//      the capacity policy, transport format, sync recipe JSON).
//   3. Inventory CRUD supports the FIFO pin-queue contract: queued
//      rows have `pending_pin = 1` and `promoteNextPendingPin`
//      activates them in `pinned_at` order.
//   4. Eviction history append + `recentlyEvicted` filters by
//      cooldown window — what drives random-recipe deprioritization.
//   5. `recordEvent` defaults origin = 'desktop'; mobile-sourced
//      events round-trip through the events table with their
//      `mobile:<device_id>` origin string intact.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDb;
  late MobileSyncRepository repo;
  late LibraryRepository libRepo;
  late Database raw;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = MobileSyncRepository(appDb);
    libRepo = LibraryRepository(appDb);
    raw = appDb.db;
  });

  tearDown(() async {
    await appDb.close();
  });

  group('v16 schema', () {
    test('mobile_devices columns + token_hash exist', () async {
      final cols = await raw.rawQuery('PRAGMA table_info(mobile_devices)');
      final names = cols.map((c) => c['name']).toSet();
      expect(names, containsAll([
        'device_id',
        'friendly_name',
        'paired_at',
        'last_seen_at',
        'last_sync_at',
        'last_manifest_version',
        'capacity_mode',
        'capacity_value',
        'transport_format_policy',
        'sync_recipe',
        'recent_eviction_cooldown_days',
        'token_hash',
      ]));
    });

    test('mobile_sync_inventory has pin-queue columns', () async {
      final cols =
          await raw.rawQuery('PRAGMA table_info(mobile_sync_inventory)');
      final names = cols.map((c) => c['name']).toSet();
      expect(names, containsAll([
        'device_id',
        'intel_uid',
        'variant_id',
        'content_hash',
        'residency',
        'sync_origin',
        'priority_rank',
        'pinned_at',
        'pending_pin',
        'added_at',
      ]));
    });

    test('events.origin column exists with desktop default', () async {
      final cols = await raw.rawQuery('PRAGMA table_info(events)');
      final origin = cols.firstWhere((c) => c['name'] == 'origin');
      expect(origin['dflt_value'], "'desktop'");
      expect(origin['notnull'], 1);
    });

    test('FK from inventory to device cascades on delete', () async {
      // Foreign keys need PRAGMA foreign_keys = ON, which AppDatabase
      // sets in onConfigure. Sanity-check that the inventory row
      // disappears when its device is deleted.
      await repo.insertDevice(_makeDevice('d1'));
      await repo.upsertInventory(_makeInventoryEntry('d1', 'intel-1'));
      expect(await repo.listInventory('d1'), hasLength(1));

      await repo.deleteDevice('d1');
      expect(await repo.listInventory('d1'), isEmpty);
    });
  });

  group('MobileSyncRepository — device CRUD', () {
    test('insertDevice + getDevice round-trip', () async {
      await repo.insertDevice(_makeDevice('d1'));
      final got = await repo.getDevice('d1');
      expect(got, isNotNull);
      expect(got!.deviceId, 'd1');
      expect(got.friendlyName, 'Zico iPhone');
      expect(got.capacity.mode, CapacityMode.songCount);
      expect(got.capacity.value, 100);
      expect(got.transportFormatPolicy, 'prefer_mp3_else_aac_256');
      expect(got.tokenHash, 'bcrypt-stub-hash');
    });

    test('getDevice returns null for unknown', () async {
      expect(await repo.getDevice('nope'), isNull);
    });

    test('listDevices is newest-paired first', () async {
      await repo.insertDevice(
          _makeDevice('d1', pairedAt: DateTime(2024, 1, 1)));
      await repo.insertDevice(
          _makeDevice('d2', pairedAt: DateTime(2024, 6, 1)));
      final list = await repo.listDevices();
      expect(list.map((d) => d.deviceId).toList(), ['d2', 'd1']);
    });

    test('updateDeviceCapacity updates both mode and value', () async {
      await repo.insertDevice(_makeDevice('d1'));
      await repo.updateDeviceCapacity(
        'd1',
        const CapacityPolicy.bytes(5 * 1024 * 1024 * 1024),
      );
      final got = await repo.getDevice('d1');
      expect(got!.capacity.mode, CapacityMode.storageBudget);
      expect(got.capacity.value, 5 * 1024 * 1024 * 1024);
    });

    test('touchLastSeen stamps current time', () async {
      await repo.insertDevice(_makeDevice('d1'));
      final before = DateTime.now().millisecondsSinceEpoch;
      await repo.touchLastSeen('d1');
      final after = DateTime.now().millisecondsSinceEpoch;
      final got = await repo.getDevice('d1');
      final seen = got!.lastSeenAt!.millisecondsSinceEpoch;
      expect(seen, greaterThanOrEqualTo(before));
      expect(seen, lessThanOrEqualTo(after));
    });

    test('markSynced stamps sync time + bumps manifest version', () async {
      await repo.insertDevice(_makeDevice('d1'));
      await repo.markSynced('d1', 42);
      final got = await repo.getDevice('d1');
      expect(got!.lastSyncAt, isNotNull);
      expect(got.lastManifestVersion, 42);
    });

    test('autoApproveSync defaults to false on pairing', () async {
      await repo.insertDevice(_makeDevice('d1'));
      final got = await repo.getDevice('d1');
      expect(got!.autoApproveSync, isFalse);
    });

    test('setAutoApprove flips the flag', () async {
      // "Remember my choice for this device" toggle on the desktop
      // approval modal. Per the mockup the user can opt out of the
      // approval step per-device; pairing is always opt-in (default
      // false) so the first sync always requires a tap.
      await repo.insertDevice(_makeDevice('d1'));
      await repo.setAutoApprove('d1', true);
      final got = await repo.getDevice('d1');
      expect(got!.autoApproveSync, isTrue);

      await repo.setAutoApprove('d1', false);
      expect((await repo.getDevice('d1'))!.autoApproveSync, isFalse);
    });
  });

  group('MobileSyncRepository — inventory CRUD', () {
    setUp(() async {
      await repo.insertDevice(_makeDevice('d1'));
    });

    test('upsertInventory + listInventory round-trip', () async {
      await repo.upsertInventory(_makeInventoryEntry(
        'd1',
        'intel-1',
        residency: ResidencyClass.manual,
      ));
      final list = await repo.listInventory('d1');
      expect(list, hasLength(1));
      expect(list[0].intelUid, 'intel-1');
      expect(list[0].residency, ResidencyClass.manual);
      expect(list[0].syncOrigin, 'manual');
      expect(list[0].pendingPin, isFalse);
    });

    test('upsertInventory is idempotent on (device_id, intel_uid)',
        () async {
      await repo.upsertInventory(
        _makeInventoryEntry('d1', 'intel-1', priorityRank: 10),
      );
      await repo.upsertInventory(
        _makeInventoryEntry('d1', 'intel-1', priorityRank: 20),
      );
      final list = await repo.listInventory('d1');
      expect(list, hasLength(1));
      // Re-upsert REPLACES, so the second priority wins.
      expect(list[0].priorityRank, 20);
    });

    test('listActiveInventory excludes pending_pin rows', () async {
      await repo.upsertInventory(_makeInventoryEntry('d1', 'intel-a'));
      await repo.upsertInventory(_makeInventoryEntry(
        'd1',
        'intel-b',
        pendingPin: true,
        pinnedAt: DateTime(2024, 1, 1),
      ));
      expect((await repo.listInventory('d1')).length, 2);
      expect((await repo.listActiveInventory('d1')).length, 1);
      expect((await repo.listActiveInventory('d1'))[0].intelUid, 'intel-a');
    });

    test('promoteNextPendingPin promotes oldest pinned_at first',
        () async {
      await repo.upsertInventory(_makeInventoryEntry(
        'd1',
        'intel-a',
        pendingPin: true,
        pinnedAt: DateTime(2024, 6, 1),
      ));
      await repo.upsertInventory(_makeInventoryEntry(
        'd1',
        'intel-b',
        pendingPin: true,
        pinnedAt: DateTime(2024, 1, 1), // older
      ));
      final promoted = await repo.promoteNextPendingPin('d1');
      expect(promoted, 'intel-b');
      expect((await repo.listActiveInventory('d1'))[0].intelUid, 'intel-b');
    });

    test('promoteNextPendingPin returns null when no queue', () async {
      await repo.upsertInventory(_makeInventoryEntry('d1', 'intel-a'));
      expect(await repo.promoteNextPendingPin('d1'), isNull);
    });

    test('removeFromInventory drops the row', () async {
      await repo.upsertInventory(_makeInventoryEntry('d1', 'intel-1'));
      await repo.removeFromInventory('d1', 'intel-1');
      expect(await repo.listInventory('d1'), isEmpty);
    });
  });

  group('MobileSyncRepository — eviction history', () {
    setUp(() async {
      await repo.insertDevice(_makeDevice('d1'));
    });

    test('recordEviction appends a row', () async {
      await repo.recordEviction(
        deviceId: 'd1',
        intelUid: 'intel-1',
        reason: 'reviewed',
      );
      final rows = await raw.query('mobile_eviction_history');
      expect(rows, hasLength(1));
      expect(rows[0]['reason'], 'reviewed');
    });

    test('recentlyEvicted respects cooldown cutoff', () async {
      final now = DateTime.now();
      await repo.recordEviction(
        deviceId: 'd1',
        intelUid: 'fresh',
        reason: 'reviewed',
        evictedAt: now.subtract(const Duration(days: 3)),
      );
      await repo.recordEviction(
        deviceId: 'd1',
        intelUid: 'stale',
        reason: 'reviewed',
        evictedAt: now.subtract(const Duration(days: 30)),
      );
      final inWindow =
          await repo.recentlyEvicted(deviceId: 'd1', cooldownDays: 14);
      expect(inWindow, equals({'fresh'}));
    });

    test('recentlyEvicted is per-device', () async {
      await repo.insertDevice(_makeDevice('d2'));
      await repo.recordEviction(
        deviceId: 'd1',
        intelUid: 'a',
        reason: 'reviewed',
      );
      await repo.recordEviction(
        deviceId: 'd2',
        intelUid: 'b',
        reason: 'reviewed',
      );
      final d1 =
          await repo.recentlyEvicted(deviceId: 'd1', cooldownDays: 30);
      final d2 =
          await repo.recentlyEvicted(deviceId: 'd2', cooldownDays: 30);
      expect(d1, equals({'a'}));
      expect(d2, equals({'b'}));
    });
  });

  group('recordEvent origin', () {
    test('defaults to desktop', () async {
      await libRepo.recordEvent(type: 'test_event');
      final events = await libRepo.loadRecentEvents();
      expect(events, hasLength(1));
      expect(events[0].origin, 'desktop');
    });

    test('mobile-sourced events round-trip the device id', () async {
      await libRepo.recordEvent(
        type: 'test_event',
        origin: 'mobile:zico-iphone',
      );
      final events = await libRepo.loadRecentEvents();
      expect(events[0].origin, 'mobile:zico-iphone');
    });

    test('ActivityEvent.fromRow uses default desktop when column NULL',
        () async {
      // Direct row insert without the origin column — simulates a
      // pre-v16 row that survived migration. (Migration default is
      // 'desktop' but ActivityEvent should also be defensive against
      // SELECT shapes that omit it entirely.)
      final ev = ActivityEvent.fromRow(const {
        'id': 1,
        'recorded_at': 0,
        'event_type': 'legacy',
        'path': null,
        'source_id': null,
        'payload': null,
      });
      expect(ev.origin, 'desktop');
    });
  });
}

MobileDevice _makeDevice(
  String deviceId, {
  String friendlyName = 'Zico iPhone',
  DateTime? pairedAt,
}) {
  return MobileDevice(
    deviceId: deviceId,
    friendlyName: friendlyName,
    pairedAt: pairedAt ?? DateTime.now(),
    capacity: const CapacityPolicy.songs(100),
    tokenHash: 'bcrypt-stub-hash',
  );
}

MobileInventoryEntry _makeInventoryEntry(
  String deviceId,
  String intelUid, {
  ResidencyClass residency = ResidencyClass.rotating,
  String syncOrigin = 'manual',
  int priorityRank = 0,
  bool pendingPin = false,
  DateTime? pinnedAt,
}) {
  return MobileInventoryEntry(
    deviceId: deviceId,
    intelUid: intelUid,
    variantId: 'variant-$intelUid',
    contentHash: 'hash-$intelUid',
    residency: residency,
    syncOrigin: syncOrigin,
    priorityRank: priorityRank,
    pinnedAt: pinnedAt,
    pendingPin: pendingPin,
    addedAt: DateTime.now(),
  );
}

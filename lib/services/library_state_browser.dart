import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/operational_state.dart';
import '../models/save_snapshot.dart';
import '../models/state_preview.dart';
import 'library_save_manager.dart';

/// Read-only browser over the `.library` files in a `LibraryRoot`,
/// powering the Load Operational State dialog.
///
/// Two responsibilities:
///   1. `listOperationalStates()` — enumerate every `.library` file
///      under Systems/, Saves/, Shared Libraries/. Pure filesystem
///      stat + filename parsing; no SQLite open. Fast even at
///      hundreds of entries.
///   2. `enrichPreview(state)` — open the selected file READ-ONLY
///      and query a small fixed set of stats. Called lazily when
///      the user clicks a row. One file open per selection.
///
/// **Critical:** this class never modifies the library state. It
/// only reads. The actual swap-and-load happens in the controller
/// (see `LibraryController.loadOperationalState`).
class LibraryStateBrowser {
  final LibraryRoot root;

  LibraryStateBrowser({required this.root});

  /// Enumerate every `.library` file in the library root, grouped
  /// by source category. Returns entries in display order:
  /// current device first, then other devices, then historical
  /// lineage (newest first), then shared libraries.
  ///
  /// Foreign files (anything not matching the expected naming /
  /// extension) are silently skipped — same forgiveness rule as
  /// `LibrarySaveManager.listSnapshots`.
  Future<List<OperationalState>> listOperationalStates({
    required String currentMachineId,
  }) async {
    final out = <OperationalState>[];
    final currentMachineSanitised = SaveSnapshot.sanitiseFilesystemLabel(
      currentMachineId,
      emptyFallback: 'MACHINE',
    );

    // --- Systems/ — device-channel files (current + other) ---
    final systemsDir = Directory(root.systemsDir);
    if (systemsDir.existsSync()) {
      final entries = await systemsDir.list(followLinks: false).toList();
      final systemsList = <OperationalState>[];
      for (final e in entries) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.endsWith('.library')) continue;
        if (name.endsWith('.partial')) continue;
        // Systems/ files are named `{MACHINE}.library` — no
        // double-underscore separators, no timestamp.
        final stem = name.substring(0, name.length - '.library'.length);
        if (stem.contains('__')) continue; // looks like a Saves/ entry, skip
        final stat = e.statSync();
        final isCurrent = stem == currentMachineSanitised;
        systemsList.add(OperationalState(
          filePath: e.path,
          source: isCurrent
              ? OperationalStateSource.currentDevice
              : OperationalStateSource.otherDevice,
          snapshot: null,
          machineId: stem,
          fileSize: stat.size,
          modifiedAt: stat.modified,
        ));
      }
      // Current device first, then other devices alphabetised.
      systemsList.sort((a, b) {
        if (a.source == OperationalStateSource.currentDevice) return -1;
        if (b.source == OperationalStateSource.currentDevice) return 1;
        return a.machineId.compareTo(b.machineId);
      });
      out.addAll(systemsList);
    }

    // --- Saves/ — historical lineage, newest first ---
    final savesDir = Directory(root.savesDir);
    if (savesDir.existsSync()) {
      final entries = await savesDir.list(followLinks: false).toList();
      final lineage = <OperationalState>[];
      for (final e in entries) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final parsed = SaveSnapshot.tryParse(name);
        if (parsed == null) continue;
        final stat = e.statSync();
        lineage.add(OperationalState(
          filePath: e.path,
          source: OperationalStateSource.historicalLineage,
          snapshot: parsed,
          machineId: parsed.machineId,
          fileSize: stat.size,
          modifiedAt: stat.modified,
        ));
      }
      lineage.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      out.addAll(lineage);
    }

    // --- Shared Libraries/ — future cross-device exchange ---
    final sharedDir = Directory(root.sharedLibrariesDir);
    if (sharedDir.existsSync()) {
      final entries = await sharedDir.list(followLinks: false).toList();
      final shared = <OperationalState>[];
      for (final e in entries) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final parsed = SaveSnapshot.tryParse(name);
        if (parsed == null) continue;
        final stat = e.statSync();
        shared.add(OperationalState(
          filePath: e.path,
          source: OperationalStateSource.sharedLibrary,
          snapshot: parsed,
          machineId: parsed.machineId,
          fileSize: stat.size,
          modifiedAt: stat.modified,
        ));
      }
      shared.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      out.addAll(shared);
    }

    return out;
  }

  /// Open the selected `.library` file READ-ONLY and fetch a fixed
  /// set of stats: track count, favorite count, reviewed count,
  /// total plays, last-played timestamp. Returns
  /// [StatePreview.failure] gracefully if the file is from an
  /// incompatible schema version or otherwise unreadable.
  ///
  /// Read-only open intentionally — no migrations run, no chance
  /// of mutating the source file just by inspecting it.
  ///
  /// Reviewed threshold for the count: 10_000 ms (matches the
  /// default `play_threshold_seconds = 10` in the
  /// LibraryController). Preview is a glimpse, not authoritative;
  /// reading the threshold out of each file's own `app_settings`
  /// would be over-engineered for V1.
  Future<StatePreview> enrichPreview(OperationalState state) async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    Database? db;
    try {
      db = await factory.openDatabase(
        state.filePath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final trackCount = await _scalarInt(
        db,
        'SELECT COUNT(*) FROM indexed_files',
      );
      final favoriteCount = await _scalarInt(
        db,
        'SELECT COUNT(*) FROM tracks WHERE favorite = 1',
      );
      final reviewedCount = await _scalarInt(
        db,
        'SELECT COUNT(*) FROM tracks WHERE cumulative_listened_ms >= 10000',
      );
      final totalPlays = await _scalarInt(
        db,
        'SELECT COALESCE(SUM(play_count), 0) FROM tracks',
      );
      final lastPlayedMs = await _scalarInt(
        db,
        'SELECT COALESCE(MAX(last_played_at), 0) FROM tracks',
      );
      DateTime? lastPlayedAt;
      if (lastPlayedMs != null && lastPlayedMs > 0) {
        lastPlayedAt =
            DateTime.fromMillisecondsSinceEpoch(lastPlayedMs);
      }
      return StatePreview(
        trackCount: trackCount,
        favoriteCount: favoriteCount,
        reviewedCount: reviewedCount,
        totalPlays: totalPlays,
        lastPlayedAt: lastPlayedAt,
      );
    } catch (e) {
      debugPrint('[browser] preview failed for ${state.filePath}: $e');
      return StatePreview.failure('Preview unavailable: $e');
    } finally {
      try {
        await db?.close();
      } catch (_) {/* best-effort */}
    }
  }

  Future<int?> _scalarInt(Database db, String sql) async {
    final rows = await db.rawQuery(sql);
    if (rows.isEmpty) return null;
    final value = rows.first.values.first;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

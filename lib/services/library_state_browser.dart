import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/activity_event.dart';
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
  /// set of stats + recent activity. The preview is the right pane
  /// of the Load Operational State dialog — it's user-facing, NOT
  /// developer diagnostics. Each individual query is wrapped in its
  /// own try/catch so a schema mismatch on ONE column doesn't
  /// torpedo the entire preview. Raw SQL exception strings are
  /// kept out of `errorMessage` — users see a calm "Some details
  /// unavailable" if absolutely necessary, never an SqliteException
  /// dump.
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
      // CRITICAL: `singleInstance: false` here. sqflite defaults to
      // `singleInstance: true`, which means opening the same file
      // path twice returns the SAME Database object — and closing
      // this preview handle would also close the running app's
      // live DB. Forcing a separate instance for the read-only
      // inspection means our `.close()` in finally only touches
      // our own handle, never the live one.
      //
      // The current-device state file IS the running app's live
      // DB, so this case is the most common collision path. With
      // singleInstance:false the read-only peek is isolated.
      db = await factory.openDatabase(
        state.filePath,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false,
        ),
      );
    } catch (e) {
      debugPrint('[browser] open failed for ${state.filePath}: $e');
      // The file is fundamentally unreadable — not a stats issue,
      // it's that we can't open it at all. User-facing message
      // stays generic; the raw exception goes to debug logs.
      return const StatePreview.failure('Could not read this state file.');
    }
    try {
      // Each scalar query is independently safe — a missing column
      // on an older schema produces null for THAT stat only, the
      // rest still render. This is the "preview gracefully degrades"
      // contract.
      final trackCount = await _scalarIntSafe(
        db,
        'SELECT COUNT(*) FROM indexed_files',
      );
      final favoriteCount = await _scalarIntSafe(
        db,
        'SELECT COUNT(*) FROM tracks WHERE favorite = 1',
      );
      final reviewedCount = await _scalarIntSafe(
        db,
        'SELECT COUNT(*) FROM tracks WHERE cumulative_ms >= 10000',
      );
      final totalPlays = await _scalarIntSafe(
        db,
        'SELECT COALESCE(SUM(play_count), 0) FROM tracks',
      );
      final lastPlayedMs = await _scalarIntSafe(
        db,
        'SELECT COALESCE(MAX(last_played_at), 0) FROM tracks',
      );
      DateTime? lastPlayedAt;
      if (lastPlayedMs != null && lastPlayedMs > 0) {
        lastPlayedAt =
            DateTime.fromMillisecondsSinceEpoch(lastPlayedMs);
      }
      // Operational activity — the right pane's narrative. Same
      // per-query safety: a missing `events` table on an older
      // schema produces null (UI renders "No recorded activity")
      // rather than failing the whole preview.
      List<ActivityEvent>? recentEvents;
      try {
        final eventRows = await db.rawQuery(
          'SELECT id, recorded_at, event_type, path, source_id, payload '
          'FROM events '
          'ORDER BY recorded_at DESC, id DESC '
          'LIMIT 25',
        );
        recentEvents = eventRows.map(ActivityEvent.fromRow).toList();
      } catch (e) {
        debugPrint(
          '[browser] events table unavailable for ${state.filePath}: $e',
        );
        recentEvents = null;
      }
      return StatePreview(
        trackCount: trackCount,
        favoriteCount: favoriteCount,
        reviewedCount: reviewedCount,
        totalPlays: totalPlays,
        lastPlayedAt: lastPlayedAt,
        recentEvents: recentEvents,
      );
    } finally {
      try {
        await db.close();
      } catch (_) {/* best-effort */}
    }
  }

  /// Per-query safe scalar fetch. Returns null on ANY failure —
  /// missing column, syntax error, locked file — without
  /// propagating the exception. Callers treat null as "stat
  /// unavailable" and render "—".
  Future<int?> _scalarIntSafe(Database db, String sql) async {
    try {
      final rows = await db.rawQuery(sql);
      if (rows.isEmpty) return null;
      final value = rows.first.values.first;
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    } catch (e) {
      debugPrint('[browser] scalar query failed: $sql — $e');
      return null;
    }
  }
}

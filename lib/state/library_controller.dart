import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show
    AppLifecycleState,
    WidgetsBinding,
    WidgetsBindingObserver;
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:shared_core/shared_core.dart';
import 'package:uuid/uuid.dart';

import '../models/intelligence_record.dart';
import '../models/reconciliation_summary.dart';
import '../models/source.dart';
import '../models/activity_event.dart';
import '../models/track.dart';
import '../widgets/delete_track_dialog.dart' show DeleteDecision;
import '../services/audio_scanner.dart';
import '../services/content_hash.dart';
import '../services/content_hash_backfill.dart';
import '../models/operational_state.dart';
import '../services/intelligence_export.dart';
import '../services/library_repository.dart';
import '../services/library_save_manager.dart';
import '../services/media_keys.dart';
import '../services/metadata_extractor.dart';
import '../services/mobile_sync/mobile_device.dart';
import '../services/mobile_sync/mobile_sync_repository.dart';
import '../services/mobile_sync/sync_orchestrator.dart';
import '../services/mobile_sync/sync_session_store.dart';
import '../services/playback_engine.dart';
import '../services/trash.dart';
import '../utils/aggregated_track_view.dart';
import '../utils/key_normalizer.dart';
import '../utils/song_identity.dart';

enum TrackSortColumn {
  favorite,
  reviewed,
  title,
  artist,
  bpm,
  key,
  duration,
  format,
  plays,
  lastPlayed,
}

enum PlaybackMode { sequential, shuffle, shuffleUnreviewed }

extension PlaybackModeView on PlaybackMode {
  String get label {
    switch (this) {
      case PlaybackMode.sequential:
        return 'SEQ';
      case PlaybackMode.shuffle:
        return 'SHUF';
      case PlaybackMode.shuffleUnreviewed:
        return 'UNREV';
    }
  }
}

class LibraryController extends ChangeNotifier {
  final PlaybackEngine engine;
  final LibraryRepository repo;
  /// Owns the `Saves/` directory and the snapshot lifecycle. Null
  /// in tests that don't exercise the save path — production
  /// passes one from `main.dart`.
  final LibrarySaveManager? saveManager;
  /// Filesystem layout for this library — used by the controller
  /// to address `Current/CURRENT.library` for mtime checks before
  /// snapshotting. Null in tests when `saveManager` is also null.
  final LibraryRoot? libraryRoot;

  /// Mobile-sync persistence layer (PR2.6.B). Null in tests that
  /// don't exercise the companion-device surfaces — production
  /// wires one from `main.dart` alongside the HTTP server. When
  /// null, [pinTracksToDevice] and [pairedDevicesListenable]
  /// behave as no-ops (empty list, silent return) so the rest of
  /// the desktop UI keeps working unaltered.
  final MobileSyncRepository? mobileSync;
  final Uuid _uuid = const Uuid();

  static const _recentBufferCapacity = 8;
  static const _trailVisibleCount = 5;
  // Bigger batches when files are local — fewer `compute()`
  // spawn round-trips per file, more files per isolate. The
  // earlier 25 was sized for slow Dropbox cloud-only reads where
  // a single hung file would block 24 others; now that the
  // library is local, the per-file cost is small enough that
  // batching 50 cuts the scheduling overhead roughly in half.
  static const _metadataBatchSize = 50;

  final List<Source> _sources = [];
  final List<Track> _tracks = [];
  // O(1) lookups keyed by uid / path. Kept consistent with [_tracks]
  // by [_replaceTracks] / [_removeTracksWhere]. Without these,
  // `_trackByUid` / `_trackByPath` would do linear scans over ~12k
  // entries on every row click, every metadata batch, every
  // currentTrack getter — which adds up fast in the play/scan path.
  final Map<String, Track> _tracksByUid = {};
  final Map<String, Track> _tracksByPath = {};
  final List<String> _recentReviewedUids = [];
  // Viewport-driven enrichment queue. Per the reactive-first
  // architecture, scan completion and hydrate do NOT auto-populate
  // this queue — only intent-driven entry points do
  // (`reportViewportPaths`, `enrichOnDemand`). Untouched files
  // remain at filename-only display indefinitely; the
  // filename-parsing fallback covers them. The companion Set keeps
  // dedup O(1) so fast-scrolling viewport reports don't pile up
  // duplicate work.
  final List<String> _enrichmentQueue = [];
  final Set<String> _inEnrichmentQueue = {};
  bool _metadataProcessing = false;
  // Progress counters for the global status bar. Reset each time
  // the queue fully drains. `_metadataTotalThisRun` grows when more
  // paths are enqueued mid-processing.
  int _metadataDoneThisRun = 0;
  int _metadataTotalThisRun = 0;

  String? _selectedSourceId;
  String _searchQuery = '';
  bool _unreviewedOnly = false;
  bool _showArtwork = false;
  bool _isScanning = false;
  TrackSortColumn _sortColumn = TrackSortColumn.title;
  bool _sortAscending = true;
  // Index into `formatSortLeads` — which format leads the FORMAT
  // column's sort order. Cycles 0..N on each header click while
  // FORMAT is the active sort column. Other columns ignore it.
  int _sortFormatMode = 0;

  String? _currentTrackUid;
  // Path of the file the engine is actually playing. Held alongside
  // `_currentTrackUid` because a track-intelligence object can have
  // multiple physical instances behind one uid (true byte-identical
  // clones share a uid). Show-in-Finder uses this to reveal the exact
  // file being played, not just any sibling — see also the resolver
  // in `_revealInFinderWithFallback`.
  String? _currentTrackPath;
  String? _selectedTrackUid;
  // Transient "this track's play session just crossed the threshold"
  // marker. Set when [_sessionListened] reaches the threshold during
  // playback; cleared the moment a new track starts. Drives the
  // momentary row highlight in the track table — appears as a fade-in
  // flash (animated by the row's AnimatedContainer) and stays until
  // the next track plays. NOT a persistent "reviewed" indicator —
  // that's `track.reviewed` and surfaces in the REV cell.
  String? _justReviewedUid;
  PlaybackMode _playbackMode = PlaybackMode.sequential;
  final Random _rng = Random();
  bool _isPlaying = false;
  // True from the moment `play(uid)` calls `engine.setTrack(...)`
  // until that future resolves (or throws). Used by the playback
  // bar to swap the play icon for a spinner while a Dropbox-backed
  // file is materialising — without this, the user sees nothing
  // happen for several seconds on cloud-only files.
  bool _isLoadingTrack = false;
  Duration _lastTickPosition = Duration.zero;
  Duration _sessionListened = Duration.zero;
  bool _sessionPlayCounted = false;
  int _playThresholdSeconds = 10;
  double _volume = 1.0;
  final ValueNotifier<double> volumeListenable = ValueNotifier<double>(1.0);

  bool _sidebarVisible = true;
  double _sidebarWidth = 260;
  static const double sidebarMinWidth = 200;
  static const double sidebarMaxWidth = 360;

  final MediaKeysBridge _media = MediaKeysBridge();

  // Utility columns: locked widths.
  // Defaults sized for "label + 12px horizontal padding (6 each
  // side) + a few px of breathing room". Headers are static (no
  // sort arrow, no dynamic rewrites), so there's no reserved-glyph
  // slot to account for. LAST is sized for the M/D/YY data form
  // ("12/31/24" is the widest), not its 4-char header.
  double _colFavWidth = 36;
  double _colRevWidth = 48;
  double _colBpmWidth = 50;
  double _colKeyWidth = 50;
  double _colTimeWidth = 56;
  // Wide enough to fit aggregated `MP3 · AIFF` style labels comfortably
  // when grouping is on, plus the expand-chevron prefix.
  // FORMAT default sized for pair combos like "MP3 · WAV" /
  // "MP3 · FLAC" — the W in WAV is unusually wide so the 9-char
  // string needs noticeably more room than 4-char "MP3" alone.
  // Triple/quad combos still ellipsize; users can drag wider.
  double _colFormatWidth = 96;
  double _colPlaysWidth = 60;
  // 140 fits "M/D/YY · H:MM AM" comfortably. Was 68 before the
  // 2026-05-15 enrichment that added time-of-day; the old width
  // would truncate the new format. Users who customised the
  // column before this change keep their persisted value.
  double _colLastPlayedWidth = 140;
  // Text columns: persisted absolute widths.
  double _colTitleWidth = 350;
  double _colArtistWidth = 240;

  static const List<String> _defaultColumnOrder = [
    'fav',
    'rev',
    'title',
    'artist',
    'bpm',
    'key',
    'time',
    'format',
    'plays',
    'lastPlayed',
  ];
  List<String> _columnOrder = List.of(_defaultColumnOrder);

  // ---------------------------------------------------------------------
  // Utility-rail order + lock
  // ---------------------------------------------------------------------
  // The right-edge utility rail's middle section is user-reorderable.
  // Volume stays pinned at the top (not in this list); these are the
  // reorderable cards beneath it. Persisted as a comma-joined string
  // under `utility_rail_order`. Unknown keys are dropped at hydrate;
  // missing keys are appended in their default-order position.
  static const _defaultUtilityRailOrder = <String>[
    'threshold',
    'mode',
    'audit',
    'history',
    'movecopy',
    'finder',
    'loadstate',
  ];
  List<String> _utilityRailOrder = List.of(_defaultUtilityRailOrder);
  // When locked, drag handles are hidden and reordering is disabled.
  // Persisted as '0' / '1' under `utility_rail_locked`.
  bool _utilityRailLocked = false;

  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<int> _revealTick = ValueNotifier(0);

  int _libraryVersion = 0;
  List<Track>? _visibleCache;
  int _visibleCacheVersion = -1;
  int? _lockedCurrentIndex;

  // The visible-tracks pipeline always collapses each song-identity
  // bucket into a single primary row (lowest-quality format wins —
  // MP3 > FLAC > WAV > AIFF). Siblings never appear as their own
  // table rows; the user reaches them via the right-click "Show in
  // Finder" submenu (one item per variant) and via aggregated cell
  // values on the primary row.
  //
  // Side-table built each pipeline run: lookup from primary's uid
  // → the bucket's AggregatedTrackView so the table can render
  // aggregated cells (sum plays, blank-on-disagreement BPM/key,
  // FORMAT label) and the context-menu can enumerate variants
  // without re-grouping on every row build.
  Map<String, AggregatedTrackView> _bucketsByPrimaryUid =
      const <String, AggregatedTrackView>{};

  // Cached per-source counts. Sidebar build calls
  // `sourceTrackCount(sourceId)` once per tile; without this cache
  // each call walked all ~12k tracks (and for sub-views, also
  // string-prefixed every path). Now we recompute the whole map
  // once per `_libraryVersion` change and answer subsequent calls
  // in O(1).
  // Per-source operational stats. One cached snapshot covers
  // sidebar tile counts (`total`) AND status-bar contextual
  // progress (`ready`, `enriching`, `waitingOnCloud`). All
  // populated by a single walk of `_tracks` in
  // `_computeAllSourceCounts`, so adding the new fields didn't
  // introduce a second iteration pass — same O(N × subViews)
  // cost, more useful output.
  //
  // Sub-views increment the same stats record as their parent's
  // walk via the existing path-prefix branch, so progress inside
  // a sub-view (e.g., Q under Afro:Tech:Deep) reflects only the
  // tracks under that prefix — matching the user's mental scope.
  Map<String, _SourceStats>? _sourceStatsCache;
  int _sourceStatsCacheVersion = -1;

  // Cached library-wide tallies for the always-on status bar:
  // enriched (any metadata extracted), missing (rows surviving the
  // last scan as `is_available=0`), song count (distinct song-
  // identities — same canonical bucket the variant collapse uses),
  // and reviewed song count (a song is reviewed if ANY variant
  // crossed the cumulative-listen threshold). Recomputed on
  // `_libraryVersion` change.
  int? _enrichedCountCache;
  int? _enrichingCountCache;
  int? _failedEnrichmentCountCache;
  int? _missingCountCache;
  int? _movedCountCache;
  // Paths of rows whose `availability_state == 'missing'` AND whose
  // content_hash is also present on at least one `available` row
  // anywhere in the library — i.e. the bytes survived elsewhere, the
  // missing row is just the trailing record at the old path. These
  // are NOT counted toward `missingCount` (would falsely alarm the
  // user that data was lost) and are folded into `movedCount` /
  // surfaced under the MOVED section of the Review dialog.
  //
  // Strict content_hash match — fingerprint coincidences don't
  // count. Computed in the same pass as the other stats in
  // `_ensureLibraryStats`.
  Set<String>? _coexistingMissingPathsCache;
  int? _songCountCache;
  int? _reviewedSongCountCache;
  int _libraryStatsVersion = -1;

  // Set while a metadata wave is in flight: a representative
  // filename from the current batch. Surfaced in the status bar so
  // the user can see exactly what file is being processed instead
  // of just an opaque counter.
  String? _currentEnrichmentLabel;
  String? _currentEnrichmentPath;

  /// Wall-clock time of the last [_applyMetadata] completion.
  /// Drives the "waiting on cloud" surfacing for the metadata
  /// pipeline — if [_metadataProcessing] is true but no path has
  /// completed in N seconds, isolates are almost certainly blocked
  /// on Dropbox / iCloud placeholder materialization. Updates
  /// every notify, so the elapsed-since-last-completion read in
  /// `enrichmentSinceLastCompletion` is accurate to ~1 s.
  DateTime? _lastEnrichmentCompletionAt;

  /// Stale-threshold for the metadata pipeline. A foreground
  /// scan finishes batch-of-50 local files in under a second; if
  /// nothing's landed in 5 s the isolates are stuck in cloud-
  /// materialisation purgatory and the status bar should narrate
  /// that explicitly instead of looking frozen at `0 / 170`.
  static const Duration _enrichmentStallThreshold = Duration(seconds: 5);

  /// `null` when no enrichment has run yet OR the pipeline is
  /// idle. Otherwise: time elapsed since the last successful
  /// `_applyMetadata`. The status bar uses this to flip to a
  /// "waiting on cloud" label once the duration exceeds the
  /// stall threshold.
  Duration? get enrichmentSinceLastCompletion {
    final at = _lastEnrichmentCompletionAt;
    if (at == null) return null;
    return DateTime.now().difference(at);
  }

  /// `true` while the enrichment pipeline is actively processing
  /// but hasn't completed a single path in [_enrichmentStallThreshold].
  /// Drives the cloud-wait status-bar label so the user sees the
  /// reason (Dropbox materialising files) instead of a frozen
  /// `Enriching 0 / 170`.
  bool get isEnrichmentStalled {
    if (!_metadataProcessing) return false;
    final since = enrichmentSinceLastCompletion;
    if (since == null) return false;
    return since >= _enrichmentStallThreshold;
  }

  /// Best-effort cloud-provider label derived from the in-flight
  /// enrichment file. Reads the full path (not just the basename)
  /// because the cloud-host marker lives in the parent directory
  /// tree (`/Library/CloudStorage/Dropbox-…` etc.). Same detection
  /// set as the hash backfill's cloud-label.
  String get currentEnrichmentCloudLabel {
    final p = _currentEnrichmentPath ?? '';
    if (p.contains('/Library/CloudStorage/Dropbox')) return 'Dropbox';
    if (p.contains('/Library/CloudStorage/GoogleDrive')) return 'Google Drive';
    if (p.contains('/Library/CloudStorage/OneDrive')) return 'OneDrive';
    if (p.contains('/Library/Mobile Documents')) return 'iCloud';
    return 'cloud';
  }

  // Files whose tag-parser failed (audio_metadata_reader threw, or
  // returned no parseable header). We remember them at session
  // scope so a fast viewport scroll over the same region doesn't
  // re-enqueue them on every scroll-end, which would otherwise
  // pile the queue forever and exaggerate "Enriching" totals.
  final Set<String> _failedEnrichmentPaths = {};

  // Source-level existence ontology. Distinct from per-track
  // availability — the source is the *watched root* and can be
  // healthy / missing independently of any individual file. A
  // source whose `folder_path` no longer exists on disk (folder
  // deleted in Finder, external drive ejected, Dropbox folder
  // unlinked) should NOT appear healthy in the sidebar; users
  // need to see "Z CRATE · Folder missing" so the missing-source
  // tracks they're seeing in the table read as recoverable
  // (remount the drive, restore the folder) rather than corrupt
  // (something is wrong with the app).
  //
  // Stored as a Set rather than mutating each Source object so
  // the existence check stays cheap to re-run and the persistent
  // Source record continues to reflect "this is what the user
  // configured" — not a transient runtime condition. Sub-views
  // inherit their parent's state and never appear in this set
  // themselves.
  final Set<String> _missingFolderSourceIds = {};

  // Per-source filesystem watchers. Each watcher fires on any
  // create / modify / delete inside the source folder (recursive
  // when the source's scan mode is recursive).
  //
  // Events are coalesced via **quiescence detection**: the debounce
  // timer is reset on every event so the rescan only fires after
  // [_watcherQuietWindow] of silence. Crucial for cloud-storage
  // paths (Dropbox / iCloud / CloudStorage) where a single user
  // action can produce a stream of FSEvents lasting tens of seconds.
  // An "every N seconds" debounce would fire mid-storm and force
  // repeated rescans; quiescence-based fires exactly once per storm.
  //
  // [_watcherMaxQuietWait] is the hard ceiling — even an active
  // sync that never quiets gets a rescan eventually so the library
  // doesn't go stale.
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final Map<String, Timer> _watcherDebounce = {};
  final Map<String, DateTime> _watcherFirstEventAt = {};
  static const _watcherQuietWindow = Duration(seconds: 3);
  static const _watcherMaxQuietWait = Duration(seconds: 30);

  // Throttle for the post-scan lifecycle save. A scan completion
  // is a meaningful checkpoint, but during a cloud-sync storm we
  // can complete a scan every 3-5 seconds and don't need to
  // rewrite the multi-MB library file each time. One save per
  // window is plenty — the autosave tick covers gaps.
  DateTime? _lastPostScanSnapshotAt;
  static const _postScanSnapshotInterval = Duration(minutes: 2);

  // App-lifecycle observer. macOS sends `resumed` when the user
  // brings the app to foreground (e.g., Cmd+Tab back from Finder).
  // Belt-and-suspenders rescan covers the case where the per-source
  // filesystem watcher missed an event — Finder's "Move to Trash"
  // sometimes produces atypical FSEvents that `Directory.watch`
  // doesn't always surface reliably.
  late final _LifecycleObserver _lifecycleObserver = _LifecycleObserver(
    (state) {
      if (state == AppLifecycleState.resumed) _rescanAllOnFocus();
    },
  );
  bool _lifecycleObserverRegistered = false;
  bool _focusRescanInFlight = false;

  // Throttle notifyListeners() during phase-2 metadata enrichment.
  // Without this, each 100-file batch triggered a full UI rebuild +
  // visible-cache invalidation + 12k-element re-sort. With ~25
  // batches per large folder, that's ~25 sorts of the entire
  // library back-to-back. We coalesce to at most one notification
  // every 500ms so the UI stays responsive while the queue drains.
  Timer? _throttledNotifyTimer;
  DateTime _lastThrottledNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<ProcessingState>? _processingSub;

  Timer? _flushTimer;

  // Save / autosave state — populated by [hydrate] from `app_settings`.
  // Defaults are sensible-for-fresh-install; the user can override
  // any of them later via settings.
  String _libraryName = 'LIBRARY';
  String _machineId = 'MACHINE';

  /// Resolved machine identity for this device, as known to the
  /// controller. Mirrors `app_settings.machine_id` (with hostname
  /// fallback) and is kept in sync with the filesystem-level
  /// `LibraryRoot/machine_id.txt`. Used by widgets that need to
  /// distinguish "this device's state" from other devices' (see
  /// the Load Operational State dialog).
  String get machineId => _machineId;

  /// Resolved library name — the user's whole music universe
  /// identity (e.g. `NEOMAC_LIBRARY`). Defaults to `LIBRARY` for
  /// fresh installs; user can rename via the `library_name`
  /// app_settings key.
  String get libraryName => _libraryName;
  bool _autosaveEnabled = true;
  int _autosaveIntervalMinutes = 3;
  Timer? _autosaveTimer;
  /// mtime of `Current/CURRENT.library` at the moment of the most
  /// recent snapshot. The autosave tick reads the current mtime
  /// and skips the snapshot if it hasn't advanced — cheap dirty-
  /// check that avoids 20 identical files when nothing changed.
  DateTime? _lastSnapshotDbMtime;

  // Lightweight operational-journal accumulators. Counters
  // increment as user actions happen; at every `_snapshotNow`
  // tick the non-zero values are flushed into the `events` table
  // as aggregate entries (e.g. `tracks_played` with
  // `{"count": 14}`), then reset. Drives the "Changes in this
  // save period" narrative in the Load Operational State dialog
  // without building full event sourcing. See `activity_event.dart`
  // EventType.tracksPlayed / favoritesAdded.
  int _playsSinceSnapshot = 0;
  int _favoritesAddedSinceSnapshot = 0;

  LibraryController({
    required this.engine,
    required this.repo,
    this.saveManager,
    this.libraryRoot,
    this.mobileSync,
    SyncSessionStore? sessionStore,
  }) : _sessionStore = sessionStore {
    _backfillWorker = ContentHashBackfillWorker(
      repo,
      onProgress: _onBackfillProgress,
      onHashStart: _onBackfillHashStart,
      onHashEnd: _onBackfillHashEnd,
    );
    _positionSub = engine.positionStream.listen(_onPosition);
    _playingSub = engine.playingStream.listen(_onPlaying);
    _durationSub = engine.durationStream.listen(_onDuration);
    _processingSub = engine.processingStateStream.listen(_onProcessing);
    _wireMediaBridge();
  }

  /// Owns the `sync_sessions` lifecycle (PR2.6.A). Optional in
  /// tests; production injects from `main.dart`. When null the
  /// `pairedDevicesListenable` resolves devices to
  /// [ActiveSyncSessionState] = `null` (i.e., never `syncing` /
  /// `awaitingApproval`) — heartbeat math drives the state.
  final SyncSessionStore? _sessionStore;
  SyncSessionStore? get sessionStore => _sessionStore;

  /// The state-machine driver for a single sync handshake
  /// (PR2.6.C). Lazily constructed the first time a UI / endpoint
  /// requests it, so tests that don't exercise sync don't pay
  /// the wiring cost. The floating progress window binds to
  /// `syncOrchestrator.activeSessionListenable` directly.
  ///
  /// Null when [_sessionStore] is null (no session lifecycle at
  /// all in this controller instance).
  SyncOrchestrator? _syncOrchestrator;
  SyncOrchestrator? get syncOrchestrator {
    final store = _sessionStore;
    if (store == null) return null;
    if (_syncOrchestrator == null) {
      _syncOrchestrator = SyncOrchestrator(sessionStore: store);
      // Q1 contract — sync is a playback-exclusive maintenance
      // window. Watch the orchestrator's active session and
      // pause the engine the moment a non-terminal session
      // appears; let the engine become playable again when the
      // session clears (orchestrator.clearActive() fires after
      // the RotationSummary dismiss timer).
      _syncOrchestrator!.activeSessionListenable
          .addListener(_onSyncSessionChanged);
    }
    return _syncOrchestrator;
  }

  /// Q1 — true while a non-terminal sync session is in flight.
  /// `play()` refuses to start a track while this is true; UI
  /// surfaces (deck buttons, keyboard shortcuts) consult it to
  /// disable controls. Pure derivation from the orchestrator's
  /// snapshot — no separate state to keep in sync.
  bool get isPlaybackBlockedBySync {
    final orchestrator = _syncOrchestrator;
    if (orchestrator == null) return false;
    return isSyncBlockingPlayback(orchestrator.activeSession);
  }

  void _onSyncSessionChanged() {
    if (isPlaybackBlockedBySync && _isPlaying) {
      // Pause the engine the moment a session begins. The
      // engine.pause() call ripples through to _onPlaying which
      // updates _isPlaying; from then on play() refuses until
      // the session terminates and the snapshot clears.
      unawaited(engine.pause());
    }
    // Notify so any widget keying off this controller redraws —
    // deck play button can grey out, keyboard shortcuts can
    // refuse, the SyncProgressWindow can render.
    notifyListeners();
  }

  /// Snapshot of paired devices + their derived operational
  /// state. Refreshed by [refreshPairedDevices], typically on a
  /// short interval from the sidebar panel. UI binds via
  /// `ValueListenableBuilder`.
  final ValueNotifier<List<DeviceWithState>> _pairedDevicesNotifier =
      ValueNotifier<List<DeviceWithState>>(const []);
  ValueListenable<List<DeviceWithState>> get pairedDevicesListenable =>
      _pairedDevicesNotifier;

  /// Re-fetch paired devices + their active sessions and recompute
  /// operational state. Idempotent. Cheap — runs three small queries.
  /// No-op when [mobileSync] is null.
  Future<void> refreshPairedDevices() async {
    final ms = mobileSync;
    if (ms == null) return;
    final devices = await ms.listDevices();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final entries = <DeviceWithState>[];
    for (final d in devices) {
      ActiveSyncSessionState? activeState;
      if (_sessionStore != null) {
        final active = await _sessionStore.activeForDevice(d.deviceId);
        if (active != null) {
          activeState = _activeSessionStateFor(active.currentState);
        }
      }
      final state = deriveDeviceState(
        lastSeenAt: d.lastSeenAt?.millisecondsSinceEpoch,
        now: nowMs,
        activeSessionState: activeState,
      );
      entries.add(DeviceWithState(device: d, state: state));
    }
    _pairedDevicesNotifier.value = entries;
  }

  ActiveSyncSessionState? _activeSessionStateFor(SyncState s) {
    switch (s) {
      case SyncState.negotiating:
      case SyncState.approving:
        return ActiveSyncSessionState.awaitingApproval;
      case SyncState.preparingManifest:
      case SyncState.preparingTransports:
      case SyncState.transferring:
      case SyncState.receivingTelemetry:
      case SyncState.applyingTelemetry:
      case SyncState.finalizingRotation:
        return ActiveSyncSessionState.syncing;
      case SyncState.idle:
      case SyncState.rotationComplete:
      case SyncState.approvalDeclined:
      case SyncState.transferFailed:
      case SyncState.networkLost:
        return null;
    }
  }

  /// Pin one or more tracks to a paired device. Mutates the
  /// device's `mobile_sync_inventory` rows with `residency='pinned'`
  /// — the manifest builder picks them up on the next sync. Does
  /// NOT initiate a transfer; pinning is residency-intent
  /// mutation, not orchestration. Per the PR2.6 contract: the
  /// manifest builder remains the canonical inventory authority.
  ///
  /// Idempotent — re-pinning the same intel_uid for the same
  /// device replaces the row (no duplicate inventory entries).
  /// Returns the count of rows written.
  Future<int> pinTracksToDevice({
    required String deviceId,
    required List<String> intelUids,
  }) async {
    final ms = mobileSync;
    if (ms == null || intelUids.isEmpty) return 0;
    final now = DateTime.now();
    var written = 0;
    for (final intelUid in intelUids) {
      final track = _tracks.firstWhere(
        (t) => t.intelUid == intelUid,
        orElse: () => Track(
          uid: '',
          fingerprint: '',
          path: '',
          filename: '',
          sourceId: '',
          title: '',
        ),
      );
      if (track.uid.isEmpty) continue;
      if (track.contentHash == null || track.contentHash!.isEmpty) {
        // Tracks without content_hash can't be pinned — the
        // manifest builder would reject them at eligibility-
        // filter time. Skip silently here so the UI can surface
        // "N of M pinned" without a confusing partial error.
        continue;
      }
      await ms.upsertInventory(MobileInventoryEntry(
        deviceId: deviceId,
        intelUid: intelUid,
        variantId: track.uid,
        contentHash: track.contentHash!,
        residency: ResidencyClass.pinned,
        syncOrigin: 'manual',
        priorityRank: 100,
        pinnedAt: now,
        addedAt: now,
      ));
      written++;
    }
    await refreshPairedDevices();
    notifyListeners();
    return written;
  }

  /// Drop a single intel_uid from a device's pinned inventory.
  /// Idempotent — removing a row that doesn't exist is a no-op.
  Future<void> unpinTrackFromDevice({
    required String deviceId,
    required String intelUid,
  }) async {
    final ms = mobileSync;
    if (ms == null) return;
    await ms.removeFromInventory(deviceId, intelUid);
    await refreshPairedDevices();
    notifyListeners();
  }

  /// content_hash backfill — see `services/content_hash_backfill.dart`.
  /// Owned here so the controller can pause it cleanly around
  /// foreground scans and surface its progress.
  late final ContentHashBackfillWorker _backfillWorker;

  /// Cumulative rows hashed in the most-recent (or in-flight)
  /// backfill session. Read by the status bar to show progress.
  int get backfillHashedThisSession => _backfillHashedThisSession;
  int _backfillHashedThisSession = 0;

  /// Live count of rows still pending — drives the determinate
  /// "N / total" display in the status bar. Sampled by the worker
  /// at the start of every batch so it stays current even as a
  /// concurrent scan inserts new NULL-hash rows. `null` until the
  /// first progress tick lands.
  int? get backfillRemaining => _backfillRemaining;
  int? _backfillRemaining;

  bool get isBackfillingContentHashes => _backfillWorker.isRunning;

  // ── Reconciliation summary ─────────────────────────────────────
  // Transient state representing "what just happened in the
  // library." Set when a scan marks a non-trivial number of rows
  // missing (e.g., a crate folder was deleted in Finder). The
  // banner widget reads this getter and renders a calm,
  // auto-dismissing operational narration:
  //
  //   Q removed
  //   38 preserved through other folders
  //   142 tracks removed from view
  //
  // Preserved-count is shown BEFORE removed-count by deliberate
  // UX choice — users emotionally anchor to loss first, so leading
  // with what survived reframes the operation as curated
  // progression rather than data destruction.
  //
  // Auto-clears after [_reconciliationDismissAfter]; the user can
  // also dismiss earlier via [dismissReconciliationSummary]. Only
  // one summary at a time — a second scan landing while a banner
  // is still on-screen replaces it.
  ReconciliationSummary? _reconciliationSummary;
  Timer? _reconciliationTimer;

  /// How long the reconciliation banner stays on-screen before
  /// auto-dismissing. Long enough to read the counts, short enough
  /// not to outstay its welcome during active workflow.
  static const Duration _reconciliationDismissAfter =
      Duration(seconds: 12);

  /// The current "what just happened" summary, or `null` when
  /// nothing is pending. Widgets listening to the controller
  /// surface this in a transient banner.
  ReconciliationSummary? get reconciliationSummary =>
      _reconciliationSummary;

  /// Manual dismiss (X button on the banner). Cancels the
  /// auto-dismiss timer too.
  void dismissReconciliationSummary() {
    if (_reconciliationSummary == null) return;
    _reconciliationSummary = null;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
    notifyListeners();
  }

  void _surfaceReconciliationSummary(
    Source source,
    ReconciliationDelta delta,
  ) {
    _reconciliationSummary = ReconciliationSummary(
      sourceName: source.displayName,
      removed: delta.removed,
      preservedElsewhere: delta.preservedElsewhere,
      surfacedAt: DateTime.now(),
    );
    _reconciliationTimer?.cancel();
    _reconciliationTimer = Timer(_reconciliationDismissAfter, () {
      // Defensive — `dismissReconciliationSummary` clears the
      // timer too; we re-check the field in case a manual dismiss
      // races with the auto-fire.
      if (_reconciliationSummary?.surfacedAt ==
          _reconciliationSummary?.surfacedAt) {
        _reconciliationSummary = null;
        _reconciliationTimer = null;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// `true` while the backfill worker is suspended for active
  /// playback. The status bar uses this to swap the label from
  /// `Hashing audio` → `Hashing audio · paused for playback` so
  /// the user can see the system is deliberately yielding, not
  /// stalled. The denominator + done count stay frozen at their
  /// last-tick values so the bar reads consistently across the
  /// pause window.
  bool get isBackfillPaused => _backfillWorker.isPaused;

  // Single-file hash tracking. Drives the "Waiting on cloud" hint
  // — a Dropbox / iCloud dataless placeholder commonly blocks the
  // file read for 10–30 seconds while macOS materialises it. With
  // a one-line label swap (and live elapsed counter) the wait
  // reads as deliberate hydration rather than a frozen worker.
  String? _currentHashPath;
  DateTime? _currentHashStartedAt;
  Timer? _currentHashTicker;

  /// Elapsed time since the in-flight hash started, or `null` if
  /// nothing is currently being hashed. The status bar uses this
  /// to (a) decide whether to swap to the cloud-waiting label
  /// (once the threshold elapses) and (b) render the live elapsed
  /// seconds counter ("Waiting on Dropbox · 14s · file.mp3").
  Duration? get currentHashElapsed {
    final at = _currentHashStartedAt;
    if (at == null) return null;
    return DateTime.now().difference(at);
  }

  /// Display label for the currently-hashing path (basename only).
  /// `null` when nothing is in flight. Plain `track.filename` would
  /// suffice for paths we already know about; for paths discovered
  /// mid-session the tracks map may not be populated yet, so we
  /// derive the basename from the raw path directly.
  String? get currentHashFilename {
    final p = _currentHashPath;
    if (p == null) return null;
    final i = p.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? p : p.substring(i + 1);
  }

  /// Patience threshold. A hash that's been running this long is
  /// almost certainly waiting on cloud-storage materialisation
  /// (typical local SSD reads of 512 KB complete in <50 ms).
  /// Below this the existing `Hashing audio` label is fine; above
  /// it the user benefits from explicit "we're hydrating from
  /// cloud" framing.
  static const Duration _cloudWaitThreshold = Duration(seconds: 5);

  /// `true` when a single-file hash has been in flight longer than
  /// the patience threshold. The status bar uses this to swap to
  /// the cloud-waiting label.
  bool get isWaitingOnCloud {
    final e = currentHashElapsed;
    return e != null && e >= _cloudWaitThreshold;
  }

  /// Best-effort cloud-provider label derived from the in-flight
  /// path. macOS exposes its cloud-storage mounts under
  /// `~/Library/CloudStorage/Dropbox-…`, iCloud under
  /// `~/Library/Mobile Documents/…`. Anything we don't recognise
  /// falls back to a generic "cloud" label so the UI stays
  /// truthful (we don't actually know if this 14-second hang is
  /// Dropbox or just a slow NAS).
  String get currentHashCloudLabel {
    final p = _currentHashPath ?? '';
    if (p.contains('/Library/CloudStorage/Dropbox')) return 'Dropbox';
    if (p.contains('/Library/CloudStorage/GoogleDrive')) return 'Google Drive';
    if (p.contains('/Library/CloudStorage/OneDrive')) return 'OneDrive';
    if (p.contains('/Library/Mobile Documents')) return 'iCloud';
    return 'cloud';
  }

  void _onBackfillProgress(int batch, int session, int remaining) {
    _backfillHashedThisSession = session;
    _backfillRemaining = remaining;
    notifyListeners();
  }

  void _onBackfillHashStart(String path) {
    _currentHashPath = path;
    _currentHashStartedAt = DateTime.now();
    // 1 Hz tick so the elapsed-seconds counter advances visibly
    // and the threshold flip from "Hashing audio" → "Waiting on
    // cloud" fires on the second it's reached. Cheap (one
    // notifyListeners per second, only while a hash is in
    // flight). Cancelled in `_onBackfillHashEnd`.
    _currentHashTicker?.cancel();
    _currentHashTicker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        // Skip the notify when nothing's actually in flight any
        // more (defensive — Timer.cancel races with the hash's
        // finally block).
        if (_currentHashStartedAt == null) return;
        notifyListeners();
      },
    );
    notifyListeners();
  }

  void _onBackfillHashEnd(String path) {
    _currentHashPath = null;
    _currentHashStartedAt = null;
    _currentHashTicker?.cancel();
    _currentHashTicker = null;
    notifyListeners();
  }

  void _wireMediaBridge() {
    _media.onPlay = () async {
      if (!_isPlaying) await togglePlayPause();
    };
    _media.onPause = () async {
      if (_isPlaying) await togglePlayPause();
    };
    _media.onTogglePlayPause = () => togglePlayPause();
    _media.onNext = () => next();
    _media.onPrevious = () => previous();
    _media.onSeek = (seconds) async {
      final track = currentTrack;
      if (track == null) return;
      final pos = Duration(milliseconds: (seconds * 1000).round());
      _positionNotifier.value = pos;
      _lastTickPosition = pos;
      await engine.seek(pos);
    };
  }

  void _pushNowPlaying() {
    final track = currentTrack;
    if (track == null) {
      _media.clearNowPlaying();
      return;
    }
    final shownTitle = track.displayTitle;
    final shownArtist = track.displayArtist;
    _media.updateNowPlaying(
      title: shownTitle.isEmpty ? null : shownTitle,
      artist: shownArtist.isEmpty ? null : shownArtist,
      durationSeconds: track.duration.inMilliseconds / 1000.0,
      positionSeconds: _positionNotifier.value.inMilliseconds / 1000.0,
      isPlaying: _isPlaying,
    );
  }

  DateTime _lastNowPlayingPushAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> hydrate() async {
    final settings = await repo.loadSettings();
    _playThresholdSeconds =
        int.tryParse(settings['play_threshold_seconds'] ?? '') ?? 10;
    // Save / autosave settings. Library name + machine ID default
    // to sensible fresh-install values; the user can rename either
    // later via settings (filename-sanitised at write time, so
    // arbitrary input is safe).
    final savedLibraryName = settings['library_name'];
    if (savedLibraryName != null && savedLibraryName.isNotEmpty) {
      _libraryName = savedLibraryName;
    }
    final savedMachineId = settings['machine_id'];
    if (savedMachineId != null && savedMachineId.isNotEmpty) {
      _machineId = savedMachineId;
    } else {
      // First-launch best-guess from hostname so saves are at
      // least labelled with something machine-identifying instead
      // of the literal "MACHINE". Users can override later.
      try {
        final host = Platform.localHostname;
        if (host.isNotEmpty) _machineId = host;
      } catch (_) {/* keep default */}
    }
    // Sync the filesystem-level identity (`machine_id.txt`) with
    // the DB setting. The bootstrap reads `machine_id.txt` BEFORE
    // opening the DB (so boot routing doesn't depend on DB
    // introspection), but after hydrate we know what the user
    // wants; mirror it to the filesystem so next boot uses the
    // current setting. Idempotent — writing the same value is a
    // no-op effect.
    final root = libraryRoot;
    if (root != null) {
      try {
        await root.writeMachineId(_machineId);
      } catch (e) {
        debugPrint(
          '[hydrate] failed to sync machine_id.txt: $e',
        );
      }
    }
    final savedAutosaveEnabled = settings['autosave_enabled'];
    if (savedAutosaveEnabled != null) {
      _autosaveEnabled = savedAutosaveEnabled != '0';
    }
    final savedAutosaveInterval =
        int.tryParse(settings['autosave_interval_minutes'] ?? '');
    if (savedAutosaveInterval != null && savedAutosaveInterval > 0) {
      _autosaveIntervalMinutes = savedAutosaveInterval;
    }
    final savedVolume = double.tryParse(settings['volume'] ?? '');
    if (savedVolume != null) {
      _volume = savedVolume.clamp(0.0, 1.0).toDouble();
      volumeListenable.value = _volume;
      await engine.setVolume(_volume);
    }
    final savedSidebar = settings['sidebar_visible'];
    if (savedSidebar != null) {
      _sidebarVisible = savedSidebar != '0';
    }
    final savedSidebarWidth = double.tryParse(settings['sidebar_width'] ?? '');
    if (savedSidebarWidth != null) {
      _sidebarWidth = savedSidebarWidth.clamp(
        sidebarMinWidth,
        sidebarMaxWidth,
      ).toDouble();
    }
    // Apply the runtime resize-clamps on load too so any stale
    // saved value from a previous build (e.g., a 78px FORMAT
    // width saved before we raised the floor to fit
    // "FORMAT · MP3") is pulled up to the current minimum
    // instead of silently restoring an unreadable layout.
    final savedTitleW = double.tryParse(settings['col_title_width'] ?? '');
    if (savedTitleW != null) _colTitleWidth = savedTitleW.clamp(120.0, 1500.0);
    final savedArtistW = double.tryParse(settings['col_artist_width'] ?? '');
    if (savedArtistW != null) _colArtistWidth = savedArtistW.clamp(100.0, 1200.0);
    final savedFormatW = double.tryParse(settings['col_format_width'] ?? '');
    if (savedFormatW != null) _colFormatWidth = savedFormatW.clamp(80.0, 200.0);
    final orderStr = settings['column_order'];
    if (orderStr != null && orderStr.isNotEmpty) {
      final parsed = orderStr
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final defaults = _defaultColumnOrder.toSet();
      final stored = parsed.toSet();
      if (stored.containsAll(defaults) && parsed.length == stored.length) {
        // Stored order is exhaustive (covers every default + has no
        // duplicates) — adopt as-is. Allows users to keep custom
        // orderings across releases that add columns.
        _columnOrder = parsed;
      } else if (defaults.containsAll(stored)) {
        // Stored order is a subset of current defaults (e.g. it was
        // saved before we added `key` / `lastPlayed`). Keep the
        // user's relative order for known columns and append any
        // newly-introduced columns at the end so they're at least
        // visible.
        final tail = _defaultColumnOrder
            .where((c) => !parsed.contains(c))
            .toList();
        _columnOrder = [...parsed, ...tail];
      }
    }
    final srcOrderStr = settings['source_order'];
    if (srcOrderStr != null && srcOrderStr.isNotEmpty) {
      _sourceOrder = srcOrderStr
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    // Utility rail: load persisted order + lock state. Reconcile
    // against the canonical default-order so unknown / removed keys
    // don't poison the list, and newly-added keys (future modules)
    // get appended in default-order position.
    final railOrderStr = settings['utility_rail_order'];
    if (railOrderStr != null && railOrderStr.isNotEmpty) {
      final saved = railOrderStr
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .where(_defaultUtilityRailOrder.contains)
          .toList();
      // Append any default keys missing from the saved order so a
      // new module added in code lands at a sensible default
      // position rather than vanishing.
      for (final key in _defaultUtilityRailOrder) {
        if (!saved.contains(key)) saved.add(key);
      }
      _utilityRailOrder = saved;
    }
    final railLockedStr = settings['utility_rail_locked'];
    if (railLockedStr != null) {
      _utilityRailLocked = railLockedStr == '1';
    }

    final sources = await repo.loadSources();
    // One-time healing pass: backfill identity_override onto rows
    // that were orphaned by pre-fix Copy operations (e.g. AIFF
    // sibling losing its bucket pairing with MP3s after a Copy
    // stamped overrides on source + dest but not on the AIFF).
    // Idempotent: once the library is healed, this is a no-op on
    // every subsequent hydrate.
    try {
      final healed = await repo.healOrphanedIdentitySiblings();
      if (healed > 0) {
        debugPrint(
          '[hydrate] healed $healed orphaned identity_override siblings',
        );
      }
    } catch (e) {
      debugPrint('[hydrate] heal pass failed: $e');
    }
    // Crash-recovery: any row left in `enriching` from a previous
    // run reverts to `discovered` so the regular enrichment pass
    // picks it back up. Must run BEFORE loadTracks so the
    // freshly-loaded Track objects see the corrected states.
    try {
      final swept = await repo.sweepStuckEnriching();
      if (swept > 0) {
        debugPrint(
          '[hydrate] swept $swept rows from stuck enriching → discovered',
        );
      }
    } catch (e) {
      debugPrint('[hydrate] enrichment-state sweep failed: $e');
    }
    final tracks = await repo.loadTracks();
    _sources
      ..clear()
      ..addAll(sources);
    _replaceTracks(tracks);
    // Initial source-existence sweep. Any source whose
    // `folder_path` isn't on disk lands in `_missingFolderSourceIds`
    // so the sidebar renders the "Folder missing" treatment from
    // first paint instead of waiting for a scan to discover it.
    _refreshMissingFolderSet();
    _markLibraryDirty();
    notifyListeners();

    // Start a filesystem watcher per non-sub-view source so external
    // changes (deletes, renames, new drops) flow into the table
    // without a manual rescan. Best-effort: failures (unsupported
    // FS, missing path) are logged and the manual rescan path still
    // works.
    for (final source in sources) {
      // Don't await — watchers should come up in parallel; we
      // don't want to gate hydrate completion on per-source
      // watcher setup, especially over slow cloud volumes.
      unawaited(_startWatcher(source));
    }

    // Belt-and-suspenders: also rescan every source when the app
    // is brought back to foreground (Cmd+Tab from Finder, etc).
    // Catches the cases where `Directory.watch` missed an event —
    // especially Finder's "Move to Trash" flow, which sometimes
    // produces FSEvents that don't surface cleanly.
    if (!_lifecycleObserverRegistered) {
      WidgetsBinding.instance.addObserver(_lifecycleObserver);
      _lifecycleObserverRegistered = true;
    }

    final unenriched =
        tracks.where((t) => t.metadataReadAt == null).length;
    debugPrint(
      '[meta] hydrate loaded ${tracks.length} tracks '
      '($unenriched without metadata — viewport will enrich on demand)',
    );
    // NO auto-enqueue. Untouched rows stay at filename-only until
    // the user scrolls/selects/plays them.

    _startAutosaveTimer();
  }

  // ---------------------------------------------------------------------------
  // Save / autosave
  // ---------------------------------------------------------------------------

  /// Periodic dirty-check that snapshots `Current/CURRENT.library`
  /// to `Saves/` when the DB file has been written since the last
  /// snapshot. Skipped entirely when `saveManager` is null (e.g.
  /// in unit tests) or when the user disabled autosave.
  void _startAutosaveTimer() {
    _autosaveTimer?.cancel();
    if (saveManager == null) return;
    if (!_autosaveEnabled) return;
    if (_autosaveIntervalMinutes <= 0) return;
    _autosaveTimer = Timer.periodic(
      Duration(minutes: _autosaveIntervalMinutes),
      (_) => unawaited(_autosaveTick()),
    );
  }

  Future<void> _autosaveTick() async {
    final mgr = saveManager;
    final root = libraryRoot;
    if (mgr == null || root == null) return;
    final dbFile = File(root.deviceLiveDbPath(_machineId));
    if (!dbFile.existsSync()) return;
    final mtime = dbFile.statSync().modified;
    if (_lastSnapshotDbMtime != null &&
        !mtime.isAfter(_lastSnapshotDbMtime!)) {
      // Live DB unchanged since the last snapshot — nothing to save.
      return;
    }
    await _snapshotNow();
  }

  /// Take a snapshot right now, regardless of dirty state. Used by
  /// lifecycle hooks (post-scan, on dispose) where we want a save
  /// point at a meaningful moment even if the tick hasn't fired.
  /// No-op when `saveManager` is null.
  ///
  /// Two writes per call (post 2026-05-12 boot transition):
  ///   1. Rolling timestamped snapshot in `Saves/` — historical
  ///      lineage / crash recovery / rollback. Source is the live
  ///      device DB at `Systems/{MACHINE}.library`.
  ///   2. Compatibility mirror to `Current/CURRENT.library` — keeps
  ///      a stable filename for manual Finder-swap rollback and
  ///      external inspection. Transitional; long-term fate of
  ///      Current/ is deferred. A failure here is logged but
  ///      doesn't abort the call: the Saves/ snapshot is the
  ///      primary durability guarantee.
  Future<void> _snapshotNow() async {
    final mgr = saveManager;
    final root = libraryRoot;
    if (mgr == null || root == null) return;
    final liveDbPath = root.deviceLiveDbPath(_machineId);
    // Flush the operational-journal accumulators FIRST so any
    // aggregate entries land in the live DB before the snapshot
    // copy captures it. Each non-zero counter becomes one row in
    // the `events` table with a count payload; counters reset.
    await _flushJournalAccumulators();
    try {
      final file = await mgr.snapshot(
        libraryName: _libraryName,
        machineId: _machineId,
        sourceDbPath: liveDbPath,
      );
      if (file != null) {
        _lastSnapshotDbMtime = File(liveDbPath).statSync().modified;
      }
    } catch (e) {
      debugPrint('[autosave] snapshot failed: $e');
    }
    try {
      await mgr.mirrorToCurrent(
        libraryName: _libraryName,
        machineId: _machineId,
      );
    } catch (e) {
      debugPrint('[autosave] compatibility mirror failed: $e');
    }
  }

  /// Drain the operational-journal accumulators into the `events`
  /// table as aggregate entries, then reset the counters. Called
  /// at the top of `_snapshotNow` so each save period gets one
  /// row per non-zero counter (e.g. `tracks_played` with
  /// `{"count": 14}`), rendered in the Load Operational State
  /// dialog as "Played 14 tracks" / "Added 3 favorites".
  ///
  /// Failures are best-effort and logged — the journal is
  /// observability, not critical data. We never block the
  /// snapshot waiting for a journal write.
  Future<void> _flushJournalAccumulators() async {
    final plays = _playsSinceSnapshot;
    final favorites = _favoritesAddedSinceSnapshot;
    _playsSinceSnapshot = 0;
    _favoritesAddedSinceSnapshot = 0;
    if (plays > 0) {
      try {
        await repo.recordEvent(
          type: EventType.tracksPlayed,
          payload: {'count': plays},
        );
      } catch (e) {
        debugPrint('[journal] tracks_played flush failed: $e');
      }
    }
    if (favorites > 0) {
      try {
        await repo.recordEvent(
          type: EventType.favoritesAdded,
          payload: {'count': favorites},
        );
      } catch (e) {
        debugPrint('[journal] favorites_added flush failed: $e');
      }
    }
  }

  /// Switch the running app's operational state to [target].
  ///
  /// Mechanics:
  ///   1. Take a final autosave snapshot of the *current* state so
  ///      this transition is itself a recoverable lineage point.
  ///      (Every state transition becomes reversible — that's the
  ///      operational-continuity guarantee.)
  ///   2. Copy `target.filePath` over the live device DB at
  ///      `Systems/{MACHINE}.library`. Atomic-rename via `.partial`.
  ///   3. Return successfully — the UI then instructs the user to
  ///      quit and relaunch. We deliberately do NOT attempt an
  ///      in-app reload in V1: too many runtime caches (sqflite
  ///      handles, controllers, scan state, playback) would need
  ///      coordinated teardown, and an explicit restart honestly
  ///      communicates "you are entering another operational
  ///      reality." Process-bound operational identity stays
  ///      clean.
  ///
  /// Loading the current-device file (the one already live) is
  /// allowed but a no-op beyond the autosave; this lets the UI
  /// always offer "Load this state" without special-casing.
  ///
  /// Returns null on success; non-null human-readable error on
  /// failure (so the UI can surface it). Never throws.
  Future<String?> loadOperationalState(OperationalState target) async {
    final mgr = saveManager;
    final root = libraryRoot;
    if (mgr == null || root == null) {
      return 'Save manager unavailable — cannot switch state.';
    }
    final liveDbPath = root.deviceLiveDbPath(_machineId);
    // Step 1 — final autosave of current state for recoverability.
    try {
      await _snapshotNow();
    } catch (e) {
      // Don't abort the load just because the safety snapshot
      // failed — but log loudly. The user explicitly asked to
      // transition; surface the issue without blocking.
      debugPrint('[loadOperationalState] pre-load snapshot failed: $e');
    }
    // Step 2 — swap the file into Systems/{MACHINE}.library.
    if (target.filePath == liveDbPath) {
      // Loading the already-live file is a no-op. The autosave
      // above already captured current state; nothing else to do.
      debugPrint(
        '[loadOperationalState] target IS the live DB — no swap needed',
      );
      return null;
    }
    final source = File(target.filePath);
    if (!source.existsSync()) {
      return 'Selected operational state file is missing on disk.';
    }
    final tmp = File('$liveDbPath.partial');
    try {
      await Directory(root.systemsDir).create(recursive: true);
      await source.copy(tmp.path);
      // Atomic-replace the live DB. Dart's File.rename on macOS
      // matches POSIX rename(2) semantics — the prior live file
      // goes away in the same syscall, no race.
      await tmp.rename(liveDbPath);
    } catch (e) {
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {/* best-effort */}
      }
      return 'Failed to swap operational state: $e';
    }
    debugPrint(
      '[loadOperationalState] swapped ${target.filePath} → $liveDbPath',
    );
    return null;
  }

  /// The track table calls this with the paths currently on screen
  /// (plus a small lookahead) once scrolling settles. We push any
  /// path that lacks metadata and isn't already queued onto the
  /// enrichment queue. No-op if everything visible is already
  /// enriched or already in flight.
  void reportViewportPaths(Iterable<String> paths) {
    _enqueueIfNeeded(paths);
  }

  /// Single-path enrichment hook used by interaction code paths
  /// (`play`, `selectTrack`). Independent of the viewport — ensures
  /// the row the user is currently engaging with gets metadata.
  void enrichOnDemand(String path) {
    _enqueueIfNeeded([path]);
  }

  /// User-triggered: enrich every un-enriched track owned by
  /// [sourceId] (or contained by a sub-view's `pathPrefix`).
  /// Bypasses the viewport gate intentionally — this is the
  /// explicit opt-in to a long-running pass.
  void enrichSource(String sourceId) {
    final s = _sourceById(sourceId);
    if (s == null) return;
    final paths = <String>[];
    if (s.isSubView) {
      for (final t in _tracks) {
        if (t.sourceId == s.parentSourceId &&
            t.path.startsWith(s.pathPrefix!) &&
            t.metadataReadAt == null) {
          paths.add(t.path);
        }
      }
    } else {
      for (final t in _tracks) {
        if (t.sourceId == sourceId && t.metadataReadAt == null) {
          paths.add(t.path);
        }
      }
    }
    debugPrint('[meta] enrichSource(${s.displayName}) → ${paths.length} paths');
    _enqueueIfNeeded(paths);
  }

  /// User-triggered: enrich every un-enriched track in the
  /// library, regardless of source. The "show me flying numbers"
  /// command.
  void enrichAll() {
    final paths = [
      for (final t in _tracks)
        if (t.metadataReadAt == null) t.path,
    ];
    debugPrint('[meta] enrichAll → ${paths.length} paths');
    _enqueueIfNeeded(paths);
  }

  void _enqueueIfNeeded(Iterable<String> paths) {
    final fresh = <String>[];
    for (final p in paths) {
      if (_inEnrichmentQueue.contains(p)) continue;
      if (_failedEnrichmentPaths.contains(p)) continue;
      final t = _tracksByPath[p];
      if (t == null) continue;
      if (t.metadataReadAt != null) continue;
      _inEnrichmentQueue.add(p);
      fresh.add(p);
      // Flip the in-memory state immediately so the row renders
      // its "actively being processed" treatment without waiting
      // for the DB write below to round-trip.
      t.enrichmentState = EnrichmentState.enriching;
    }
    if (fresh.isEmpty) return;
    _enrichmentQueue.addAll(fresh);
    _metadataTotalThisRun += fresh.length;
    // Persist `enriching` so a render-anywhere read of these
    // rows (e.g., re-hydration after a window reopen) sees the
    // same state. Fire-and-forget — failure to persist is OK,
    // worst case the row stays at `discovered` and a subsequent
    // enqueue does the same work again. Boot-time
    // `sweepStuckEnriching` is the safety net for any rows that
    // ever land here without a paired clearance.
    unawaited(repo.markPathsEnriching(fresh));
    debugPrint(
      '[meta] queued +${fresh.length} '
      '(queue=${_enrichmentQueue.length}, processing=$_metadataProcessing)',
    );
    if (!_metadataProcessing) {
      _processMetadataQueue();
    } else {
      _notifyThrottled();
    }
  }

  Timer? _enrichmentStallTicker;

  /// `true` when [path] resolves to a cloud-storage mount where
  /// reads can block for tens of seconds (placeholder
  /// materialisation). Same detection set as
  /// [currentEnrichmentCloudLabel] / [currentHashCloudLabel] so
  /// the operational vocabulary stays consistent across pipelines.
  ///
  /// Used by `_processMetadataQueue` to throttle isolate
  /// concurrency on cloud paths — see the per-wave logic there.
  static bool _isCloudPath(String path) {
    return path.contains('/Library/CloudStorage/Dropbox') ||
        path.contains('/Library/CloudStorage/GoogleDrive') ||
        path.contains('/Library/CloudStorage/OneDrive') ||
        path.contains('/Library/Mobile Documents');
  }

  Future<void> _processMetadataQueue() async {
    if (_metadataProcessing) return;
    _metadataProcessing = true;
    _lastEnrichmentCompletionAt = DateTime.now();
    // 1 Hz tick so the elapsed-since-last-completion clock
    // advances visibly in the status bar even when isolates are
    // blocked on Dropbox materialisation. Cancelled in the
    // `finally` below when processing ends.
    _enrichmentStallTicker?.cancel();
    _enrichmentStallTicker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!_metadataProcessing) return;
        notifyListeners();
      },
    );
    notifyListeners();
    debugPrint('[meta] processor starting (queue=${_enrichmentQueue.length})');
    try {
      // Two-key sort: local paths first, then by filesize asc
      // within each storage class. Cloud paths sink to the back
      // of the queue so the user sees thousands of fast local
      // results land before any cloud-hydration delay starts.
      // Within a storage class, smallest-first keeps the
      // "thousands of small wins arriving steadily" feel.
      _enrichmentQueue.sort((a, b) {
        final aCloud = _isCloudPath(a);
        final bCloud = _isCloudPath(b);
        if (aCloud != bCloud) return aCloud ? 1 : -1;
        final sa = _tracksByPath[a]?.filesize ?? 0;
        final sb = _tracksByPath[b]?.filesize ?? 0;
        return sa.compareTo(sb);
      });

      while (_enrichmentQueue.isNotEmpty) {
        // Hydration-aware scheduling. Determine if the NEXT wave
        // will be processing cloud paths — if so, throttle hard:
        //   - concurrency = 2 (was 8). Parallel hydration of 8
        //     Dropbox AIFFs saturates the network, makes nothing
        //     visibly complete, and burns CPU on stalled isolates.
        //     2 concurrent reads let one finish while the next is
        //     already in flight; user sees one row brighten,
        //     then another, then another — steady visible
        //     progress instead of a giant batched burst.
        //   - batch size = 1. Each isolate processes one file at
        //     a time and returns. Without this, a single
        //     blocked AIFF would freeze 50 results behind it.
        //     Isolate-spawn overhead (~50 ms) is negligible
        //     against per-file Dropbox waits of 5–30 s.
        // Local paths keep the original 8 × 50 budget — they
        // benefit from amortising isolate-spawn cost across
        // many cheap reads. The queue sort above puts local
        // first, so cloud throttling only kicks in once the
        // local backlog drains.
        final wavePeekPath = _enrichmentQueue.first;
        final isCloudWave = _isCloudPath(wavePeekPath);
        final concurrency = isCloudWave ? 2 : 8;
        final batchSize = isCloudWave ? 1 : _metadataBatchSize;

        final waveBatches = <List<String>>[];
        for (var i = 0;
            i < concurrency && _enrichmentQueue.isNotEmpty;
            i++) {
          final batch = _enrichmentQueue
              .take(batchSize)
              .toList(growable: false);
          _enrichmentQueue.removeRange(0, batch.length);
          // INTENTIONALLY do NOT remove batch paths from
          // `_inEnrichmentQueue` here. They're still IN FLIGHT —
          // the wave is awaiting `extractBatch` below. A
          // concurrent `enrichSource` (from a viewport report or
          // another scan completion) would otherwise see these
          // paths as "not queued, not yet enriched" and re-enqueue
          // them, double-counting. The user reported "87 songs,
          // 170 backlog" — that was exactly this bug. The dedup
          // set now represents "in the pipeline at all" (queued
          // OR in-flight), and paths get removed only after their
          // results land in `_applyMetadata`.
          waveBatches.add(batch);
        }
        final waveSw = Stopwatch()..start();
        final waveTotal =
            waveBatches.fold<int>(0, (s, b) => s + b.length);
        debugPrint(
          '[meta] wave start (${waveBatches.length} batches × '
          '$_metadataBatchSize, total=$waveTotal, '
          'queue remaining=${_enrichmentQueue.length})',
        );

        // Run all batches in parallel — but apply each batch's
        // results AS IT COMPLETES instead of waiting for the whole
        // wave. This is what makes the counter "fly": with 8
        // batches in flight and `Future.wait`, the user sees ZERO
        // progress for the entire wave duration and then a single
        // 400-track jump. With per-batch handling, each batch's
        // ~50 rows surface immediately on its completion, and the
        // `currentEnrichmentLabel` rotates through actual files
        // being processed.
        final sep = Platform.pathSeparator;
        await Future.wait(
          waveBatches.map((batch) async {
            final List<TrackMetadata> results;
            try {
              results = await MetadataExtractor.extractBatch(batch);
            } catch (e) {
              debugPrint('[meta] batch FAILED: $e');
              return;
            }
            // Surface a representative filename from this batch
            // for the status bar — rotates as batches finish.
            // Full path retained on `_currentEnrichmentPath` so
            // `currentEnrichmentCloudLabel` can detect Dropbox /
            // iCloud / etc. (the basename alone wouldn't match).
            if (results.isNotEmpty) {
              final p = results.first.path;
              final i = p.lastIndexOf(sep);
              _currentEnrichmentLabel = i < 0 ? p : p.substring(i + 1);
              _currentEnrichmentPath = p;
            }
            // A batch landing means the pipeline is making
            // progress — reset the stall clock so the cloud-wait
            // label drops back to plain "Enriching".
            _lastEnrichmentCompletionAt = DateTime.now();
            for (final m in results) {
              final t = _trackByPath(m.path);
              if (t != null) {
                _applyMetadata(t, m);
              }
              // Path is no longer in flight — clear from the
              // dedup set so future enrichSource calls can
              // re-enqueue it if needed (e.g., new viewport
              // report after a stat-change reset its
              // `metadata_read_at`). Failed reads still stamp
              // `metadataReadAt`, so `_enqueueIfNeeded` skips
              // them; this just drops the in-flight marker.
              _inEnrichmentQueue.remove(m.path);
            }
            try {
              await repo.updateMetadataBatch(results);
            } catch (e) {
              debugPrint('[meta] DB update FAILED: $e');
            }
            _metadataDoneThisRun += results.length;
            _markLibraryDirty();
            // Notify per batch so the counter and label update
            // every ~50 rows instead of every ~400.
            notifyListeners();
          }),
        );
        debugPrint(
          '[meta] wave done in ${waveSw.elapsedMilliseconds}ms '
          '($waveTotal in flight)',
        );
      }
    } finally {
      _metadataProcessing = false;
      _metadataDoneThisRun = 0;
      _metadataTotalThisRun = 0;
      _currentEnrichmentLabel = null;
      _currentEnrichmentPath = null;
      _lastEnrichmentCompletionAt = null;
      _enrichmentStallTicker?.cancel();
      _enrichmentStallTicker = null;
      _inEnrichmentQueue.clear();
      notifyListeners();
      debugPrint('[meta] processor idle');
    }
  }

  void _applyMetadata(Track t, TrackMetadata m) {
    if (m.readSucceeded) {
      if (m.title != null) t.title = m.title!;
      if (m.artist != null) t.artist = m.artist!;
      if (m.album != null) t.album = m.album!;
      if (m.genre != null) t.genre = m.genre!;
      if (m.musicalKey != null) t.musicalKey = m.musicalKey!;
      if (m.bpm != null) t.bpm = m.bpm;
      if (m.duration != null && m.duration! > Duration.zero) {
        t.duration = m.duration!;
      }
      t.hasArtwork = m.hasArtwork;
      t.enrichmentState = EnrichmentState.ready;
    } else {
      // Tag parser failed (audio_metadata_reader can't decode this
      // particular format / file revision). Track the path so we
      // don't keep re-enqueueing it from every viewport snapshot.
      _failedEnrichmentPaths.add(t.path);
      t.enrichmentState = EnrichmentState.failed;
    }
    // Stamp regardless of success: "we have processed this row".
    // The filename-parsing display fallback still covers it; the
    // user just doesn't see flying-zero stuck-counter behaviour
    // when their library has lots of unparseable formats. Failed
    // rows can be re-attempted by removing+re-adding the source
    // (or via a future "Retry failed" action).
    t.metadataReadAt = DateTime.now();
  }

  // ---------------------------------------------------------------------------
  // Public read-only state
  // ---------------------------------------------------------------------------

  /// Persisted display order of top-level source IDs (sub-views are
  /// always rendered immediately under their parent and don't have
  /// their own slot in this list). Loaded from `app_settings` at
  /// hydrate, mutated by [moveSource], persisted as a comma-joined
  /// string under the `source_order` key.
  List<String> _sourceOrder = [];

  /// Compare-key helper: position in `_sourceOrder` if present;
  /// otherwise sources after all explicitly-ordered ones, ranked by
  /// their natural DB `createdAt`. Used by both `sources` getter
  /// and reorder logic so the two stay consistent.
  int _orderKey(Source s) {
    final idx = _sourceOrder.indexOf(s.id);
    if (idx >= 0) return idx;
    return _sourceOrder.length + s.createdAt;
  }

  List<Source> get sources {
    if (_sources.isEmpty) return const [];
    // Order top-level by `_sourceOrder`. Then for each top-level,
    // append its sub-views — also ordered by `_sourceOrder` so the
    // user can rearrange `B`, `C`, `D` independently.
    final topLevel = _sources.where((s) => !s.isSubView).toList()
      ..sort((a, b) => _orderKey(a).compareTo(_orderKey(b)));
    final ordered = <Source>[];
    for (final s in topLevel) {
      ordered.add(s);
      final subs = _sources
          .where((c) => c.parentSourceId == s.id)
          .toList()
        ..sort((a, b) => _orderKey(a).compareTo(_orderKey(b)));
      ordered.addAll(subs);
    }
    // Defensive: any sub-view whose parent vanished (shouldn't
    // happen with FK cascade, but cheap to handle).
    final byId = {for (final s in _sources) s.id};
    for (final s in _sources) {
      if (s.isSubView && !byId.contains(s.parentSourceId)) {
        ordered.add(s);
      }
    }
    return List.unmodifiable(ordered);
  }

  Source? _sourceLookup(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Insert [draggedId] immediately before [targetId] in the saved
  /// source order. Same-tier only — refuses if dragged and target
  /// have different parents (top-level + sub-view, or sub-views of
  /// different parents). The `_sourceOrder` list is one flat
  /// sequence shared by both tiers; the `sources` getter splits it
  /// per-tier when rendering, so this handles both cases.
  Future<void> moveSourceBefore(
    String draggedId,
    String targetId,
  ) async {
    if (draggedId == targetId) return;
    final dragged = _sourceLookup(draggedId);
    final target = _sourceLookup(targetId);
    if (dragged == null || target == null) return;
    if (dragged.parentSourceId != target.parentSourceId) return;

    // Materialise a flat order list with every source ID present
    // (anything missing from `_sourceOrder` gets appended in
    // createdAt order so we don't lose track of new sources).
    final ordered = [..._sourceOrder];
    final present = ordered.toSet();
    final byCreated = _sources.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final s in byCreated) {
      if (!present.contains(s.id)) ordered.add(s.id);
    }

    ordered.remove(draggedId);
    final targetIdx = ordered.indexOf(targetId);
    if (targetIdx < 0) return;
    ordered.insert(targetIdx, draggedId);

    _sourceOrder = ordered;
    notifyListeners();
    await repo.setSetting('source_order', _sourceOrder.join(','));
  }

  // ---------------------------------------------------------------------
  // Utility-rail order + lock — public surface
  // ---------------------------------------------------------------------

  /// Current order of the reorderable utility-rail cards. Defensive
  /// copy so callers can't mutate internal state. Volume is
  /// intentionally NOT in this list (it stays pinned above the
  /// reorderable section).
  List<String> get utilityRailOrder => List.unmodifiable(_utilityRailOrder);

  /// Whether the utility rail's reorder behavior is currently
  /// disabled. UI uses this to hide drag handles and refuse
  /// reorder gestures.
  bool get utilityRailLocked => _utilityRailLocked;

  /// Persist a new utility-rail order. Filtered against the canonical
  /// default-order so callers can't sneak unknown keys in; missing
  /// keys are appended so the persisted list stays exhaustive.
  Future<void> setUtilityRailOrder(List<String> order) async {
    final filtered = order
        .where(_defaultUtilityRailOrder.contains)
        .toList();
    for (final key in _defaultUtilityRailOrder) {
      if (!filtered.contains(key)) filtered.add(key);
    }
    _utilityRailOrder = filtered;
    notifyListeners();
    await repo.setSetting('utility_rail_order', filtered.join(','));
  }

  /// Toggle the lock-order state. When `true`, the rail's drag
  /// handles disappear and reorder gestures are refused.
  Future<void> setUtilityRailLocked(bool locked) async {
    if (_utilityRailLocked == locked) return;
    _utilityRailLocked = locked;
    notifyListeners();
    await repo.setSetting('utility_rail_locked', locked ? '1' : '0');
  }
  String? get selectedSourceId => _selectedSourceId;

  /// The currently-selected source object, or `null` when "All
  /// Tracks" is selected (or the source ID resolved to something
  /// no longer in `_sources`). Status bar uses this to render
  /// the contextual `Q · enriching · 32 / 87 ready` label.
  Source? get selectedSource {
    final id = _selectedSourceId;
    if (id == null) return null;
    return _sourceById(id);
  }
  String get searchQuery => _searchQuery;
  bool get unreviewedOnly => _unreviewedOnly;
  bool get showArtwork => _showArtwork;
  bool get isScanning => _isScanning;
  TrackSortColumn get sortColumn => _sortColumn;
  bool get sortAscending => _sortAscending;

  String? get currentTrackUid => _currentTrackUid;
  String? get currentTrackPath => _currentTrackPath;
  /// UID of the most recently threshold-crossed track. Stays set
  /// while that track is current; clears on the next [play] call.
  /// The table row keyed to this uid renders with an accent
  /// highlight (an AnimatedContainer at the row level fades the
  /// highlight in — that's the "flash"). Distinct from
  /// `track.reviewed`, which is the long-term persistent flag.
  String? get justReviewedUid => _justReviewedUid;
  String? get selectedTrackUid => _selectedTrackUid;
  PlaybackMode get playbackMode => _playbackMode;
  bool get isPlaying => _isPlaying;
  bool get isLoadingTrack => _isLoadingTrack;
  bool get isMetadataProcessing => _metadataProcessing;
  int get metadataProgressDone => _metadataDoneThisRun;
  int get metadataProgressTotal => _metadataTotalThisRun;
  String? get currentEnrichmentLabel => _currentEnrichmentLabel;
  Duration get currentPosition => _positionNotifier.value;

  /// Library-wide enriched tally (`metadataReadAt != null`).
  /// Cached at `_libraryVersion` granularity.
  int get enrichedCount {
    _ensureLibraryStats();
    return _enrichedCountCache ?? 0;
  }

  /// Library-wide count of rows currently in the
  /// `EnrichmentState.enriching` state — i.e., paths handed to the
  /// metadata-extraction pipeline whose tags haven't landed yet.
  /// Drives the activity strip's "ENRICHING N" chunk. Always shows
  /// (including zero) so the user sees a calm-but-truthful baseline.
  int get enrichingCount {
    _ensureLibraryStats();
    return _enrichingCountCache ?? 0;
  }

  /// Library-wide count of rows in `EnrichmentState.failed`. These
  /// are paths the metadata pipeline tried and couldn't decode
  /// (corrupt tag block, unsupported codec variant, permission
  /// flap). Surfaced explicitly so the user can spot "attention
  /// required" libraries without digging.
  int get failedEnrichmentCount {
    _ensureLibraryStats();
    return _failedEnrichmentCountCache ?? 0;
  }

  /// Implicit "not yet processed" count: total rows minus the ones
  /// in any other state. Computed from the cached totals so the
  /// activity strip stays consistent with the rest of the tally
  /// (rounding errors here would manifest as the four chunks not
  /// adding up to the file count, which would be a trust killer).
  int get discoveredCount {
    final total = totalTrackCount;
    final accounted = enrichedCount + enrichingCount + failedEnrichmentCount;
    final remainder = total - accounted;
    return remainder < 0 ? 0 : remainder;
  }

  /// Library-wide missing tally — truly-gone files only. Auto-
  /// detected moves are excluded (they live in `movedCount`).
  int get missingCount {
    _ensureLibraryStats();
    return _missingCountCache ?? 0;
  }

  /// Library-wide count of `superseded` rows — files the scan
  /// detected as moved within their source (old DB path no longer
  /// on disk, but a same-fingerprint file exists at a new path).
  /// Surfaced separately from `missing` so the user can see "I
  /// reorganised these" vs "these are actually gone".
  int get movedCount {
    _ensureLibraryStats();
    return _movedCountCache ?? 0;
  }

  /// Snapshot of every track currently in the `missing` or
  /// `superseded` state, regardless of source. The Review-missing
  /// dialog reads this directly to populate its two sections.
  /// Linear scan, called only when the dialog opens.
  List<Track> get tracksNeedingReview {
    return [
      for (final t in _tracks)
        if (t.availability == 'missing' || t.availability == 'superseded') t,
    ];
  }

  /// Permanently delete `indexed_files` rows by path. Used by the
  /// Review-missing dialog when the user confirms purge. Intel
  /// rows in `tracks` survive (guardrail #5: never destroy user
  /// work — the intel reconnects on fingerprint match if the file
  /// ever returns).
  Future<void> purgeMissingTracks(List<String> paths) async {
    if (paths.isEmpty) return;
    await repo.purgeIndexedFiles(paths);
    // Reload — bulk delete is easier to express than incremental
    // in-memory pruning, and this only fires from the dialog
    // (rare user action), not during normal browsing.
    final allTracks = await repo.loadTracks();
    _replaceTracks(allTracks);
    _markLibraryDirty();
    notifyListeners();
  }

  /// Intentional in-app deletion: move the listed files to the
  /// macOS Trash, remove their `indexed_files` rows, optionally
  /// clear favorite on every variant sharing the song's intel uid.
  ///
  /// Distinct from `purgeMissingTracks` in three ways:
  /// 1. The files are still on disk when this is called — we
  ///    relocate them to ~/.Trash via NSFileManager (recoverable
  ///    from Finder). The Review-missing path operates on files
  ///    already gone from disk.
  /// 2. We can selectively clear `tracks.favorite` for the song —
  ///    the dialog's "Remove Favorite" radio surfaces this when
  ///    the song was favorited and surviving variants remain.
  /// 3. Intel row stays in `tracks` regardless. The user can
  ///    re-add the file later and history reconnects.
  ///
  /// Returns the count of files successfully moved to Trash. A
  /// trash failure on one path doesn't abort the rest — each
  /// failure is logged and the surviving deletions proceed.
  Future<int> deleteTracksToTrash(DeleteDecision decision) async {
    if (decision.paths.isEmpty) return 0;
    final trashed = <String>[];
    for (final p in decision.paths) {
      final ok = await TrashService.moveToTrash(p);
      if (ok) {
        trashed.add(p);
      } else {
        debugPrint('[delete] trash failed, skipping: $p');
      }
    }
    if (trashed.isEmpty) return 0;

    // DB cleanup + audit events. Same path as the missing-row
    // purge so the events table sees one `purged` per row.
    await repo.purgeIndexedFiles(trashed);

    // Conditional FAV cascade — only when the dialog flagged
    // `clearFavorite` AND the song actually had intel to flip.
    // Pattern mirrors `toggleFavorite`: write the canonical intel
    // row, then propagate to every in-memory variant pointing at
    // the same intel uid (including ones not in this delete batch).
    if (decision.clearFavorite) {
      try {
        final now = DateTime.now();
        await repo.updateIntelligence(
          intelUid: decision.intelUid,
          favorite: false,
        );
        for (final t in _tracks) {
          if (t.intelUid == decision.intelUid) {
            t.favorite = false;
            t.favoriteToggledAt = now;
          }
        }
      } catch (e) {
        debugPrint(
          '[delete] favorite-clear write failed (intel=${decision.intelUid}): $e',
        );
      }
    }

    // Drop trashed paths from in-memory state. Reload from DB
    // would also work but is heavier for a small batch; explicit
    // pruning keeps the hot path tight.
    final trashedSet = trashed.toSet();
    _removeTracksWhere((t) => trashedSet.contains(t.path));

    _markLibraryDirty();
    notifyListeners();
    return trashed.length;
  }

  // ── App-initiated Move / Copy orchestration ─────────────────
  //
  // Thin wrappers around `repo.moveTrackFile` / `repo.copyTrackFile`
  // that take care of post-success housekeeping (reload tracks,
  // mark library dirty, notify) while leaving the FS + DB heavy
  // lifting to the repo. Right-click "Move to..." / "Copy to..."
  // wires up to these from sub-slice C; tests cover the repo
  // primitives directly so we don't need a controller-level
  // mock-engine harness here.
  //
  // Both return the raw [MoveCopyResult] so the UI can render the
  // failure reason verbatim in a SnackBar — they don't try to
  // pretty-print or swallow errors at this layer.

  /// Move the file backing [track] into [destSource]'s folder root.
  /// On success: track list reloads from DB so the row appears at
  /// the new path and the old row's gone. On failure: nothing
  /// changes in DB / FS / memory; UI shows the reason.
  Future<MoveCopyResult> moveTrack({
    required Track track,
    required Source destSource,
  }) async {
    final result = await repo.moveTrackFile(
      sourcePath: track.path,
      destSource: destSource,
    );
    if (result.success) {
      final allTracks = await repo.loadTracks();
      _replaceTracks(allTracks);
      _markLibraryDirty();
      notifyListeners();
    }
    return result;
  }

  /// Copy the file backing [track] into [destSource]'s folder root.
  /// On success: new row appears in the track list sharing
  /// intel_uid with the original (favorites / plays / review state
  /// reflect for both). On failure: nothing changes.
  Future<MoveCopyResult> copyTrack({
    required Track track,
    required Source destSource,
  }) async {
    final result = await repo.copyTrackFile(
      sourcePath: track.path,
      destSource: destSource,
    );
    if (result.success) {
      final allTracks = await repo.loadTracks();
      _replaceTracks(allTracks);
      _markLibraryDirty();
      notifyListeners();
    }
    return result;
  }

  /// Watched sources that can appear in the Move/Copy dialog —
  /// every non-sub-view source, INCLUDING the one the [track]
  /// currently lives in. The current source is rendered as a
  /// disabled "CURRENT LOCATION" row inside the dialog (rather
  /// than hidden) so the user sees the full routing graph and
  /// can answer "where is this file right now?" without leaving
  /// the picker. The dialog is responsible for blocking selection
  /// of the current source; this method does not pre-filter it
  /// out.
  List<Source> moveCopyDestinationsFor(Track track) {
    return _sources.where((s) => !s.isSubView).toList(growable: false);
  }

  /// Distinct song-identity count — same buckets the variant
  /// collapse uses. Tracks with empty title/artist (no identity to
  /// group on) each count as their own song.
  int get songCount {
    _ensureLibraryStats();
    return _songCountCache ?? 0;
  }

  /// Count of songs (not files) where any variant in the bucket has
  /// crossed the cumulative-listen threshold. Mirrors how the
  /// table's REV column resolves a primary row.
  int get reviewedSongCount {
    _ensureLibraryStats();
    return _reviewedSongCountCache ?? 0;
  }

  /// `songCount - reviewedSongCount`, exposed for status-bar
  /// readability.
  int get unreviewedSongCount => songCount - reviewedSongCount;

  /// Files − songs: how many duplicate / variant rows the library
  /// holds beyond one-canonical-per-song. Always non-negative.
  int get variantFileCount {
    final v = totalTrackCount - songCount;
    return v < 0 ? 0 : v;
  }

  void _ensureLibraryStats() {
    // Keyed on `_dataVersion` (not `_libraryVersion`) — library-wide
    // totals don't care about the current filter, so source / search
    // / sort changes shouldn't force a 12k-track recompute.
    if (_libraryStatsVersion == _dataVersion) return;
    var enriched = 0;
    // Per-state counts for the activity strip. `discovered` is
    // implicit: total - enriched - enriching - failed. We compute
    // the active states (where work is happening or visibly missing)
    // and let the strip derive `discovered` from the total.
    var enriching = 0;
    var failedEnrichment = 0;
    var supersededCount = 0;
    // Build the byte-equivalence side index in pass 1: every
    // content_hash that has at least one currently-`available`
    // row. Used in pass 2 to reclassify "missing but content
    // exists elsewhere" rows out of the alarming MISSING tally
    // and into the calmer MOVED bucket.
    final availableContentHashes = <String>{};
    // Song-identity bucketing in the same pass. Tracks with empty
    // title/artist (songIdentityKey returns null) can't bucket and
    // each count as a singleton song. Other tracks are deduped by
    // their identity key.
    var singletonSongs = 0;
    var singletonReviewed = 0;
    final reviewedByBucket = <String, bool>{};
    final missingTracks = <Track>[];
    for (final t in _tracks) {
      if (t.metadataReadAt != null) enriched++;
      // Authoritative state read from the formal `enrichment_state`
      // column (schema v14). `discovered` is implicit (the
      // remainder) so we don't tally it here.
      switch (t.enrichmentState) {
        case EnrichmentState.enriching:
          enriching++;
          break;
        case EnrichmentState.failed:
          failedEnrichment++;
          break;
        case EnrichmentState.discovered:
        case EnrichmentState.ready:
          break;
      }
      if (t.availability == 'missing') {
        missingTracks.add(t);
      } else if (t.availability == 'superseded') {
        supersededCount++;
      }
      if (t.availability == 'available' && (t.contentHash?.isNotEmpty ?? false)) {
        availableContentHashes.add(t.contentHash!);
      }
      final key = songIdentityKey(t);
      if (key == null) {
        singletonSongs++;
        if (t.reviewed) singletonReviewed++;
        continue;
      }
      final prior = reviewedByBucket[key];
      if (prior == null) {
        reviewedByBucket[key] = t.reviewed;
      } else if (!prior && t.reviewed) {
        reviewedByBucket[key] = true;
      }
    }
    // Pass 2 over the missing-only subset: bucket into
    // truly-missing vs coexisting-elsewhere by content_hash match.
    // A missing row with a known content_hash that appears on at
    // least one available row is "coexisting" — UI counts it as
    // moved rather than missing.
    final coexistingPaths = <String>{};
    var trulyMissing = 0;
    for (final t in missingTracks) {
      final ch = t.contentHash;
      if (ch != null && ch.isNotEmpty &&
          availableContentHashes.contains(ch)) {
        coexistingPaths.add(t.path);
      } else {
        trulyMissing++;
      }
    }
    var reviewedBucketed = 0;
    for (final v in reviewedByBucket.values) {
      if (v) reviewedBucketed++;
    }
    _enrichedCountCache = enriched;
    _enrichingCountCache = enriching;
    _failedEnrichmentCountCache = failedEnrichment;
    _missingCountCache = trulyMissing;
    _movedCountCache = supersededCount + coexistingPaths.length;
    _coexistingMissingPathsCache = coexistingPaths;
    _songCountCache = singletonSongs + reviewedByBucket.length;
    _reviewedSongCountCache = singletonReviewed + reviewedBucketed;
    _libraryStatsVersion = _dataVersion;
  }

  /// Paths of rows whose `availability_state == 'missing'` but
  /// whose `content_hash` is present on at least one available
  /// row anywhere in the library. UI surfaces (Review dialog,
  /// status bar tally) treat these as "found elsewhere" — folded
  /// into the MOVED count, NOT the MISSING count, since the bytes
  /// haven't been lost. The DB state stays `'missing'` because
  /// uniqueness fails (≥ 2 byte-twins available); only the user
  /// can pick a single successor manually.
  // ── Activity log proxies (Sub-slice C) ─────────────────────────
  //
  // Thin pass-throughs to LibraryRepository so the History panel
  // widget doesn't need a direct repo handle. Not cached — the
  // panel does a single load on open / refresh, not on every
  // controller notify; query cost is small (LIMIT 250) and the
  // events index covers it.

  /// Paginated activity feed for the History panel. Newest first.
  Future<List<ActivityEvent>> loadActivityFeed({
    int limit = 250,
    int offset = 0,
    List<String>? eventTypes,
  }) {
    return repo.loadRecentEvents(
      limit: limit,
      offset: offset,
      eventTypes: eventTypes,
    );
  }

  /// Lifetime event count — for "X of Y" tally text in the panel
  /// header.
  Future<int> activityEventCount() => repo.eventCount();

  /// Snapshot of top-level source IDs whose `folder_path` does
  /// not currently exist on disk. The sidebar uses this to render
  /// missing-folder tiles dimmed with a "Folder missing" subtitle,
  /// so the user can tell the difference between "this source has
  /// some tracks gone" (per-track availability) and "the entire
  /// watched root is gone" (this set).
  ///
  /// Returns a view of the internal set; callers shouldn't mutate.
  /// Sub-views never appear here — they piggyback on their parent's
  /// state and have no folder of their own.
  Set<String> get missingFolderSourceIds =>
      Set.unmodifiable(_missingFolderSourceIds);

  /// Convenience for sidebar tiles: returns `true` when [sourceId]
  /// is a top-level source whose watched folder isn't on disk
  /// right now. Cheap (Set lookup); safe to call per-frame.
  bool isSourceFolderMissing(String sourceId) =>
      _missingFolderSourceIds.contains(sourceId);

  /// Recompute the missing-folder set across every source —
  /// top-level AND sub-views. A sub-view is a saved filter
  /// pointing at a path prefix inside its parent (e.g., Q is a
  /// sub-view of Afro:Tech:Deep filtering tracks under
  /// `…/Afro:Tech:Deep/Q/`). When the user deletes that
  /// sub-folder in Finder, the sub-view's `folderPath` no
  /// longer exists either, even though the parent does — the
  /// sidebar still needs to mark it missing so the user sees
  /// the dead lens for what it is.
  ///
  /// Cheap — one `existsSync` per source, which resolves to a
  /// single stat. Called at hydrate, at scan start, after
  /// source add/remove, and on watcher-failure paths.
  ///
  /// Returns `true` if the set changed (so callers can decide
  /// whether to `notifyListeners`).
  bool _refreshMissingFolderSet() {
    final before = Set<String>.from(_missingFolderSourceIds);
    _missingFolderSourceIds.clear();
    for (final s in _sources) {
      try {
        if (!Directory(s.folderPath).existsSync()) {
          _missingFolderSourceIds.add(s.id);
        }
      } catch (_) {
        // existsSync can throw on some failure modes (permission
        // denied at a parent, broken symlink). Treat any throw as
        // "we can't see this folder" → missing. The user can
        // recover by reconnecting whatever underlying storage
        // dropped out.
        _missingFolderSourceIds.add(s.id);
      }
    }
    return before.length != _missingFolderSourceIds.length ||
        !before.containsAll(_missingFolderSourceIds);
  }

  Set<String> get coexistingMissingPaths {
    _ensureLibraryStats();
    return _coexistingMissingPathsCache ?? const <String>{};
  }
  ValueListenable<Duration> get positionListenable => _positionNotifier;
  ValueListenable<int> get revealTick => _revealTick;

  int get totalTrackCount => _tracks.length;

  /// Whole-library view in insertion order. Read-only — callers
  /// must not mutate. Use this for cross-library pickers (e.g., the
  /// manual link-target dialog) that need to see tracks regardless
  /// of source / search filters.
  List<Track> get allTracks => List.unmodifiable(_tracks);
  int get libraryVersion => _libraryVersion;

  int get playThresholdSeconds => _playThresholdSeconds;
  double get colFavWidth => _colFavWidth;
  double get colRevWidth => _colRevWidth;
  double get colBpmWidth => _colBpmWidth;
  double get colKeyWidth => _colKeyWidth;
  double get colTimeWidth => _colTimeWidth;
  double get colFormatWidth => _colFormatWidth;
  double get colPlaysWidth => _colPlaysWidth;

  /// Aggregated cell values for a collapsed bucket whose primary
  /// row is [primary]. Returns `null` when [primary] is not a bucket
  /// primary or before the visible-tracks pipeline has been run.
  AggregatedTrackView? aggregatedViewForPrimary(Track primary) =>
      _bucketsByPrimaryUid[primary.uid];

  /// Cheap cached count of multi-variant buckets in the library —
  /// drives the `AUDIT N` badge in the utility rail. Without this,
  /// every notifyListeners rebuilt the rail and recomputed
  /// `groupBySongIdentity` on the full track list (12k+ items), which
  /// saturated the UI thread during normal browsing. Caching at
  /// `_libraryVersion` granularity means the count is computed once
  /// per data/filter change and read back in O(1) for subsequent
  /// rebuilds.
  int get multiVariantBucketCount {
    if (_multiVariantBucketCountVersion != _dataVersion) {
      var count = 0;
      for (final bucket in groupBySongIdentity(_tracks)) {
        var available = 0;
        for (final t in bucket) {
          if (!t.isAvailable) continue;
          available++;
          if (available >= 2) {
            count++;
            break; // early exit — we only care whether it's >=2
          }
        }
      }
      _multiVariantBucketCountCache = count;
      _multiVariantBucketCountVersion = _dataVersion;
    }
    return _multiVariantBucketCountCache;
  }

  int _multiVariantBucketCountCache = 0;
  int _multiVariantBucketCountVersion = -1;

  /// Every multi-variant bucket the matcher has assembled across the
  /// whole library (manual link, auto 4-field, fingerprint
  /// equivalence — any rule that paired two files), independent of
  /// the current source / search filters. Sorted by total filesize
  /// descending so the biggest-impact duplicates surface first.
  ///
  /// Used by the duplicates audit dialog; recomputed each call so a
  /// rescan or a fresh link / unlink immediately reflects in the
  /// dialog without needing a `visibleTracks` round-trip. The audit
  /// dialog is opened explicitly, so the recompute cost (one
  /// `groupBySongIdentity` pass + sort) only fires on user action —
  /// not per UI rebuild. The badge in the rail uses
  /// `multiVariantBucketCount` instead.
  List<AggregatedTrackView> get multiVariantBuckets {
    final out = <AggregatedTrackView>[];
    for (final bucket in groupBySongIdentity(_tracks)) {
      // Only count available variants. A bucket with one available
      // + one unavailable variant has no actual duplicate problem
      // to audit (the unavailable one is already going away).
      final ordered = orderBucketByPlaybackPreference(
        bucket.where((t) => t.isAvailable).toList(growable: false),
      );
      if (ordered.length < 2) continue;
      out.add(AggregatedTrackView(ordered));
    }
    out.sort((a, b) {
      final sa = _bucketFilesize(a);
      final sb = _bucketFilesize(b);
      return sb.compareTo(sa); // desc
    });
    return out;
  }

  /// Sum of the on-disk filesizes for every variant in [view].
  /// Helper for the audit dialog header + per-row total. Filesize is
  /// per-file (lives on `indexed_files`) so it's always at the
  /// variant level, not aggregated by slice 3.
  int _bucketFilesize(AggregatedTrackView view) {
    var total = 0;
    for (final t in view.variants) {
      total += t.filesize;
    }
    return total;
  }

  /// `true` when [primary] is the displayed primary of a multi-
  /// variant bucket — used by the right-click handler to decide
  /// whether to surface a per-format "Show in Finder" submenu.
  bool primaryHasSiblings(Track primary) {
    final view = _bucketsByPrimaryUid[primary.uid];
    return view != null && view.hasSiblings;
  }
  double get colLastPlayedWidth => _colLastPlayedWidth;
  double get colTitleWidth => _colTitleWidth;
  double get colArtistWidth => _colArtistWidth;

  List<String> get columnOrder => List.unmodifiable(_columnOrder);

  // ---------------------------------------------------------------------------
  // Settings + UI prefs
  // ---------------------------------------------------------------------------

  Future<void> moveColumn(String column, int targetIndex) async {
    final from = _columnOrder.indexOf(column);
    if (from < 0) return;
    final adjusted = targetIndex > from ? targetIndex - 1 : targetIndex;
    final clamped = adjusted.clamp(0, _columnOrder.length - 1);
    if (clamped == from) return;
    _columnOrder.removeAt(from);
    _columnOrder.insert(clamped, column);
    notifyListeners();
    await repo.setSetting('column_order', _columnOrder.join(','));
  }

  static const _playThresholdPresets = <int>[3, 5, 10, 15, 30];

  Future<void> cyclePlayThreshold() async {
    final idx = _playThresholdPresets.indexOf(_playThresholdSeconds);
    final next =
        _playThresholdPresets[(idx + 1) % _playThresholdPresets.length];
    await _setPlayThresholdSeconds(next);
  }

  double get volume => _volume;

  Future<void> setVolume(double v, {bool commit = false}) async {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    if (clamped == _volume) {
      if (commit) await repo.setSetting('volume', _volume.toString());
      return;
    }
    _volume = clamped;
    volumeListenable.value = _volume;
    await engine.setVolume(_volume);
    if (commit) await repo.setSetting('volume', _volume.toString());
  }

  bool get sidebarVisible => _sidebarVisible;
  double get sidebarWidth => _sidebarWidth;

  Future<void> toggleSidebarVisible() async {
    _sidebarVisible = !_sidebarVisible;
    notifyListeners();
    await repo.setSetting('sidebar_visible', _sidebarVisible ? '1' : '0');
  }

  Future<void> setSidebarWidth(double w, {bool commit = false}) async {
    final clamped = w.clamp(sidebarMinWidth, sidebarMaxWidth).toDouble();
    if (clamped == _sidebarWidth) {
      if (commit) {
        await repo.setSetting('sidebar_width', _sidebarWidth.toString());
      }
      return;
    }
    _sidebarWidth = clamped;
    notifyListeners();
    if (commit) {
      await repo.setSetting('sidebar_width', _sidebarWidth.toString());
    }
  }

  Future<void> _setPlayThresholdSeconds(int s) async {
    _playThresholdSeconds = s;
    notifyListeners();
    await repo.setSetting('play_threshold_seconds', s.toString());
  }

  Future<void> setColumnWidth(
    String column,
    double width, {
    bool commit = true,
  }) async {
    double clamped;
    switch (column) {
      case 'fav':
        clamped = width.clamp(32.0, 80.0);
        _colFavWidth = clamped;
        break;
      case 'rev':
        clamped = width.clamp(40.0, 80.0);
        _colRevWidth = clamped;
        break;
      case 'bpm':
        clamped = width.clamp(44.0, 120.0);
        _colBpmWidth = clamped;
        break;
      case 'key':
        clamped = width.clamp(44.0, 120.0);
        _colKeyWidth = clamped;
        break;
      case 'time':
        clamped = width.clamp(48.0, 120.0);
        _colTimeWidth = clamped;
        break;
      case 'format':
        clamped = width.clamp(80.0, 200.0);
        _colFormatWidth = clamped;
        break;
      case 'plays':
        clamped = width.clamp(52.0, 120.0);
        _colPlaysWidth = clamped;
        break;
      case 'lastPlayed':
        clamped = width.clamp(60.0, 200.0);
        _colLastPlayedWidth = clamped;
        break;
      case 'title':
        clamped = width.clamp(120.0, 1500.0);
        _colTitleWidth = clamped;
        break;
      case 'artist':
        clamped = width.clamp(100.0, 1200.0);
        _colArtistWidth = clamped;
        break;
      default:
        return;
    }
    notifyListeners();
    if (commit) {
      await repo.setSetting('col_${column}_width', clamped.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Track lookups
  // ---------------------------------------------------------------------------

  int sourceTrackCount(String sourceId) {
    // Per-source counts depend only on which tracks belong to which
    // source, not the user's filter. Reads from the same cached
    // walk that produces ready / enriching / waitingOnCloud — one
    // pass populates everything.
    _ensureSourceStats();
    return _sourceStatsCache?[sourceId]?.total ?? 0;
  }

  /// Contextual operational progress for a single source. Powers
  /// the status bar's source-scoped enrichment cluster ("Q ·
  /// enriching · 32 / 87 ready · 18 waiting on Dropbox"). Returns
  /// `null` when [sourceId] is unknown.
  ///
  /// Sub-views (filtered lenses on a parent's tracks) get their
  /// own stats from the same path-prefix match used elsewhere in
  /// the codebase, so progress reads as "what's happening to the
  /// tracks I'm currently looking at" rather than the parent's
  /// globals.
  ({int total, int ready, int enriching, int waitingOnCloud})?
      progressForSource(String sourceId) {
    _ensureSourceStats();
    final stats = _sourceStatsCache?[sourceId];
    if (stats == null) return null;
    return (
      total: stats.total,
      ready: stats.ready,
      enriching: stats.enriching,
      waitingOnCloud: stats.waitingOnCloud,
    );
  }

  void _ensureSourceStats() {
    if (_sourceStatsCache == null ||
        _sourceStatsCacheVersion != _dataVersion) {
      _sourceStatsCache = _computeAllSourceCounts();
      _sourceStatsCacheVersion = _dataVersion;
    }
  }

  /// Walk the in-memory tracks once and bucket per source. Sub-views
  /// (filtered lenses) get their own stats from a path-prefix match
  /// against the parent's tracks. Called once per library-version
  /// change; subsequent reads are O(1).
  ///
  /// Records four counters per source in the same pass:
  ///   - `total` — every visible track in scope
  ///   - `ready` — `EnrichmentState.ready`
  ///   - `enriching` — `EnrichmentState.enriching`
  ///   - `waitingOnCloud` — `enriching` AND path is cloud-backed
  ///     (the status bar appends a "N waiting on Dropbox" note
  ///     when this is nonzero so the user sees the external cause)
  Map<String, _SourceStats> _computeAllSourceCounts() {
    final stats = <String, _SourceStats>{};
    final subViews = [for (final s in _sources) if (s.isSubView) s];
    for (final t in _tracks) {
      final isEnriching = t.enrichmentState == EnrichmentState.enriching;
      final isReady = t.enrichmentState == EnrichmentState.ready;
      final isWaitingOnCloud = isEnriching && _isCloudPath(t.path);
      final ownerStats = stats[t.sourceId] ??= _SourceStats();
      ownerStats.bump(
        isReady: isReady,
        isEnriching: isEnriching,
        isWaitingOnCloud: isWaitingOnCloud,
      );
      for (final sv in subViews) {
        if (sv.parentSourceId == t.sourceId &&
            t.path.startsWith(sv.pathPrefix!)) {
          final subStats = stats[sv.id] ??= _SourceStats();
          subStats.bump(
            isReady: isReady,
            isEnriching: isEnriching,
            isWaitingOnCloud: isWaitingOnCloud,
          );
        }
      }
    }
    return stats;
  }

  Track? get currentTrack {
    final uid = _currentTrackUid;
    if (uid != null) {
      final byUid = _tracksByUid[uid];
      if (byUid != null) return byUid;
    }
    // Playback-priority fallback: the audio engine plays a file
    // PATH; `_currentTrackPath` is the most stable identity we
    // have across scan reloads. If a watcher-triggered rescan
    // shifted the row's uid (e.g., Dropbox sync bumped mtime → new
    // uid; `computeTrackUid` hashes mtime), the uid lookup misses
    // but the path lookup still resolves. Without this fallback
    // the deck reads "No track selected" mid-playback and every
    // playback-driving action (seek / favorite / play-count /
    // review) silently no-ops because they gate on `currentTrack`.
    final path = _currentTrackPath;
    if (path != null) {
      final byPath = _tracksByPath[path];
      if (byPath != null) return byPath;
    }
    return null;
  }

  Track? _trackByUid(String uid) => _tracksByUid[uid];

  Track? _trackByPath(String path) => _tracksByPath[path];

  /// Replace the in-memory track list and rebuild the lookup maps.
  /// Call sites: hydrate, scan reload, import.
  ///
  /// **Playback continuity contract:** if a track is currently
  /// playing, its row's UID may have shifted (Dropbox sync bumped
  /// mtime → `computeTrackUid` re-hashed → new uid for the same
  /// path). `_currentTrackUid` would then point at a uid that no
  /// longer exists in the new map → `currentTrack` returns null
  /// → deck reads "No track selected" mid-playback and every
  /// playback-action (seek, favorite, play-count, review) silently
  /// no-ops because they gate on `currentTrack`.
  ///
  /// Path is the most stable identity we have across reloads.
  /// After the rebuild, if the playing path still resolves to a
  /// row, snap `_currentTrackUid` to that row's current uid so
  /// the deck stays linked. Belt + suspenders with `currentTrack`'s
  /// path fallback — both guards handle the same hazard from
  /// different angles.
  void _replaceTracks(List<Track> tracks) {
    _tracks
      ..clear()
      ..addAll(tracks);
    _tracksByUid.clear();
    _tracksByPath.clear();
    for (final t in tracks) {
      _tracksByUid[t.uid] = t;
      _tracksByPath[t.path] = t;
    }
    // Self-heal the playing-track link. Only fires when there's
    // an actually-playing track AND its path survived the rebuild
    // (the file disappearing entirely is handled by the
    // `removeSource` / availability paths, not here).
    final playingPath = _currentTrackPath;
    if (playingPath != null) {
      final reHydrated = _tracksByPath[playingPath];
      if (reHydrated != null && reHydrated.uid != _currentTrackUid) {
        _currentTrackUid = reHydrated.uid;
      }
    }
  }

  /// Remove tracks where [test] returns true, keeping the maps in
  /// sync. Used by `removeSource` for top-level sources.
  void _removeTracksWhere(bool Function(Track) test) {
    _tracks.removeWhere((t) {
      if (test(t)) {
        _tracksByUid.remove(t.uid);
        _tracksByPath.remove(t.path);
        return true;
      }
      return false;
    });
  }

  List<Track> get recentReviewedTracks => [
    for (final uid in _recentReviewedUids)
      if (_trackByUid(uid) != null) _trackByUid(uid)!,
  ];

  void _pushRecentReviewed(String uid) {
    _recentReviewedUids.remove(uid);
    _recentReviewedUids.insert(0, uid);
    if (_recentReviewedUids.length > _recentBufferCapacity) {
      _recentReviewedUids.removeLast();
    }
  }

  int? trailIndexOf(String uid) {
    final upper = _recentReviewedUids.length < _trailVisibleCount
        ? _recentReviewedUids.length
        : _trailVisibleCount;
    for (var i = 0; i < upper; i++) {
      if (_recentReviewedUids[i] == uid) return i;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Visible-tracks pipeline
  // ---------------------------------------------------------------------------

  List<Track> get visibleTracks {
    if (_visibleCache != null && _visibleCacheVersion == _libraryVersion) {
      return _visibleCache!;
    }
    final result = _computeGroupedVisible();
    _visibleCache = result;
    _visibleCacheVersion = _libraryVersion;
    return result;
  }

  // ---------------------------------------------------------------------------
  // Grouped pipeline: group ALL tracks by song identity first, then filter
  // at the bucket level (source / unreviewed / search). Sort and sticky-
  // current operate on primaries using aggregated values. This is the path
  // that keeps a song's variant set intact across source views — e.g., when
  // the user navigates into "Z CRATE", a song whose MP3 lives in a different
  // crate still shows `MP3 · AIFF` and the favorite that was set on the MP3.
  // ---------------------------------------------------------------------------

  List<Track> _computeGroupedVisible() {
    // Step 1: group the whole library. Order each bucket so the
    // lowest-quality format (the displayed primary) is at index 0.
    //
    // Variant-presence rule (user policy: "removed from disk =
    // removed from view"):
    //   - At least one variant available → show only the available
    //     variants in the bucket. Unavailable siblings stay in the
    //     DB and rejoin the bucket when their source comes back,
    //     but they don't pollute the FORMAT cell / primary picker
    //     while they're gone.
    //   - Every variant unavailable → drop the bucket from the
    //     visible table. The `tracks` intel row (favorite,
    //     play_count, cumulative listening, review state) lives
    //     on regardless, so re-adding the file to any watched
    //     source reconnects automatically — the user's history
    //     isn't lost, just the now-stale row.
    final rawBuckets = groupBySongIdentity(_tracks);
    final buckets = <List<Track>>[];
    for (final raw in rawBuckets) {
      final available =
          raw.where((t) => t.isAvailable).toList(growable: false);
      if (available.isEmpty) continue;
      buckets.add(orderBucketByPlaybackPreference(available));
    }
    // Build the per-bucket aggregated view once so filter / sort don't
    // have to recompute.
    final views = <String, AggregatedTrackView>{
      for (final b in buckets) b.first.uid: AggregatedTrackView(b),
    };

    // Step 2: bucket-level filtering. A bucket passes if ANY variant
    // satisfies the filter. This keeps variant sets intact across
    // source / search views — the user sees the song with full
    // FORMAT aggregation and aggregated stats regardless of which
    // crate / folder they're currently looking at.
    Iterable<List<Track>> filtered = buckets;

    if (_selectedSourceId != null) {
      final selected = _sourceById(_selectedSourceId!);
      bool matchesSource(Track t) {
        if (selected != null && selected.isSubView) {
          return t.sourceId == selected.parentSourceId &&
              t.path.startsWith(selected.pathPrefix!);
        }
        return t.sourceId == _selectedSourceId;
      }
      filtered = filtered.where((b) => b.any(matchesSource));
    }

    if (_unreviewedOnly) {
      final exemptUids = _unreviewedExemptUids();
      filtered = filtered.where((b) {
        // Aggregated reviewed = any variant's cumulativeListened sum
        // ≥ threshold. Exempt-uid match on any variant keeps the
        // recent-reviewed trail and the currently-playing bucket
        // visible while filtering everything else.
        final view = views[b.first.uid]!;
        if (!view.reviewed) return true;
        return b.any((t) => exemptUids.contains(t.uid));
      });
    }

    if (_searchQuery.isNotEmpty) {
      final matcher = _buildSearchMatcher();
      filtered = filtered.where((b) => b.any(matcher));
    }

    // Step 3: emit primaries and sort using aggregated values where
    // applicable so the user's mental model ("the song has 13 plays")
    // matches what they sort by.
    final primaries = filtered.map((b) => b.first).toList();
    final dir = _sortAscending ? 1 : -1;
    primaries.sort((a, b) {
      final va = views[a.uid]!;
      final vb = views[b.uid]!;
      switch (_sortColumn) {
        case TrackSortColumn.favorite:
          return dir * ((va.favorite ? 1 : 0) - (vb.favorite ? 1 : 0));
        case TrackSortColumn.reviewed:
          return dir * ((va.reviewed ? 1 : 0) - (vb.reviewed ? 1 : 0));
        case TrackSortColumn.title:
          return dir *
              a.displayTitle
                  .toLowerCase()
                  .compareTo(b.displayTitle.toLowerCase());
        case TrackSortColumn.artist:
          final aa = a.displayArtist.toLowerCase();
          final ba = b.displayArtist.toLowerCase();
          if (aa.isEmpty && ba.isEmpty) return 0;
          if (aa.isEmpty) return 1;
          if (ba.isEmpty) return -1;
          return dir * aa.compareTo(ba);
        case TrackSortColumn.bpm:
          // Aggregated BPM honours blank-on-disagreement. Buckets
          // with a usable value sort numerically; rows that show "—"
          // sink to the bottom in both directions.
          final ab = va.bpm;
          final bb = vb.bpm;
          if (ab == null && bb == null) return 0;
          if (ab == null) return 1;
          if (bb == null) return -1;
          return dir * ab.compareTo(bb);
        case TrackSortColumn.key:
          final ak = camelotSortIndex(va.displayKey);
          final bk = camelotSortIndex(vb.displayKey);
          if (ak == unknownSortIndex && bk == unknownSortIndex) return 0;
          if (ak == unknownSortIndex) return 1;
          if (bk == unknownSortIndex) return -1;
          return dir * ak.compareTo(bk);
        case TrackSortColumn.duration:
          return dir * a.duration.compareTo(b.duration);
        case TrackSortColumn.format:
          // Three-level sort delegated to `compareFormatBuckets`:
          //   1. Tier (exact / contains / lacks the lead)
          //   2. formatLabel — same-combo rows form adjacent
          //      blocks so the user sees "format family blocks"
          //      while scrolling rather than title-interleaved
          //      combos
          //   3. Title ascending — within each block
          //
          // Direction toggle doesn't apply to FORMAT — clicks
          // advance the lead instead of flipping asc/desc.
          return compareFormatBuckets(
            va,
            vb,
            formatSortLeads[_sortFormatMode],
          );
        case TrackSortColumn.plays:
          return dir * va.playCount.compareTo(vb.playCount);
        case TrackSortColumn.lastPlayed:
          final la = va.lastPlayedAt;
          final lb = vb.lastPlayedAt;
          if (la == null && lb == null) return 0;
          if (la == null) return 1;
          if (lb == null) return -1;
          return dir * la.compareTo(lb);
      }
    });

    // Step 4: sticky-current. The current track may be the primary OR
    // a sibling — pin whichever bucket *contains* it. Matches the
    // existing flat-pipeline rule (lock natural index on first
    // observation, otherwise move the row to honour the lock).
    _applyStickyCurrent(primaries, (primary) {
      final view = views[primary.uid]!;
      return view.variants.any((t) => t.uid == _currentTrackUid);
    });

    // Step 5: trim the bucket map to visible primaries only. The table
    // builds row-level renderers off this map (`aggregatedViewForPrimary`)
    // and consults it for context-menu variant lists — no point
    // exposing buckets the user can't see in the current view.
    final visibleViews = <String, AggregatedTrackView>{
      for (final p in primaries) p.uid: views[p.uid]!,
    };
    _bucketsByPrimaryUid = visibleViews;
    return primaries;
  }

  // ---------------------------------------------------------------------------
  // Shared filter / sort / sticky helpers — kept private to the controller.
  // ---------------------------------------------------------------------------

  Set<String> _unreviewedExemptUids() {
    final exempt = <String>{};
    if (_currentTrackUid != null) exempt.add(_currentTrackUid!);
    final upper = _recentReviewedUids.length < _trailVisibleCount
        ? _recentReviewedUids.length
        : _trailVisibleCount;
    for (var i = 0; i < upper; i++) {
      exempt.add(_recentReviewedUids[i]);
    }
    return exempt;
  }

  /// Builds the per-track search predicate. Reused by both pipelines so
  /// the search semantics ("Dm" finds 7A-tagged, "7A" finds Dm-tagged,
  /// raw musicalKey contains, display fields contain) stay identical
  /// whether grouping is on or off.
  bool Function(Track) _buildSearchMatcher() {
    final q = _searchQuery.toLowerCase();
    final qCamelot = normalizeKeyToCamelot(_searchQuery)?.toLowerCase();
    return (t) {
      if (t.displayTitle.toLowerCase().contains(q)) return true;
      if (t.displayArtist.toLowerCase().contains(q)) return true;
      if (t.rawKey.toLowerCase().contains(q)) return true;
      if (t.displayKey.toLowerCase().contains(q)) return true;
      if (qCamelot != null && t.displayKey.toLowerCase() == qCamelot) {
        return true;
      }
      return false;
    };
  }

  /// Locks the row identified by [matchesCurrent] to the index where it
  /// first appeared in the sorted list; if it later sorts to a
  /// different natural position (because its play count / favorite /
  /// last-played changed under the hood), move it back to the locked
  /// index so the user's eye doesn't have to chase the row.
  void _applyStickyCurrent(
    List<Track> rows,
    bool Function(Track) matchesCurrent,
  ) {
    if (_currentTrackUid == null) return;
    final naturalIdx = rows.indexWhere(matchesCurrent);
    if (naturalIdx < 0) return;
    if (_lockedCurrentIndex == null) {
      _lockedCurrentIndex = naturalIdx;
      return;
    }
    if (naturalIdx == _lockedCurrentIndex) return;
    final t = rows.removeAt(naturalIdx);
    final insertAt = _lockedCurrentIndex!.clamp(0, rows.length);
    rows.insert(insertAt, t);
  }

  void _markLibraryDirty() {
    _libraryVersion++;
    _dataVersion++;
    _visibleCache = null;
    // Source-count cache uses `_dataVersion` and invalidates lazily
    // on the next `sourceTrackCount` call.
  }

  /// Filter-only invalidation — search, source selection, sort,
  /// unreviewed-only toggle, sticky-current shifts. Bumps just the
  /// visible-cache version; library-wide counts (songCount,
  /// sourceTrackCount, multiVariantBucketCount, etc) stay valid
  /// because the underlying track data didn't change. Reduces
  /// per-keystroke cost on the search box from ~3 O(n) recomputes
  /// down to just the necessary visible-tracks rebuild.
  void _markFilterDirty() {
    _libraryVersion++;
    _visibleCache = null;
  }

  /// Bumped only when track DATA changes (list mutations, isAvailable
  /// flips, intel field updates). Used by caches whose value depends
  /// solely on the track set, not on filter state.
  int _dataVersion = 0;

  /// Coalesced notifier used by long-running enrichment loops
  /// (metadata extraction, future reconciliation). Guarantees at
  /// most one rebuild per ~500ms while still firing eventually
  /// after the last update.
  void _notifyThrottled() {
    final now = DateTime.now();
    final since = now.difference(_lastThrottledNotifyAt).inMilliseconds;
    if (since >= 500) {
      _lastThrottledNotifyAt = now;
      _throttledNotifyTimer?.cancel();
      _throttledNotifyTimer = null;
      notifyListeners();
      return;
    }
    if (_throttledNotifyTimer?.isActive == true) return;
    _throttledNotifyTimer = Timer(
      Duration(milliseconds: 500 - since),
      () {
        _lastThrottledNotifyAt = DateTime.now();
        _throttledNotifyTimer = null;
        notifyListeners();
      },
    );
  }

  void _invalidateLock() {
    _lockedCurrentIndex = null;
  }

  // ---------------------------------------------------------------------------
  // Sources — add / rescan / remove
  // ---------------------------------------------------------------------------

  /// Find the top-level scanning source whose `folder_path` contains
  /// [pickedPath] as a strict descendant. Returns `null` if [pickedPath]
  /// equals an existing source path or isn't nested under any.
  ///
  /// Sub-views are skipped — only scanning sources can become parents
  /// (nested-of-nested collapses to "sub-view of the top-level
  /// scanning ancestor").
  Source? findContainingSource(String pickedPath) {
    final sep = Platform.pathSeparator;
    for (final s in _sources) {
      if (s.isSubView) continue;
      if (pickedPath == s.folderPath) return null; // exact match
      final prefix = s.folderPath.endsWith(sep)
          ? s.folderPath
          : s.folderPath + sep;
      if (pickedPath.startsWith(prefix)) return s;
    }
    return null;
  }

  Source? _sourceById(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Add a new watched source.
  ///
  /// If [folderPath] is nested inside an existing top-level source,
  /// this short-circuits to a virtual sub-view (no scan, no
  /// `indexed_files` writes, no source-ownership transfer). Otherwise
  /// it's a fresh top-level scanning source: performs the initial
  /// scan with the requested [scanMode] and indexes discovered files
  /// into `indexed_files`. Workflow intelligence is **not** materialised
  /// during scan — that happens lazily on user interaction.
  Future<void> addSource(
    String folderPath,
    ScanMode scanMode, {
    String? displayName,
  }) async {
    debugPrint('[addSource] path=$folderPath mode=$scanMode');
    if (_sources.any((s) => s.folderPath == folderPath)) {
      final existing = _sources.firstWhere((s) => s.folderPath == folderPath);
      debugPrint(
        '[addSource] exact match → ${existing.isSubView ? "subview, return" : "rescan"}',
      );
      if (existing.isSubView) return; // sub-views never scan
      await rescanSource(existing.id);
      return;
    }

    final containing = findContainingSource(folderPath);
    debugPrint(
      '[addSource] containing=${containing?.displayName ?? "<none>"}',
    );
    if (containing != null) {
      await _addSubView(folderPath, parent: containing, displayName: displayName);
      return;
    }

    final source = Source(
      id: _uuid.v4(),
      displayName: displayName ?? _displayNameFor(folderPath),
      folderPath: folderPath,
      scanMode: scanMode,
      enabled: true,
      lastScanAt: null,
      trackCount: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    await repo.insertSource(source);
    _sources.add(source);
    notifyListeners();

    await _scanIntoSource(source);
    unawaited(_startWatcher(source));
  }

  /// Insert a sub-view source row. Sub-views never scan, never own
  /// `indexed_files` rows, never participate in availability —
  /// they're virtual filtered lenses over the parent's tracks
  /// keyed by exact path-prefix.
  Future<void> _addSubView(
    String folderPath, {
    required Source parent,
    String? displayName,
  }) async {
    final sep = Platform.pathSeparator;
    final prefix = folderPath.endsWith(sep) ? folderPath : folderPath + sep;
    final source = Source(
      id: _uuid.v4(),
      displayName: displayName ?? _displayNameFor(folderPath),
      folderPath: folderPath,
      scanMode: ScanMode.recursive, // unused for sub-views
      enabled: true,
      lastScanAt: null,
      trackCount: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      parentSourceId: parent.id,
      pathPrefix: prefix,
    );
    // Don't swallow insert errors — earlier silent-failure variant
    // produced the "toast says added, sidebar shows nothing" bug
    // because the snackbar was fired regardless of DB outcome.
    // Letting the exception propagate lets the sidebar surface the
    // real error to the user.
    await repo.insertSource(source);
    debugPrint(
      '[_addSubView] inserted id=${source.id} parent=${parent.id} prefix=$prefix',
    );
    _sources.add(source);
    _markLibraryDirty();
    notifyListeners();
  }

  /// Re-scan an existing source. Existing rows for this source whose
  /// files are still present are preserved (intelligence intact); rows
  /// not seen this scan are flagged unavailable, never deleted.
  ///
  /// Concurrent requests for the same source dedupe: a second caller
  /// while a scan is in flight gets the same Future as the first.
  /// Without this guard, the FS watcher + focus-rescan + manual
  /// REFRESH could all kick off overlapping scans of the same source
  /// at the same time and race on a shared SQLite transaction —
  /// `txnSynchronized` would then throw mid-batch and the whole
  /// rescan would abort before `markUnseenAvailability` ever ran.
  Future<void> rescanSource(String sourceId) async {
    final inFlight = _scansInFlight[sourceId];
    if (inFlight != null) return inFlight;
    final idx = _sources.indexWhere((s) => s.id == sourceId);
    if (idx < 0) return;
    final future = _scanIntoSource(_sources[idx])
        .whenComplete(() => _scansInFlight.remove(sourceId));
    _scansInFlight[sourceId] = future;
    return future;
  }

  // Per-source scan dedup map. See `rescanSource`.
  final Map<String, Future<void>> _scansInFlight = {};

  Future<void> _scanIntoSource(Source source) async {
    _isScanning = true;
    // Refresh source-existence ontology at scan boundary. Cheap
    // (one stat per top-level source) and catches the common
    // "folder was deleted between sessions" or "drive ejected"
    // cases before the per-track availability sweep below runs.
    _refreshMissingFolderSet();
    // Don't cancel the backfill worker. Previous design did, on
    // the theory that the scan and backfill would fight for disk.
    // In practice the scan is a tight CPU+DB loop (the inline-hash
    // bottleneck moved to backfill) and the backfill is throttled
    // to 10 files / 500 ms — they coexist fine. Cancelling here
    // created a pathological loop on cloud-sync storms: each
    // watcher rescan cancelled the backfill mid-hash, then
    // restarted it; the same Dropbox-resident file was re-picked
    // and re-hashed (15+ seconds per attempt) on every cycle.
    // Reset the hashing instrumentation so the per-scan summary
    // log at the end of this call reflects only THIS scan's work.
    ContentHashStats.reset();
    notifyListeners();
    try {
      // Snapshot the in-memory unavailable count BEFORE the rescan
      // so we can log how many rows changed availability. Quick
      // diagnostic — exposes whether the scan is actually marking
      // deleted files as gone.
      final preUnavailable =
          _tracks.where((t) => t.sourceId == source.id && !t.isAvailable).length;
      final scanStart = Stopwatch()..start();
      // Disk walk + per-file stat now happen inside the scanner
      // isolate; the UI thread stays responsive even on huge cloud
      // libraries.
      final entries = await AudioScanner.scan(
        source.folderPath,
        recursive: source.scanMode == ScanMode.recursive,
      );
      debugPrint(
        '[scan] ${source.displayName}: walked ${entries.length} files in '
        '${scanStart.elapsedMilliseconds}ms (pre-unavailable=$preUnavailable)',
      );

      // Build the batch payload. Carry forward already-known durations
      // so the fingerprint stays stable when we re-upsert files we've
      // already seen.
      final knownPaths = <String>{};
      final batch = <({
        String path,
        String filename,
        int filesize,
        int modifiedAtMs,
        String fallbackTitle,
        int durationMs
      })>[];
      for (final e in entries) {
        final existing = _trackByPath(e.path);
        if (existing != null) knownPaths.add(e.path);
        batch.add((
          path: e.path,
          filename: e.filename,
          filesize: e.filesize,
          modifiedAtMs: e.modifiedAtMs,
          fallbackTitle: filenameWithoutExtension(e.path),
          durationMs: existing?.duration.inMilliseconds ?? 0,
        ));
      }

      // Upsert can throw (UNIQUE constraint, SQLite lock, schema
      // mismatch); we want the rescan to keep going so deleted files
      // still get marked unavailable downstream. Otherwise an upsert
      // failure mid-scan leaves the in-memory state stale forever.
      final upsertStart = Stopwatch()..start();
      try {
        final inserted = await repo.upsertIndexedFilesBatch(
          sourceId: source.id,
          files: batch,
        );
        debugPrint(
          '[scan] upsert batch: ${batch.length} files '
          '($inserted new) in ${upsertStart.elapsedMilliseconds}ms',
        );
      } catch (e, st) {
        debugPrint(
          '[scan] upsert FAILED for ${source.displayName} '
          '(continuing with availability sweep): $e',
        );
        debugPrint('$st');
      }

      final reconciliation = await repo.markUnseenAvailability(
        source.id,
        {for (final e in entries) e.path},
      );
      if (reconciliation.isMaterial) {
        _surfaceReconciliationSummary(source, reconciliation);
      }

      // Auto-detect moved files: any row left in `missing` state
      // whose fingerprint matches an `available` row in the same
      // source is almost certainly a file the user moved within
      // the source. Upgrade those rows to `superseded` so they
      // drop out of the "missing" tally and out of the table —
      // but stay around for the Review-missing dialog.
      final supersededCount =
          await repo.markMovedSupersessions(source.id);
      if (supersededCount > 0) {
        debugPrint(
          '[scan] ${source.displayName}: $supersededCount moved '
          'file(s) auto-detected via fingerprint match',
        );
      }

      // Cross-source relocation pass. Handles the intake → prep
      // → crate workflow: a file moved from one watched source
      // into another should auto-resolve instead of lingering as
      // missing. Strict uniqueness rule (see repo doc) — only
      // fires when exactly one valid same-fingerprint available
      // candidate exists across all sources. Idempotent; we run
      // it on every scan so any source-scan order produces the
      // same final state.
      final crossSourceCount = await repo.markCrossSourceMoves();
      if (crossSourceCount > 0) {
        debugPrint(
          '[scan] cross-source relocation: $crossSourceCount '
          'missing row(s) auto-resolved against a unique '
          'available copy in another watched source',
        );
      }

      // Re-link any new indexed_files row to its existing tracks
      // row by fingerprint. This is what makes "remove → re-add"
      // preserve favorites / play counts visibly: without this,
      // the table would show 0/false until each row was clicked.
      final reconnected =
          await repo.reconnectIntelligenceBySource(source.id);
      debugPrint('[scan] reconnected $reconnected rows to existing intelligence');

      // Reload tracks — rebuild the in-memory list so intel_uid
      // changes (fingerprint migration on re-tag) propagate and
      // newly-discovered rows become visible.
      final allTracks = await repo.loadTracks();
      _replaceTracks(allTracks);

      // Post-scan re-enrichment trigger. The scan upsert marks
      // a row's `metadata_read_at = 0` whenever its
      // `content_hash` diverged at the same path — that's the
      // signal "an external app (Mp3tag / Rekordbox / DAW)
      // rewrote tags or audio bytes; the stored title/artist/
      // album/BPM/key fields are now stale." Without an active
      // enqueue here the reactive viewport-driven enrichment
      // only re-reads when the user scrolls the row in or out,
      // and rows already visible would silently stay frozen at
      // the old values.
      //
      // `enrichSource(source.id)` enqueues any indexed_files
      // row for this source whose `metadata_read_at` is null,
      // which covers both newly-inserted rows AND rows the
      // upsert just invalidated. The enrichment queue runs in
      // the background; we don't block the scan completion on
      // it.
      enrichSource(source.id);

      // Diagnostic: how many rows in this source are now unavailable?
      // If preUnavailable < postUnavailable, the scan correctly
      // marked some files as gone. If unchanged after deleting a
      // file, something is broken — most likely the scanner isn't
      // detecting the file as missing (different source_id? trash
      // folder inside the source root? path normalization?).
      final postUnavailable = allTracks
          .where((t) => t.sourceId == source.id && !t.isAvailable)
          .length;
      debugPrint(
        '[scan] ${source.displayName}: rows for this source '
        'now unavailable=$postUnavailable (was $preUnavailable, delta=${postUnavailable - preUnavailable})',
      );

      final count = await repo.countIndexedFiles(source.id);
      final now = DateTime.now().millisecondsSinceEpoch;
      await repo.updateSourceMeta(
        source.id,
        lastScanAt: now,
        trackCount: count,
      );
      final i = _sources.indexWhere((s) => s.id == source.id);
      if (i >= 0) {
        _sources[i] = _sources[i].copyWith(
          lastScanAt: now,
          trackCount: count,
        );
      }

      _invalidateLock();
      _markLibraryDirty();

      // Reactive-first architecture: NO auto-enqueue here. New rows
      // appear in the table immediately at filename-only display;
      // they enrich on demand when the user scrolls them into view,
      // selects them, or plays them. Avoids the post-scan
      // multi-minute Dropbox materialisation storm we used to
      // trigger by enriching the whole library every scan.
    } catch (e, st) {
      debugPrint('[scan] FAILED: $e');
      debugPrint('$st');
    } finally {
      _isScanning = false;
      // Per-scan hashing summary. One line per scan boundary
      // makes performance regressions and pathological files
      // (slow Dropbox reads, AIFFs on slow NAS) visible without
      // needing a full UI.
      debugPrint(
        '[scan] ${source.displayName}: ${ContentHashStats.summary()}',
      );
      // Resume the content_hash backfill now that foreground
      // scanning is done. Picks up any newly-null rows the scan
      // just inserted as well as legacy rows the migration left
      // unhashed.
      _backfillWorker.start();
      notifyListeners();
      // Record a journal entry first — single event per scan
      // completion, not aggregated. Surfaces in the Load
      // Operational State dialog as "Library scan completed —
      // {source}". Best-effort; failure doesn't block the
      // lifecycle save below.
      try {
        await repo.recordEvent(
          type: EventType.scanCompleted,
          sourceId: source.id,
          payload: {'source_name': source.displayName},
        );
      } catch (e) {
        debugPrint('[journal] scan_completed write failed: $e');
      }
      // Lifecycle save: a scan is a meaningful checkpoint — new
      // rows, new content_hash, often new artwork/metadata. Save
      // even if the autosave tick wouldn't fire for another few
      // minutes so the user can roll back to "post-scan state".
      //
      // Throttled to one save per [_postScanSnapshotInterval]
      // because cloud-sync storms can produce a scan every few
      // seconds; rewriting the multi-MB library file on every
      // scan during a storm pegs disk and starves the UI. The
      // autosave tick covers the windows in between, and the
      // user-initiated Save action is always immediate.
      final now = DateTime.now();
      final last = _lastPostScanSnapshotAt;
      if (last == null ||
          now.difference(last) >= _postScanSnapshotInterval) {
        _lastPostScanSnapshotAt = now;
        unawaited(_snapshotNow());
      }
    }
  }

  /// Start watching [source]'s folder for filesystem events. On any
  /// change (create / modify / delete) inside the folder, schedule a
  /// debounced rescan of just this source so the in-memory library
  /// stays current with what's actually on disk. The user reported
  /// "i just deleted one of those, but still shows up" — this is the
  /// instant-sync path that closes that loop.
  ///
  /// No-op for sub-views (they don't own files), non-existent paths,
  /// and non-macOS platforms (only macOS has been verified to deliver
  /// usable events from `Directory.watch`).
  Future<void> _startWatcher(Source source) async {
    if (!Platform.isMacOS) return;
    if (source.isSubView) return;
    await _stopWatcher(source.id);
    final dir = Directory(source.folderPath);
    if (!await dir.exists()) return;
    try {
      final sub = dir
          .watch(
            events: FileSystemEvent.all,
            recursive: source.scanMode == ScanMode.recursive,
          )
          .listen(
            (event) => _onWatcherEvent(source.id, event),
            onError: (e) => debugPrint(
              '[watcher] ${source.displayName}: $e',
            ),
            cancelOnError: false,
          );
      _watchers[source.id] = sub;
    } catch (e) {
      // Directory.watch can throw on some filesystems (older NFS,
      // unsupported sandbox configurations). Fail soft — manual
      // rescan still works.
      debugPrint('[watcher] failed to start for ${source.displayName}: $e');
    }
  }

  void _onWatcherEvent(String sourceId, FileSystemEvent event) {
    // Useful when diagnosing "I deleted a file but it didn't update":
    // the absence of this log means FSEvents never delivered the
    // change. The lifecycle-resumed rescan covers that case.
    debugPrint('[watcher] $sourceId ${_eventTypeName(event)} '
        '${event.path}${event.isDirectory ? " (dir)" : ""}');
    // Quiescence-based coalescing: reset the timer on every event
    // so the rescan only fires after [_watcherQuietWindow] of
    // silence. Cloud-sync storms (Dropbox materializing 1000 files)
    // can fire events for tens of seconds; a fixed debounce would
    // produce repeated mid-storm rescans, each one nulling content
    // hashes that the backfill worker would then re-compute (15s
    // per file on Dropbox). One rescan at the END of the storm is
    // dramatically cheaper.
    //
    // Hard ceiling: if events keep coming for [_watcherMaxQuietWait]
    // straight without ever quieting, fire a rescan anyway so the
    // library doesn't go stale during a long-running sync.
    final now = DateTime.now();
    _watcherFirstEventAt.putIfAbsent(sourceId, () => now);
    final firstAt = _watcherFirstEventAt[sourceId]!;
    final waitedTooLong = now.difference(firstAt) >= _watcherMaxQuietWait;
    _watcherDebounce[sourceId]?.cancel();
    if (waitedTooLong) {
      // Storm has been continuous past the ceiling — rescan now.
      _watcherDebounce.remove(sourceId);
      _watcherFirstEventAt.remove(sourceId);
      rescanSource(sourceId);
      return;
    }
    _watcherDebounce[sourceId] = Timer(_watcherQuietWindow, () {
      _watcherDebounce.remove(sourceId);
      _watcherFirstEventAt.remove(sourceId);
      rescanSource(sourceId);
    });
  }

  String _eventTypeName(FileSystemEvent e) {
    switch (e.type) {
      case FileSystemEvent.create:
        return 'create';
      case FileSystemEvent.modify:
        return 'modify';
      case FileSystemEvent.delete:
        return 'delete';
      case FileSystemEvent.move:
        return 'move';
      default:
        return '?(${e.type})';
    }
  }

  /// Sequential rescan of every non-sub-view source. Triggered when
  /// the app comes back to foreground; covers the case where the
  /// per-source filesystem watcher missed an event. Guarded against
  /// re-entry so rapid focus toggles don't pile rescans on each other.
  Future<void> _rescanAllOnFocus() async {
    if (_focusRescanInFlight) return;
    _focusRescanInFlight = true;
    try {
      debugPrint(
        '[focus] resumed → rescanning ${_sources.length} sources',
      );
      // Snapshot the list — rescanSource awaits and the sources
      // list could mutate (e.g., user removes one mid-rescan).
      for (final source in _sources.toList()) {
        if (source.isSubView) continue;
        try {
          await rescanSource(source.id);
        } catch (e) {
          debugPrint(
            '[focus] rescan failed for ${source.displayName}: $e',
          );
        }
      }
    } finally {
      _focusRescanInFlight = false;
    }
  }

  /// User-triggered "rescan everything now" (Cmd+R). Reuses the
  /// focus-rescan path — same sequential walk over non-sub-view
  /// sources, same re-entry guard. Exposed so the manual escape
  /// hatch matches the automatic one byte-for-byte.
  Future<void> rescanAllSources() => _rescanAllOnFocus();

  Future<void> _stopWatcher(String sourceId) async {
    final sub = _watchers.remove(sourceId);
    await sub?.cancel();
    _watcherDebounce.remove(sourceId)?.cancel();
  }

  Future<void> _stopAllWatchers() async {
    for (final t in _watcherDebounce.values) {
      t.cancel();
    }
    _watcherDebounce.clear();
    final futures = _watchers.values.map((s) => s.cancel()).toList();
    _watchers.clear();
    await Future.wait(futures);
  }

  /// Remove the source. The FK cascade drops `indexed_files` rows under
  /// it; `tracks` rows are intentionally untouched (guardrail 5 — user
  /// work survives source removal). Re-adding the same folder will
  /// reconnect intelligence by fingerprint.
  Future<void> removeSource(String sourceId) async {
    await _stopWatcher(sourceId);
    await repo.deleteSource(sourceId);
    _sources.removeWhere((s) => s.id == sourceId);
    _missingFolderSourceIds.remove(sourceId);
    _removeTracksWhere((t) => t.sourceId == sourceId);
    final remainingUids = <String>{for (final t in _tracks) t.uid};
    _recentReviewedUids.removeWhere((uid) => !remainingUids.contains(uid));
    if (_selectedSourceId == sourceId) _selectedSourceId = null;
    if (_currentTrackUid != null &&
        !_tracks.any((t) => t.uid == _currentTrackUid)) {
      await engine.stop();
      _currentTrackUid = null;
      _currentTrackPath = null;
      _isPlaying = false;
      _positionNotifier.value = Duration.zero;
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
    }
    _invalidateLock();
    _markLibraryDirty();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Filter / selection
  // ---------------------------------------------------------------------------

  void selectSource(String? sourceId) {
    _selectedSourceId = sourceId;
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  void toggleUnreviewedOnly() {
    _unreviewedOnly = !_unreviewedOnly;
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  void toggleShowArtwork() {
    _showArtwork = !_showArtwork;
    notifyListeners();
  }

  /// Ordered list of which formats lead the FORMAT-column sort.
  /// Each click on the FORMAT header advances through this list,
  /// wrapping at the end.
  ///
  /// First 4 entries are the original single-format leads. Entries
  /// 5–10 are the meaningful 2-format pair combos — when a pair
  /// lead is active, buckets whose variants contain BOTH formats
  /// sort to the top together, letting the user surface things
  /// like "all my MP3+AIFF pairs" by clicking through.
  ///
  /// The matcher / display still prefers the
  /// `aggregated_track_view._formatPreferenceOrder` for playback;
  /// this is purely a sort-visualization knob. The FORMAT header
  /// itself is static — sort state is conveyed only by row order.
  static const List<List<String>> formatSortLeads = [
    ['MP3'],
    ['FLAC'],
    ['WAV'],
    ['AIFF'],
    ['MP3', 'AIFF'],
    ['MP3', 'FLAC'],
    ['MP3', 'WAV'],
    ['FLAC', 'AIFF'],
    ['FLAC', 'WAV'],
    ['WAV', 'AIFF'],
  ];

  int get sortFormatMode => _sortFormatMode;

  /// Display label for the current FORMAT-column lead — e.g.
  /// `'MP3'` for a single-format lead or `'MP3 · AIFF'` for a pair
  /// lead. Matches the visual shape of `AggregatedTrackView.formatLabel`
  /// so any future tooltip / debug surface stays consistent with
  /// what the rows display.
  String get sortFormatLead => formatSortLeads[_sortFormatMode].join(' · ');

  void setSort(TrackSortColumn column) {
    if (_sortColumn == column) {
      // FORMAT cycles through `formatSortLeads` instead of the
      // usual asc/desc flip — each click promotes the next format
      // to the top of the sort.
      if (column == TrackSortColumn.format) {
        _sortFormatMode = (_sortFormatMode + 1) % formatSortLeads.length;
      } else {
        _sortAscending = !_sortAscending;
      }
    } else {
      _sortColumn = column;
      _sortAscending = true;
      if (column == TrackSortColumn.format) {
        _sortFormatMode = 0;
      }
    }
    _invalidateLock();
    _markFilterDirty();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Intelligence-mutating actions (lazy promotion + bucket consolidation).
  // Each user-driven write goes:
  //   resolve bucket → consolidate intel → mutate canonical → mirror
  //   in-memory across every Track sharing that intel uid.
  // The consolidation step (slice 3) ensures the song-identity bucket
  // shares a single `tracks` row, so favorite / play count / cumulative
  // listening / last-played stay coherent across format variants
  // regardless of which row the user interacted with.
  // ---------------------------------------------------------------------------

  /// Every in-memory Track sharing [t]'s song identity. Uses the
  /// same two-tier rule as the matcher: manual override → 4-field
  /// match → fingerprint match. Linear over `_tracks`; called only
  /// on mutation, so the cost is negligible.
  List<Track> variantsFor(Track t) {
    final out = <Track>[];
    for (final candidate in _tracks) {
      if (sameSongIdentity(t, candidate)) out.add(candidate);
    }
    return out.isEmpty ? [t] : out;
  }

  /// Run [mutate] against the canonical intel uid for [origin]'s
  /// bucket, then mirror canonical state back to every in-memory
  /// Track that points at it. Returns the canonical uid (`null` if
  /// promotion failed — caller should treat as a no-op).
  ///
  /// `mutate` receives the canonical uid and is expected to issue
  /// the `repo.updateIntelligence` write itself. After it returns,
  /// `fetchIntelligence` reads the now-current values and the
  /// helper propagates them to all in-memory tracks sharing the
  /// uid — including bucket variants AND any literal fingerprint
  /// duplicates (which may not be in the same song-identity bucket
  /// but already share intel via the older fingerprint-sharing path).
  Future<String?> _writeBucketIntelligence(
    Track origin,
    Future<void> Function(String canonicalUid) mutate,
  ) async {
    final bucket = variantsFor(origin);
    final canonical = await repo.consolidateBucketIntelligence(
      bucket.map((t) => t.path).toList(),
    );
    if (canonical == null) return null;
    // Mirror the canonical uid onto every bucket variant before
    // running the mutation — keeps the in-memory linkage current
    // even if the mutate call throws.
    for (final v in bucket) {
      v.intelUid = canonical;
    }
    await mutate(canonical);
    final intel = await repo.fetchIntelligence(canonical);
    if (intel != null) {
      for (final t in _tracks) {
        if (t.intelUid != canonical) continue;
        t.favorite = intel.favorite;
        t.playCount = intel.playCount;
        t.cumulativeListened = Duration(milliseconds: intel.cumulativeMs);
        t.lastPlayedAt = intel.lastPlayedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(intel.lastPlayedAt!)
            : null;
        t.reviewedAt = intel.reviewedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(intel.reviewedAt!)
            : null;
        t.favoriteToggledAt = intel.favoriteToggledAt != null
            ? DateTime.fromMillisecondsSinceEpoch(intel.favoriteToggledAt!)
            : null;
      }
    }
    return canonical;
  }

  /// Manually pair [origin] with [target] so they bucket together
  /// regardless of whether the strict 4-field matcher would have
  /// matched them. Both rows receive the same `identityOverride`
  /// value (a fresh UUID), and their intelligence is consolidated
  /// onto a single canonical `tracks` row.
  ///
  /// If [origin] is already part of a bucket (manual or computed),
  /// the override propagates to every variant in that bucket so the
  /// pairing extends transitively — pairing a fifth file to a song
  /// that already has four variants keeps them all together.
  Future<void> linkTracks(Track origin, Track target) async {
    if (origin.uid == target.uid) return;
    final originBucket = variantsFor(origin);
    final targetBucket = variantsFor(target);
    final unique = <String, Track>{
      for (final t in originBucket) t.uid: t,
      for (final t in targetBucket) t.uid: t,
    };
    final allTracks = unique.values.toList();
    if (allTracks.length < 2) return;

    // Pick the override: if any of the involved tracks already had
    // a manual override, reuse it (extending the existing manual
    // bucket); otherwise mint a fresh UUID.
    String? override;
    for (final t in allTracks) {
      final ov = t.identityOverride;
      if (ov != null && ov.isNotEmpty) {
        override = ov;
        break;
      }
    }
    override ??= _uuid.v4();

    // Apply in-memory immediately so the table redraws.
    for (final t in allTracks) {
      t.identityOverride = override;
    }
    _markLibraryDirty();
    notifyListeners();

    // Persist + consolidate intel so the pair shares one canonical
    // `tracks` row (slice 3 mechanism).
    await repo.setIdentityOverride(
      allTracks.map((t) => t.path).toList(),
      value: override,
    );
    await _writeBucketIntelligence(origin, (_) async {});
    _markLibraryDirty();
    notifyListeners();
  }

  /// Tear down [origin]'s song-identity bucket. Every variant becomes
  /// its own singleton (its `identityOverride` is forced to its own
  /// uid, ensuring no future auto-match re-pairs them), and every
  /// piece of *behavioral* intelligence — play count, favorite,
  /// cumulative listened, last played, review state — resets to its
  /// default on all variants.
  ///
  /// Per project memory: unlink means "these are NOT the same song
  /// anymore." File-analysis fields (BPM, key, duration, fingerprint)
  /// live on the per-file row and stay untouched.
  ///
  /// No-ops when the bucket has only one variant — nothing to unlink.
  Future<void> unlinkBucket(Track origin) async {
    final bucket = variantsFor(origin);
    if (bucket.length < 2) return;

    await repo.unlinkBucketIntelligence(
      bucket.map((t) => t.path).toList(),
    );
    // Mirror the DB tear-down into the in-memory tracks so the
    // table redraws immediately without a full reload.
    for (final t in bucket) {
      t.identityOverride = t.uid;
      t.intelUid = null;
      t.favorite = false;
      t.playCount = 0;
      t.cumulativeListened = Duration.zero;
      t.lastPlayedAt = null;
    }
    _markLibraryDirty();
    notifyListeners();
  }

  Future<void> toggleFavorite(String uid) async {
    final t = _trackByUid(uid);
    if (t == null) return;
    final bucket = variantsFor(t);
    // Flip against the value shown on the row the user actually
    // clicked — not the bucket aggregate. With grouping ON every
    // variant in the bucket has the same favorite (consolidation
    // mirrors them) so the two are equivalent. With grouping OFF
    // they can diverge if the user pre-favorited one variant
    // before slice 3 shipped: clicking the as-yet-unfavorited
    // sibling expects to turn the star ON, not OFF, and toggling
    // against the aggregate would silently un-favorite.
    final next = !t.favorite;

    // Operational journal accumulator — only direction false→true
    // counts as "favorited" for the save period narrative.
    // Toggling back off doesn't decrement.
    if (next && !t.favorite) {
      _favoritesAddedSinceSnapshot += 1;
    }

    // Optimistic in-memory flip on every bucket variant so the UI
    // updates instantly. _writeBucketIntelligence below will
    // overwrite these with canonical state once persisted. The
    // favorite_toggled_at stamp powers iPhone-sync LWW
    // reconciliation — repo.updateIntelligence auto-stamps it
    // when `favorite` is non-null.
    final now = DateTime.now();
    for (final v in bucket) {
      v.favorite = next;
      v.favoriteToggledAt = now;
    }
    _markLibraryDirty();
    notifyListeners();

    await _writeBucketIntelligence(t, (canonical) async {
      await repo.updateIntelligence(intelUid: canonical, favorite: next);
    });
    _markLibraryDirty();
    notifyListeners();
  }

  Future<void> toggleReviewed(String uid) async {
    final t = _trackByUid(uid);
    if (t == null) return;
    final bucket = variantsFor(t);
    // Same reasoning as toggleFavorite: flip against the clicked
    // row's reviewed state, not the bucket aggregate. Pre-slice-3
    // per-variant divergence would otherwise cause the click to
    // un-review when the user intended to review.
    //
    // PR1 change: reviewed state is now durable via reviewed_at —
    // toggling on stamps the timestamp, toggling off clears it.
    // cumulative_ms is NO LONGER manipulated here (the old code
    // wrote 0 / 3000 to drive the derived getter); we leave the
    // analytics counter alone.
    final reviewed = t.reviewed;
    final nextReviewedAt = reviewed ? null : DateTime.now();

    // Optimistic in-memory update across the bucket.
    for (final v in bucket) {
      v.reviewedAt = nextReviewedAt;
    }
    if (!reviewed) _pushRecentReviewed(uid);
    _markLibraryDirty();
    notifyListeners();

    await _writeBucketIntelligence(t, (canonical) async {
      if (reviewed) {
        await repo.updateIntelligence(
          intelUid: canonical,
          clearReviewedAt: true,
        );
      } else {
        await repo.updateIntelligence(
          intelUid: canonical,
          reviewedAt: nextReviewedAt!.millisecondsSinceEpoch,
        );
      }
    });
    _markLibraryDirty();
    notifyListeners();
  }

  void cyclePlaybackMode() {
    final values = PlaybackMode.values;
    _playbackMode = values[(_playbackMode.index + 1) % values.length];
    notifyListeners();
  }

  void selectTrack(String? uid) {
    if (_selectedTrackUid == uid) return;
    _selectedTrackUid = uid;
    if (uid != null) {
      // Pre-warm metadata for the row the cursor is on, even if it's
      // outside the viewport (keyboard arrow navigation past the
      // last rendered row, etc.).
      final t = _tracksByUid[uid];
      if (t != null) enrichOnDemand(t.path);
    }
    notifyListeners();
  }

  void selectNextVisible() {
    final list = visibleTracks;
    if (list.isEmpty) return;
    final cursor = _selectedTrackUid ?? _currentTrackUid;
    if (cursor == null) {
      _selectedTrackUid = list.first.uid;
    } else {
      final idx = list.indexWhere((t) => t.uid == cursor);
      if (idx < 0) {
        _selectedTrackUid = list.first.uid;
      } else if (idx < list.length - 1) {
        _selectedTrackUid = list[idx + 1].uid;
      } else {
        _selectedTrackUid = list.last.uid;
      }
    }
    notifyListeners();
  }

  void selectPreviousVisible() {
    final list = visibleTracks;
    if (list.isEmpty) return;
    final cursor = _selectedTrackUid ?? _currentTrackUid;
    if (cursor == null) {
      _selectedTrackUid = list.first.uid;
    } else {
      final idx = list.indexWhere((t) => t.uid == cursor);
      if (idx <= 0) {
        _selectedTrackUid = list.first.uid;
      } else {
        _selectedTrackUid = list[idx - 1].uid;
      }
    }
    notifyListeners();
  }

  Future<void> playSelected() async {
    final uid = _selectedTrackUid;
    if (uid == null) return;
    await play(uid, reveal: true);
  }

  void revealCurrent() {
    if (_currentTrackUid == null) return;
    if (_selectedTrackUid != _currentTrackUid) {
      _selectedTrackUid = _currentTrackUid;
      notifyListeners();
    }
    _revealTick.value = _revealTick.value + 1;
  }

  /// Reveal a specific track instance in Finder. Used by row-level
  /// actions (right-click → Show in Finder).
  ///
  /// **Currently-playing instance wins**: if a track is playing and
  /// shares this row's intelligence (same `intelUid`), reveal the
  /// playing file instead — duplicate rows of the playing track all
  /// reveal the file on the engine. Otherwise the row's own path is
  /// the preferred target, with a fallback to other available
  /// siblings if that file is missing.
  /// Reveal a specific variant in Finder without the
  /// currently-playing override or the sibling fallback. Used by
  /// the multi-variant right-click submenu: when the user explicitly
  /// picks "Show MP3 in Finder" or "Show AIFF in Finder", honor
  /// exactly that pick — don't silently substitute the playing file
  /// or another sibling. If the picked variant is missing on disk,
  /// no-op (debug-printed).
  Future<void> revealVariantInFinder(Track t) async {
    if (!Platform.isMacOS) return;
    if (!t.isAvailable) {
      debugPrint('[finder] requested variant is unavailable: ${t.path}');
      return;
    }
    await _runFinderReveal(t.path);
  }

  Future<void> showTrackInstanceInFinder(Track t) async {
    if (_currentTrackUid != null &&
        _currentTrackPath != null &&
        t.intelUid != null &&
        currentTrack?.intelUid == t.intelUid) {
      await showCurrentTrackInFinder();
      return;
    }
    await _revealInFinderWithFallback(
      preferredPath: t.path,
      intelUid: t.intelUid,
    );
  }

  /// Reveal the file the engine is currently playing in Finder. Used
  /// by the utility-rail button. No-op if nothing is playing.
  Future<void> showCurrentTrackInFinder() async {
    final path = _currentTrackPath;
    if (path == null) return;
    await _revealInFinderWithFallback(
      preferredPath: path,
      intelUid: currentTrack?.intelUid,
    );
  }

  /// Resolver: open [preferredPath] if present and available; else
  /// fall back to the most-recently-seen available sibling (any
  /// `Track` whose `intelUid` matches and whose file is on disk).
  /// Never randomly picks — `last_seen_at` orders deterministically;
  /// if there's no usable instance, no-op + debugPrint.
  Future<void> _revealInFinderWithFallback({
    required String preferredPath,
    required String? intelUid,
  }) async {
    if (!Platform.isMacOS) return;
    final preferred = _trackByPath(preferredPath);
    if (preferred != null && preferred.isAvailable) {
      await _runFinderReveal(preferred.path);
      return;
    }
    if (intelUid != null) {
      Track? best;
      for (final t in _tracks) {
        if (t.intelUid != intelUid) continue;
        if (!t.isAvailable) continue;
        if (t.path == preferredPath) continue;
        if (best == null || t.lastSeenAt > best.lastSeenAt) best = t;
      }
      if (best != null) {
        await _runFinderReveal(best.path);
        return;
      }
    }
    debugPrint(
      '[finder] no available instance to reveal '
      '(preferred=$preferredPath, intelUid=$intelUid)',
    );
  }

  Future<void> _runFinderReveal(String path) async {
    try {
      await Process.run('open', ['-R', path]);
    } catch (_) {
      // best-effort
    }
  }

  Future<void> goBack() async {
    if (_recentReviewedUids.isNotEmpty &&
        _recentReviewedUids[0] != _currentTrackUid) {
      await play(_recentReviewedUids[0], reveal: true);
    } else {
      await previous();
    }
  }

  /// Try to play [origin]'s bucket, falling back through sibling
  /// variants when the chosen file is missing or the engine rejects
  /// it. Returns the Track whose file was actually loaded into the
  /// engine, or `null` if every variant failed.
  ///
  /// Order: requested track first (the user's explicit preference,
  /// e.g. clicking the AIFF row plays the AIFF), then the rest of
  /// the bucket in playback-preference order. Each candidate that
  /// fails has its in-memory `isAvailable` flipped to false so the
  /// table redraws without it on the next pipeline run; persistence
  /// will catch up on the next rescan.
  Future<Track?> _tryPlayBucket(Track origin) async {
    final bucket = variantsFor(origin);
    final ordered = orderBucketByPlaybackPreference(bucket);
    // Move origin to the front if it's in the bucket (user explicit
    // preference wins over the playback-preference default).
    final candidates = <Track>[origin];
    for (final v in ordered) {
      if (v.uid != origin.uid) candidates.add(v);
    }
    for (final candidate in candidates) {
      if (!candidate.isAvailable) {
        debugPrint(
          '[play] skipping unavailable variant: ${candidate.path}',
        );
        continue;
      }
      // Defensive pre-flight: if the file was marked available but
      // is actually gone from disk (rescan hasn't fired yet), avoid
      // the slower engine.setTrack failure and flip the in-memory
      // flag immediately so the row drops from the table.
      if (!File(candidate.path).existsSync()) {
        debugPrint(
          '[play] file missing on disk, marking unavailable: '
          '${candidate.path}',
        );
        candidate.isAvailable = false;
        continue;
      }
      try {
        await engine.setTrack(candidate.path);
        return candidate;
      } catch (e) {
        debugPrint(
          '[play] engine.setTrack failed for ${candidate.path}: $e — '
          'trying next variant',
        );
        // Engine errors can be transient — a Dropbox CloudStorage
        // file being materialised, a codec stall, a momentary
        // lock by another process, the engine still tearing down
        // a prior track. Previously we flipped `isAvailable=false`
        // here, which broke retries: after one transient failure
        // the row would silently fail on every subsequent click
        // until a rescan re-synced in-memory from DB. The terminal
        // case ("file actually gone") is already caught by the
        // `File.existsSync()` pre-flight above, so engine errors
        // get treated as "try the next variant this attempt" and
        // leave the in-memory flag alone.
      }
    }
    return null;
  }

  Future<void> play(String uid, {bool reveal = false, String? path}) async {
    // Q1 contract: sync is a playback-exclusive maintenance
    // window. play() refuses while a non-terminal sync session
    // is in flight — the engine can't safely traverse tracks
    // whose inventory is being mutated. The UI button paths
    // should already disable themselves via
    // `playbackBlockedListenable`, but we guard here too in
    // case a keyboard shortcut or remote command bypasses the
    // UI gate.
    if (isPlaybackBlockedBySync) {
      debugPrint('[play] refused: sync session in flight');
      return;
    }
    // Per-step millisecond timing of the play path. Each `tick` call
    // logs the cumulative + delta against the last tick. Goal: the
    // segment from `entry` → `engine.setTrack returned` should be
    // <50 ms on local files; anything longer surfaces a real
    // bottleneck (sort, DB writes, listener storms, etc.).
    final sw = Stopwatch()..start();
    var lastMs = 0;
    void tick(String label) {
      final now = sw.elapsedMilliseconds;
      debugPrint('[play t+${now}ms +${now - lastMs}ms] $label');
      lastMs = now;
    }

    tick('entry uid=$uid path=${path ?? "<none>"}');
    // Path-preferred lookup. `uid` is `sha256(basename | filesize |
    // durationMs | mtimeMs)` truncated to 16 hex chars — same
    // physical file in two watched folders (Z CRATE + Afro:Tech:Deep)
    // collides, and `_tracksByUid` only holds the last-seen Track
    // for that key. Path is the indexed_files PK; always unique.
    // When the table's click handler passes its row's path, we
    // resolve unambiguously even under collision.
    //
    // Falls back to uid lookup for callers that only know the uid
    // (next/previous/keyboard navigation, restore from snapshot).
    Track? track;
    if (path != null) {
      track = _trackByPath(path);
    }
    track ??= _trackByUid(uid);
    tick('lookup → ${track == null ? "null" : "ok"}');
    if (track == null) {
      debugPrint('[play] unknown uid: $uid (path=$path)');
      return;
    }
    // Re-resolve uid from the actually-found track. When the lookup
    // succeeded via path, `uid` may have been a collision twin's
    // value; from here on we use the canonical uid of the row we
    // intend to play so subsequent state ops (`_currentTrackUid`,
    // etc.) stay consistent.
    uid = track.uid;
    // `isNewTrack` keys on PATH, not uid, so two collision twins
    // (same uid, different paths) correctly read as distinct
    // tracks. Without this, switching from Z CRATE → Afro:Tech:Deep
    // on the same byte-identical AIFF would silently no-op because
    // the uid hasn't changed.
    final isNewTrack = _currentTrackPath != track.path;
    if (isNewTrack) {
      await _flushCurrentTrack();
      tick('_flushCurrentTrack');
      final visible = visibleTracks;
      tick('visibleTracks (${visible.length} rows, sort cost included)');
      final displayedIdx = visible.indexWhere((t) => t.uid == uid);
      tick('indexWhere');
      _currentTrackUid = uid;
      _selectedTrackUid = uid;
      _lockedCurrentIndex = displayedIdx >= 0 ? displayedIdx : null;
      _positionNotifier.value = Duration.zero;
      _lastTickPosition = Duration.zero;
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
      // Clear the transient "just reviewed" marker so the previous
      // track's highlight disappears the moment a new track starts
      // playing. Set again later in [_onPosition] when this new
      // track's session crosses the threshold.
      _justReviewedUid = null;
      _isLoadingTrack = true;
      _markLibraryDirty();
      notifyListeners();
      tick('notifyListeners (loading state)');
      // Resolve the actual file to play. The bucket-level fallback
      // tries the requested track first; if its file is missing or
      // the engine refuses it (codec error, corrupt header, etc),
      // walks siblings in playback-preference order until one
      // works. This is how the user expects a song to keep playing
      // even after one of its variants gets deleted in Finder.
      final played = await _tryPlayBucket(track);
      if (played == null) {
        debugPrint(
          '[play] all variants in bucket failed for ${track.path}',
        );
        _currentTrackUid = null;
        _currentTrackPath = null;
        _isLoadingTrack = false;
        notifyListeners();
        return;
      }
      tick('engine.setTrack returned (path=${played.path})');
      _isLoadingTrack = false;
      _currentTrackPath = played.path;
      enrichOnDemand(played.path);
      tick('enrichOnDemand queued');

      final now = DateTime.now();
      await _writeBucketIntelligence(played, (canonical) async {
        await repo.updateIntelligence(
          intelUid: canonical,
          lastPlayedAt: now.millisecondsSinceEpoch,
        );
      });
      tick('updateIntelligence (lastPlayedAt, bucket)');
      _pushNowPlaying();
      tick('_pushNowPlaying');
    }
    await engine.play();
    tick('engine.play() — first audio frame requested');
    if (reveal) {
      _revealTick.value = _revealTick.value + 1;
    }
  }

  Future<void> _flushCurrentTrack() async {
    final t = currentTrack;
    if (t == null) return;
    if (t.intelUid == null) return;
    // The in-memory cumulativeListened / playCount on `t` is the
    // authoritative session state (this is the file the engine is
    // playing). Mirror it onto canonical intel + every bucket
    // sibling so favoriting / reviewing on a different variant
    // after this flush stays coherent.
    await _writeBucketIntelligence(t, (canonical) async {
      await repo.updateIntelligence(
        intelUid: canonical,
        cumulativeMs: t.cumulativeListened.inMilliseconds,
        playCount: t.playCount,
      );
    });
  }

  Future<void> togglePlayPause() async {
    if (_currentTrackUid == null) {
      final list = visibleTracks;
      if (list.isNotEmpty) await play(list.first.uid);
      return;
    }
    if (engine.isPlaying) {
      await engine.pause();
    } else {
      await engine.play();
    }
  }

  Future<void> next() async {
    final list = visibleTracks;
    if (list.isEmpty || _currentTrackUid == null) return;

    if (_playbackMode == PlaybackMode.shuffleUnreviewed) {
      final pool = list
          .where((t) => !t.reviewed && t.path != _currentTrackPath)
          .toList();
      if (pool.isEmpty) return;
      final pick = pool[_rng.nextInt(pool.length)];
      await play(pick.uid, reveal: true, path: pick.path);
      return;
    }

    if (_playbackMode == PlaybackMode.shuffle && list.length > 1) {
      Track pick;
      do {
        pick = list[_rng.nextInt(list.length)];
      } while (pick.path == _currentTrackPath);
      await play(pick.uid, reveal: true, path: pick.path);
      return;
    }

    // Locate "current" by path, not uid — uid can collide across
    // sources (same physical file at two paths). Path is the row's
    // primary key in indexed_files and is unambiguous.
    final idx = list.indexWhere((t) => t.path == _currentTrackPath);
    if (idx >= 0 && idx < list.length - 1) {
      final pick = list[idx + 1];
      await play(pick.uid, reveal: true, path: pick.path);
    }
  }

  Future<void> previous() async {
    final list = visibleTracks;
    if (list.isEmpty || _currentTrackUid == null) return;
    final idx = list.indexWhere((t) => t.path == _currentTrackPath);
    if (idx > 0) {
      final pick = list[idx - 1];
      await play(pick.uid, reveal: true, path: pick.path);
    }
  }

  Future<void> skip(Duration delta) async {
    final track = currentTrack;
    if (track == null) return;
    var newPos = _positionNotifier.value + delta;
    if (newPos < Duration.zero) newPos = Duration.zero;
    if (track.duration > Duration.zero && newPos > track.duration) {
      newPos = track.duration;
    }
    _positionNotifier.value = newPos;
    _lastTickPosition = newPos;
    await engine.seek(newPos);
  }

  Future<void> seekToFraction(double fraction) async {
    final track = currentTrack;
    if (track == null || track.duration == Duration.zero) return;
    final ms = (track.duration.inMilliseconds * fraction.clamp(0.0, 1.0))
        .round();
    final newPos = Duration(milliseconds: ms);
    _positionNotifier.value = newPos;
    _lastTickPosition = newPos;
    await engine.seek(newPos);
  }

  void _onPosition(Duration pos) {
    final track = currentTrack;
    if (track != null && _isPlaying) {
      final delta = pos - _lastTickPosition;
      if (delta > Duration.zero && delta < const Duration(seconds: 2)) {
        // Real forward playback time — `delta` is bounded above by
        // 2s to reject seek-induced jumps (a real audio tick is
        // <250ms apart). cumulative_ms is the analytics counter;
        // session-level threshold-crossing is what drives review
        // state.
        track.cumulativeListened = track.cumulativeListened + delta;
        _sessionListened = _sessionListened + delta;

        // PR1 canonical event: when this session's real-playback
        // counter crosses `_playThresholdSeconds`, ONE trigger
        // atomically fires three side effects + the optional
        // first-time review stamp.
        //
        //   play_count       += 1     (this session counted)
        //   last_played_at    = now   (most-recent listen)
        //   reviewed_at      ??= now  (first review stamp, sticky)
        //
        // Replays of an already-reviewed track keep their original
        // `reviewed_at` intact (preserves WHEN review happened);
        // play_count and last_played_at still update each session.
        //
        // The pre-v15 derived-review logic (`cumulative_ms >= 3` as
        // the review boundary) is gone — review IS the threshold
        // crossing now, with no second condition.
        final shouldCountSession =
            !_sessionPlayCounted &&
            _sessionListened >= Duration(seconds: _playThresholdSeconds);

        if (shouldCountSession) {
          _sessionPlayCounted = true;
          track.playCount += 1;
          final now = DateTime.now();
          track.lastPlayedAt = now;
          // Sticky first-review stamp. If reviewedAt is already
          // set (replay of a reviewed track), leave it alone —
          // the timestamp records WHEN review happened, not the
          // latest listen.
          track.reviewedAt ??= now;
          // Operational journal accumulator — increment the
          // per-save-period "tracks played" counter. Flushed
          // to the events table at the next autosave tick.
          _playsSinceSnapshot += 1;
          // Mark this track for transient row-highlight in the
          // table. The row's AnimatedContainer fades the colour
          // in (= the user-visible "flash"); the marker stays
          // until the next `play()` call clears it, so the
          // highlight reads as "you played this track through
          // — until you start the next one."
          _justReviewedUid = track.uid;
          _pushRecentReviewed(track.uid);
          // Bump `_dataVersion` only — NOT `_libraryVersion` and
          // NOT the visible cache. The track object was mutated
          // in place (playCount, reviewedAt, lastPlayedAt);
          // widget rebuilds via notifyListeners() read those
          // updated fields directly. Crucially, the table's
          // visible-cache stays valid → no re-sort fires while a
          // song is playing → neighbour rows DO NOT shift around
          // the currently-playing row when the threshold crosses.
          //
          // Was previously `_markLibraryDirty()` here, which
          // invalidated the visible cache. With sticky-current
          // pinning the playing row, the re-sort would remove it
          // from its natural new position and re-insert at the
          // locked index — shifting every row in between by 1.
          // User noticed and complained: "I JUST DONT WANT THINGS
          // TO MOVE WHILE THE SONG IS PLAYING."
          //
          // Other caches that legitimately depend on data freshness
          // (multiVariantBucketCount, source counts) still refresh
          // because they key off `_dataVersion`.
          _dataVersion++;
          notifyListeners();
          // Persist through the bucket helper so the threshold
          // mutation propagates to every sibling variant in
          // memory + the canonical intel row, in one atomic
          // update. Promotion already happened at play() start,
          // so this call is just a write + mirror.
          final cumulativeMs = track.cumulativeListened.inMilliseconds;
          final playCount = track.playCount;
          final lastPlayedAtMs = now.millisecondsSinceEpoch;
          final reviewedAtMs = track.reviewedAt!.millisecondsSinceEpoch;
          unawaited(_writeBucketIntelligence(track, (canonical) async {
            await repo.updateIntelligence(
              intelUid: canonical,
              cumulativeMs: cumulativeMs,
              playCount: playCount,
              lastPlayedAt: lastPlayedAtMs,
              reviewedAt: reviewedAtMs,
            );
          }));
        }
      }
    }
    _lastTickPosition = pos;
    _positionNotifier.value = pos;
    final now = DateTime.now();
    if (now.difference(_lastNowPlayingPushAt).inMilliseconds >= 1000) {
      _lastNowPlayingPushAt = now;
      _pushNowPlaying();
    }
  }

  void _onPlaying(bool playing) {
    if (_isPlaying == playing) return;
    _isPlaying = playing;
    if (playing) {
      _flushTimer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => _flushCurrentTrack(),
      );
      // Playback-priority law: while audio is playing, the
      // backfill worker yields the disk + IO thread pool so
      // scroll, skip, and queue interactions stay smooth. The
      // worker keeps its session state (progress count, failed-
      // path memo) — it just stops scheduling new hashes until
      // we resume() below.
      _backfillWorker.pause();
    } else {
      _flushTimer?.cancel();
      _flushTimer = null;
      _flushCurrentTrack();
      // Playback stopped → background work catches up. Idempotent.
      _backfillWorker.resume();
    }
    _pushNowPlaying();
    notifyListeners();
  }

  void _onDuration(Duration? d) {
    if (d == null || d == Duration.zero) return;
    final track = currentTrack;
    if (track == null) return;
    if (track.duration != d) {
      track.duration = d;
      _markLibraryDirty();
      notifyListeners();
      // Duration is part of the lightweight index, not intelligence —
      // metadata extractor will eventually persist it via
      // updateMetadataBatch. We don't write to `tracks` from here.
    }
  }

  void _onProcessing(ProcessingState state) {
    if (state == ProcessingState.completed) {
      _sessionListened = Duration.zero;
      _sessionPlayCounted = false;
      next();
    }
  }

  // ---------------------------------------------------------------------------
  // Intelligence export / import (cross-machine portability).
  // ---------------------------------------------------------------------------

  /// Snapshot intelligence rows to a JSON file.
  ///
  /// If [toPath] is `null`, writes to the default location:
  /// `~/Documents/Music Tracker/intelligence-{yyyyMMdd-HHmm}.json`.
  /// Returns the written file (caller can show the path in a toast).
  Future<File> exportIntelligence({String? toPath}) async {
    final records = await repo.exportIntelligenceRecords();
    final filePath = toPath ??
        '${(await IntelligenceExportFile.defaultExportDirectory()).path}/'
            '${IntelligenceExportFile.defaultFilename()}';
    final file = await IntelligenceExportFile.writeTo(
      filePath: filePath,
      records: records,
    );
    debugPrint(
      '[export] wrote ${records.length} intelligence records to '
      '${file.path}',
    );
    return file;
  }

  /// Read an intelligence file and preview the merge plan WITHOUT
  /// applying it. Used by the import-confirm dialog so the user sees
  /// the breakdown before committing.
  ///
  /// Throws [FormatException] if the file isn't a valid intelligence
  /// export. The returned `records` is what
  /// [applyIntelligenceImport] should be called with on confirm.
  Future<({List<IntelligenceRecord> records, List<String> parseErrors})>
      previewIntelligenceImport(File file) async {
    final errors = <String>[];
    final records = await IntelligenceExportFile.readFrom(file, errors: errors);
    return (records: records, parseErrors: errors);
  }

  /// Apply an already-parsed import. Reloads tracks afterwards so
  /// merged state appears in the UI without restarting the app.
  Future<ImportSummary> applyIntelligenceImport(
    List<IntelligenceRecord> records,
  ) async {
    final summary = await repo.importIntelligenceRecords(records);
    final allTracks = await repo.loadTracks();
    _replaceTracks(allTracks);
    _markLibraryDirty();
    notifyListeners();
    debugPrint(
      '[import] read=${summary.recordsRead} '
      'mergedByUid=${summary.mergedByUid} '
      'mergedByFp=${summary.mergedByFingerprint} '
      'ghost=${summary.insertedAsGhost} '
      'errors=${summary.skippedErrors.length}',
    );
    return summary;
  }

  /// Graceful reset of background work for Flutter hot reload.
  /// Called from `_HomeScreenState.reassemble()` whenever the user
  /// hits `r` in the running `flutter run` session.
  ///
  /// What hot reload breaks if we don't intervene:
  ///   - `compute()` isolates in flight die with "Computation ended
  ///     without result". The scanner, metadata extractor, and
  ///     content-hash backfill all use compute(); a reload landing
  ///     mid-call surfaces as a `[scan] FAILED` log line and a brief
  ///     UI hang while the cascading watcher rescans pile up.
  ///   - Pending watcher-debounce timers reference closures that
  ///     may have changed under them; their next fire could call
  ///     into a stale code path.
  ///   - The backfill worker's scheduler timer survives but its
  ///     class body might have been edited; on the next fire it
  ///     could behave inconsistently.
  ///
  /// Cancelling these gives the post-reload state a clean room
  /// to rebuild from. Background work re-arms naturally:
  ///   - Watchers continue firing (the streams survived); the
  ///     next event re-arms the quiescence debounce.
  ///   - The backfill worker auto-restarts at the next scan-end
  ///     boundary (see `_scanIntoSource`'s `finally` block).
  ///   - Any track the user clicks to play kicks the on-demand
  ///     enrichment hook so foreground interactions stay snappy.
  ///
  /// Safe to call multiple times in quick succession (idempotent).
  void handleHotReload() {
    debugPrint('[reassemble] pausing background work for hot reload');
    // Backfill: cancel cleanly. Restarts on next scan-end.
    _backfillWorker.cancel();
    // Drop pending watcher debounces — better to lose one quiesced
    // rescan than to fire it through a half-reloaded code path.
    for (final t in _watcherDebounce.values) {
      t.cancel();
    }
    _watcherDebounce.clear();
    _watcherFirstEventAt.clear();
    // Clear the enrichment stall ticker. If `_metadataProcessing`
    // is still true (an isolate batch in flight pre-reload), let
    // the processor's own `finally` block tear down on next tick —
    // we just stop the 1Hz UI notify so the post-reload frame
    // doesn't show stale "waiting N seconds" counters.
    _enrichmentStallTicker?.cancel();
    _enrichmentStallTicker = null;
    // Dismiss any reconciliation banner mid-fade so the post-reload
    // UI doesn't surface a half-stale narration.
    _reconciliationSummary = null;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _autosaveTimer?.cancel();
    _flushCurrentTrack();
    // Final shutdown snapshot — fire-and-forget. App is exiting,
    // so we can't await; sqflite's file is fully flushed by
    // `_flushCurrentTrack` already, the copy below is just disk
    // I/O. Worst case: app dies mid-copy and the snapshot is
    // discarded (cleaned up by the next autosave tick on relaunch
    // since `.partial` files don't match the filename format).
    unawaited(_snapshotNow());
    _positionSub?.cancel();
    _playingSub?.cancel();
    _durationSub?.cancel();
    _processingSub?.cancel();
    _positionNotifier.dispose();
    _revealTick.dispose();
    _backfillWorker.cancel();
    unawaited(_stopAllWatchers());
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver);
      _lifecycleObserverRegistered = false;
    }
    super.dispose();
  }
}

String _displayNameFor(String path) {
  final segs = path.split(Platform.pathSeparator);
  for (var i = segs.length - 1; i >= 0; i--) {
    if (segs[i].isNotEmpty) return segs[i];
  }
  return path;
}

/// Per-source operational stats — single struct populated in the
/// `_computeAllSourceCounts` walk and consumed by both the sidebar
/// (`total`) and the status-bar contextual cluster (`ready`,
/// `enriching`, `waitingOnCloud`). Mutable for cheap accumulation
/// during the walk; widgets only read it.
class _SourceStats {
  int total = 0;
  int ready = 0;
  int enriching = 0;
  int waitingOnCloud = 0;

  void bump({
    required bool isReady,
    required bool isEnriching,
    required bool isWaitingOnCloud,
  }) {
    total++;
    if (isReady) ready++;
    if (isEnriching) enriching++;
    if (isWaitingOnCloud) waitingOnCloud++;
  }
}

/// Thin shim around `WidgetsBindingObserver` so the controller can
/// listen for app lifecycle changes without itself mixing in
/// WidgetsBindingObserver (which isn't declared as a Dart mixin in
/// the current Flutter SDK). The controller registers an instance of
/// this with `WidgetsBinding.instance.addObserver(...)` and forwards
/// the lifecycle-state callback to a closure.
class _LifecycleObserver extends WidgetsBindingObserver {
  final void Function(AppLifecycleState) onChange;
  _LifecycleObserver(this.onChange);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChange(state);
  }
}

/// One sidebar Devices panel row: a [MobileDevice] paired with
/// its derived [DeviceOperationalState]. Pre-computed by
/// [LibraryController.refreshPairedDevices] so the UI never
/// recomputes state on rebuild — purity + cheap rendering.
class DeviceWithState {
  final MobileDevice device;
  final DeviceOperationalState state;
  const DeviceWithState({required this.device, required this.state});
}

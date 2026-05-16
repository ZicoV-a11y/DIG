# Project Context Pack — Music Tracker

> **High-density architectural restoration for future Claude sessions.**
> Optimised for restoration speed, not completeness. A session that
> reads this + the three companion architecture docs should recover
> ~85–90% of working context without trawling commit history.
>
> Last revised: **2026-05-15.**
> If this date is more than a few weeks stale, treat the "current
> status" and "active investigations" sections as suspect — verify
> against `git log --oneline -30` and the latest memory files.

---

## 1. Project identity

**What it is.** A Flutter macOS desktop app — a *DJ digging
workstation*. Table-centric, keyboard-first, non-destructive,
momentum-preserving. The user spends hours/day in it organising,
auditing, and playing a library of ~12,000+ tracks (often
cloud-backed via Dropbox).

**Operational philosophy.** The app is the user's persistent
operational console for their music universe. Trust matters more
than features. Architectural correctness matters more than
shipping velocity. Visible filesystem state matters more than
opaque polish.

**Why it exists.** Existing DJ libraries (Rekordbox, Serato,
iTunes) are siloed databases that:
- Don't let the user reason about their library outside the app.
- Hide lineage decisions behind opaque sync engines.
- Conflate "files on disk" with "songs in the library."
- Make moves / dedup / multi-device merges either impossible or
  destructive.

Music Tracker rejects all of that. The ontology is the product;
the UI surfaces it; the filesystem mirrors it.

**What makes it architecturally different.**
- Three-layer identity: Track Identity ≠ Media Representation ≠
  File Instance. Codec variants coexist. Same bytes can coexist
  as intentional duplicates.
- Operational state lives in named, readable `.library` files
  the user can navigate in Finder.
- Device identity is filesystem-level (`machine_id.txt`), not
  DB-resident.
- Composition is *additive* — never pick-newest, never
  destructive overwrite. (Resolver is design-only today; the
  constraint is enforced in the docs ahead of implementation.)

---

## 2. Core ontology — vocabulary index

| Term | Definition | Where in code |
|---|---|---|
| **Library** | The user's entire music universe. Named `{USER}_LIBRARY` (e.g. `NEOMAC_LIBRARY`). NOT a genre/crate/view. | conceptual |
| **Global Library Graph** | Composed reality across all Device Contributions. Deferred — single-device runtime collapses onto this device's contribution today. | deferred |
| **Device Contribution** | One device's perspective on the Library. Embodied as `Systems/{MACHINE}.library`. | filesystem |
| **Operational State** | Any queryable `.library` snapshot — live, historical, or foreign. | filesystem |
| **Operational Truth** | The single Operational State the running app is currently bound to. | sqflite |
| **Historical Lineage** | The chronological chain of Save States in `Saves/`. | filesystem |
| **Save State** | One Save in lineage. Named `{LIB}__{MACHINE}__{DATE}__{TIME}.library`. | filesystem |
| **LibraryRoot** | `~/Documents/Music Tracker/`. Folder holding all Library state. | `LibraryRoot` class |
| **`machine_id.txt`** | Plain-text device identity. Read at boot BEFORE any DB open. | filesystem |
| **Track Identity** | The musical work. One row per Track Identity in the table. | `sameSongIdentity` |
| **Media Representation** | A codec/format encoding (MP3/AIFF/WAV). Operationally meaningful — DJs deliberately keep multiple. | `fileFormatLabel` |
| **File Instance** | A specific `indexed_files` row. Unique by path. | `indexed_files` table |
| **`identity_override`** | UUID stamped on a row to control Track Identity grouping. Manual link / Unlink / Copy propagation. | `indexed_files` column |
| **`fingerprint`** | `(basename + filesize + duration_ms)` hash. File-level equivalence. | `track_uid.dart` |
| **`content_hash`** | sha256 of first/last 256 KB. True byte-level identity. | `content_hash.dart` |
| **TempGroup / SmartView** | (deferred) operational projection over tracks, not a filesystem container. INTERNAL NAMING ONLY — user-facing label is free. | deferred |

### Filesystem layout

```
~/Documents/Music Tracker/         ← LibraryRoot
├── machine_id.txt                 ← filesystem-level device identity (L1)
├── Systems/
│   └── {MACHINE}.library          ← live operational state
├── Current/
│   └── CURRENT.library            ← compatibility mirror (transitional)
├── Saves/
│   └── {LIB}__{MACHINE}__{DATE}__{TIME}.library
│                                  ← Historical Lineage
├── Shared Libraries/              ← scaffolded; foreign Device Contributions
├── Cache/                         ← derived artifacts, safe to delete
└── Logs/                          ← debug / audit
```

### Three-layer track model

```
Track Identity                      ← the musical work
    ├── Media Representation: MP3   ← codec
    │       ├── File Instance: /DL Folder/song.mp3
    │       └── File Instance: /Z CRATE/song.mp3
    ├── Media Representation: AIFF
    │       └── File Instance: /DL Folder/song.aiff
    └── Media Representation: WAV
            └── File Instance: /external/song.wav
```

---

## 3. Architectural laws — the load-bearing 12

Full text in [`architectural_laws.md`](architectural_laws.md). Compression here for restoration.

1. **L1.** Device identity is filesystem-level, not DB-resident. `machine_id.txt` must be readable BEFORE any DB open.
2. **L2.** Operational continuity outranks legacy location continuity. `Systems/{MACHINE}.library` is live; `Current/CURRENT.library` is mirror.
3. **L3.** Filesystem layout IS the architecture. Anything load-bearing surfaces as a visible folder/file.
4. **L4.** Devices contribute INTO the Library, never AS the Library.
5. **L5.** The resolver is additive, never pick-newest. No global authority hierarchy across devices.
6. **L6.** `Saves/` is lineage, not authority. Loading switches truth; it does not "recover" or "replay."
7. **L7.** Track Identity, Media Representation, and File Instance are independent layers. Never collapse any two.
8. **L8.** `identity_override` mutations propagate across ALL 4-field-matched siblings. Heal pass exists to repair pre-fix asymmetric state.
9. **L9.** Auto-supersession requires ALL FOUR: `missing` + uniqueness + temporal-after + small-overlap. `content_hash` alone is NOT sufficient.
10. **L10.** Operational state UI never sounds like backup software. Never: backup, restore, snapshot, revert, rollback. Always: load, switch, operational state, lineage.
11. **L11.** Every workflow action is a controller method. UI / keyboard / MIDI / Stream Deck / automation all reach the same surface.
12. **L12.** Two persistence worlds coexist intentionally — `.library` (full DB snapshot) and `intelligence.json` (legacy export). Do not auto-merge until Shared Libraries exchange settles.

### Forbidden collapses (§6.5 of system_ontology.md)

The negative-space companion to the ontology. Many recent bugs were
*ontology-collapse* bugs, not implementation bugs:

| Forbidden equation | Bug it prevents |
|---|---|
| codec ≠ duplicate | AIFF disappearing from bucket after Copy stamps overrides on MP3 pair only (2026-05-12) |
| save ≠ backup | UI drifts into "restore" language; trust model collapses |
| device ≠ library | Master-device thinking; pick-newest resolver; silent destruction |
| `Systems/{DEVICE}.library` ≠ the library itself | Future multi-device composition becomes impossible |
| operational state ≠ historical lineage | Save States get authoritative semantics; lineage becomes a write target |
| hash match ≠ same operational file | Auto-merge of intentional duplicates (master + working copy) |
| newest ≠ authority | Phone with stale state overwrites desktop's recent changes |
| representation ≠ instance | Variant picker silently picks; Move/Copy targets wrong file |
| filesystem ≠ truth mirror | "If it's not in Finder it's not real" — losing the operational/intelligence distinction |
| Current/ ≠ authority | Current/ silently re-elevated to authoritative |

---

## 4. Operational trust philosophy

Full text in [`ui_philosophy.md`](ui_philosophy.md) §3. The recurring
pattern across every UI decision:

- **Explicitness over magic.**
- **Visible lineage over hidden state.**
- **Readable structure over abstraction.**
- **Recoverability over cleverness.**
- **Operational clarity over seamlessness.**

Concrete commitments:
- **Visible filesystem.** Every load-bearing piece of state lives
  at a Finder-readable path.
- **Readable naming.** Save filenames parse as
  `{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library` in plain text.
- **Explicit device identity.** `machine_id.txt` is plain text,
  inspectable and editable.
- **Lineage visibility.** Every autosave produces a readable
  `Saves/` entry.
- **Snapshot before swap.** Every Load Operational State action
  takes a final autosave of current state first.
- **Manual restart before auto-reload.** Loading a different
  operational state prompts the user to Cmd+Q and relaunch.
- **No hidden magic.** New persistence concepts surface as a
  visible folder or filename pattern.
- **No silent resolver behavior.** When the resolver lands, its
  composition decisions must be visible.
- **No hidden merge destruction.** Pick-newest is forbidden at
  the law level.

---

## 5. Current system status — shipped as of 2026-05-15

### Identity & persistence (the foundation)
- Schema at v13. Migrations: idempotent, additive, backfill-aware.
- `indexed_files` carries `content_hash`, `first_seen_at`,
  `last_seen_at`, `identity_override`, `availability_state`.
- `events` table with rich payload — every lifecycle decision
  records *why* it happened (matched_on, overlap_ms, successor
  references, etc).
- Heal pass on every hydrate: `healOrphanedIdentitySiblings`
  backfills asymmetric `identity_override` state from pre-fix
  Copy operations. Idempotent, safe.

### Save system (trust-cycle verified 2026-05-12)
- `~/Documents/Music Tracker/` LibraryRoot with five subdirs.
- Autosave timer writes Saves/, mirrors to Current/, updates
  Systems/{MACHINE}.library in place.
- Boot transition: `Systems/{MACHINE}.library` is the live DB
  sqflite opens. Current/ is compatibility mirror.
- `machine_id.txt` read at boot before any DB open.
- Load Operational State dialog: navigate Systems/Saves/Shared
  Libraries entries. Manual restart prompt (in-app reload
  deferred until resolver maturity).

### Identity model (Phase 2 supersession landed 2026-05-13)
- `markMovedSupersessions` (same-source) and
  `markCrossSourceMoves` (cross-source) both enforce the L9
  4-condition rule.
- `supersessionTemporalOverlapGrace = Duration(minutes: 10)` —
  single centralised constant.
- Event payloads carry full temporal evidence: `matched_on`,
  `missing_last_seen_at`, `successor_first_seen_at`, `overlap_ms`.
- 4-field identity matching + `identity_override` + fingerprint
  + content_hash — see `sameSongIdentity` for the rule order.

### Lineage narration (causal-integrity surfaces shipped)
- **Activity Log dialog** (utility rail) — chronological event
  feed, shared formatter via `event_log_format.dart`.
- **Load Operational State dialog** — per-state activity
  timeline, same formatter.
- **Review-missing dialog** — per-row lineage narration: "→
  new.mp3 · matched on content_hash · 3m overlap" for moved
  rows; "last seen 8d ago · AIFF · WAV variants still
  available" for removed rows.
- **Right-click "View history" popup** — per-row causal
  inspection. Direct events + payload-reference events for the
  row's path. First per-row inspection surface.

### Playback deck
- Three-zone layout: NowPlaying (left, OverflowBox-bleeds-right
  into dead space) + transport (centred at app W/2 via
  Align(alignment)) + artwork (110×110) + volume (in utility
  rail at top).
- Sticky-current row pinning: playing track stays at its locked
  index even when its sort key changes.
- **Threshold crossing UX (2026-05-15)**: transient row flash
  (AnimatedContainer 500 ms accent wash) + REV cell glyph pulse
  (AnimatedScale + AnimatedDefaultTextStyle). Clears when next
  play() starts.
- Last Played column: `M/D/YY · H:MM AM/PM` format, 140 px
  default width.
- `_dataVersion`-only refresh on threshold cross — visible cache
  stays valid, no re-sort, neighbour rows don't shift.

### Utility rail (rebuilt 2026-05-13)
- Pinned Volume at top.
- ReorderableListView middle: Threshold, Mode, Audit, History,
  Move/Copy, Finder, Load — drag handle per card.
- Lock Order toggle at bottom.
- Order + lock state persist in `app_settings`.

### Defensive hardening
- `WidgetsBindingObserver.didChangeAppLifecycleState` re-grabs
  body focus on `AppLifecycleState.resumed`.
- Esc dismisses any open dialog before falling through to
  search-clear / body-refocus.
- Heal pass runs on every hydrate.
- Forbidden-language invariant test scans
  `lib/widgets/**.dart` for archival semantics in user-facing
  strings. Caught + fixed a real violation on first run.

### Architecture docs (in-repo, not memory)
- `docs/architecture/`:
  - `system_ontology.md` (~580 lines) — canonical model.
  - `architectural_laws.md` (~200 lines) — invariants.
  - `ui_philosophy.md` (~360 lines) — surface + trust.
  - `resolver_architecture.md` (~450 lines) — design-only.
  - `PROJECT_CONTEXT_PACK.md` — this doc.
- `docs/testing/manual_smoke.md` — 9-scenario manual
  verification checklist.

### Test posture (390 tests as of 2026-05-15)
- Dense data-layer coverage: heal, supersession 4-condition,
  lineage events, history, batch upsert, content_hash,
  move/copy, unlink, availability.
- Pure-function: event log format, song identity, file format.
- Architectural invariant: L10 forbidden-language test (caught
  real regression).
- Integration: operational journal end-to-end.
- Save manager + state browser: round-trip integration.

---

## 6. Active bug investigations

### Input-event desync (Slice B, partially mitigated)
**Symptom:** mouse clicks die OR arrow keys die while hover
stays alive. Restart fixes; hot reload does NOT. Observed both
after Cmd+Tab away/return AND once after hot reload.

**Audit findings (2026-05-15):** no `AbsorbPointer` /
`IgnorePointer` / `OverlayEntry` / `ModalBarrier` leaks in
dispatched code. Every `showDialog` / `showGeneralDialog` uses
`barrierDismissible: true`. No `barrierDismissible: false` traps.

**Defensive layers shipped:**
- A4 — focus re-grab on `AppLifecycleState.resumed`.
- Esc dismisses open dialogs first (was previously short-circuited
  by global HardwareKeyboard handler).

**Status:** mitigated for the Cmd+Tab variant. Root cause of the
hot-reload variant still unknown. Without a reliable repro,
further investigation paused.

### Dropbox cloud-placeholder hang on add-source (fixed 2026-05-15)
**Was:** adding a Dropbox watch folder hung the main thread for
423 seconds (per macOS sysdiagnose). Root cause:
`computeContentHashSync` inside batch upsert called on the main
isolate; APFS blocked the read while materialising a dataless
placeholder via `apfs_materialize_dataless_file_ext`.

**Fix:** `library_repository.dart` batch upsert now uses
`await computeContentHash(...).timeout(30s, onTimeout: () => null)`.
Yield-to-event-loop every 200 iterations so UI keeps painting
even on huge inserts.

**Not yet covered (queued for follow-up audit):**
- Other sync FS calls on the main isolate (statSync in migration
  paths, etc).
- dart:io thread-pool starvation if every thread is blocked on
  Dropbox. 30s timeout caps individual file hangs; full fix would
  move heavier work to isolates.

### Mid-playback row reshuffle (fixed 2026-05-15)
**Was:** rows around the currently-playing track shuffled
position when the threshold crossed. Root cause: threshold-cross
block called `_markLibraryDirty()` which nuked the visible cache;
next `visibleTracks` re-ran the sort; sticky-current's
removeAt+insert shifted neighbours by 1.

**Fix:** replaced with bare `_dataVersion++`. Track object mutates
in place; widget rebuilds via `notifyListeners()` read updated
values directly; visible cache stays valid.

---

## 7. Current high-priority directions

### Slice C — Sort groups / Smart Views / TempGroups (next, design-first)
User-requested: right-click column header → "Group by {column}" →
new entry in sidebar under "TEMP GROUPS" section. Children =
distinct values. Click child to filter.

Approved direction:
- One parent entry, expandable to children (vs flat N entries
  vs modal popup).
- Session-only by default (vs persisted vs pin-to-persist).
- V1 columns: TBD when user re-engages.

Internal naming: **`SmartView` / `TempGroup` / `OperationalGroup`**.
Never `folder` — that would invite filesystem-mirroring reflexes.
User-facing label is free ("Temp groups" etc).

Status: design conversation paused mid-Question-3. Resume when
user signals.

### Resolver implementation (deferred, post-design-iteration)
Design doc shipped: `resolver_architecture.md`. Defines the
contract: pure function over Contributions, in-memory derived view,
additive merge, conflict surfacing. Six open questions enumerated
(favorite-vs-unfavorite, review-state composition, identity-link
conflict policy, composition trigger granularity, cumulative
listened sum-vs-max, boot ordering).

Will eventually live in `runtime_state_flow.md` (also deferred —
"speculative formalization before contribution model stabilizes
would prematurely freeze unresolved authority semantics").

### Operational lineage visibility (in flight, per-row layer done)
Causal narration is the active conceptual direction. Established
in Review-missing dialog + History popup. Future surfaces inherit
the same vocabulary (matched_on, overlap, successor, coexistence)
rather than inventing their own. Per-track "tell me the story of
this song" full modal is the next planned step — deferred until
resolver semantics stabilise.

### iPhone operational projection (future, undefined)
User has mentioned this as a long-horizon direction. Not in any
current slice. Would presumably be a separate Device Contribution
via `Systems/IPHONE.library` + `Shared Libraries/` exchange. Waits
on resolver.

---

## 8. Deferred / explicitly not decided

| Question | Status |
|---|---|
| Resolver implementation | Design only. Six open questions in `resolver_architecture.md` §9. |
| Composed-graph persistence | **Forbidden.** "Ephemeral derived view, never persisted as authoritative state." See resolver_architecture.md §7. |
| Current/ removal (long-term) | Explicitly "DO NOT decide yet" per the boot-transition slice's guiding principles. |
| `runtime_state_flow.md` | Deferred until resolver enters concrete design. |
| Sort group lifetime/storage/predicate granularity | Open. User to direct when Slice C resumes. |
| Per-track lineage modal | Deferred until vocabulary stabilises across resolver work. |
| Two-persistence-world unification (.library vs intelligence.json) | Deferred until Shared Libraries exchange semantics settle. L12 forbids premature merging. |
| Cross-device sync mechanism | Out of scope. Filesystem boundary (`Shared Libraries/`) is the architectural seam; how files get there is the user's problem. |
| BPM bucketing for sort groups | Open. Likely V2 of Smart Views. |
| Smart View ↔ source-scope interaction | Open. Override vs respect-current-source. |
| Resolver explicit-unfavorite vs favorited union | Q1 in resolver_architecture.md §9. |
| Cumulative listened sum vs max across devices | Q5 in resolver_architecture.md §9. |

---

## 9. Terminology — approved & forbidden

### Approved language (operational state surfaces)

| Term | Use |
|---|---|
| **Load operational state** | The action of selecting a `.library` |
| **Load this operational state** | Dialog's primary button (exact label) |
| **Switch library state** | Verb-form when narrating |
| **Operational reality / Library reality** | The state the app is bound to |
| **Lineage point / Lineage state** | A `Saves/` entry |
| **Contribution channel / Device channel / Device state** | A `Systems/{MACHINE}.library` |
| **Current device state** | This device's live Systems/ file |
| **Historical operational states** | The Saves/ chain |
| **Shared libraries** | `Shared Libraries/` entries |
| **Temp groups** | (user-facing) Smart Views in sidebar |

### Forbidden language (NEVER in user-facing copy)

Enforced by `test/architectural_invariants_test.dart` — scans
`lib/widgets/**.dart` for these in string literals:
- **Backup** / **Backups**
- **Restore** / **Restores** / **Restoring**
- **Snapshot** / **Snapshots** (in UI strings — internal code can
  use the word)
- **Revert** / **Reverts** / **Reverting**
- **Rollback** / **Roll back**

`Import` is NOT in the test allowlist — reserved for the legacy
`intelligence.json` flow.

### Internal-naming discipline

| Concept | Internal name | User-facing label |
|---|---|---|
| Operational projection over tracks | `SmartView` / `TempGroup` / `OperationalGroup` | "Temp groups" / "Groups" |
| Future composed graph across devices | `GlobalLibraryGraph` | (no UI yet) |
| Auto-supersession decision | `markMovedSupersessions` / `markCrossSourceMoves` | "Moved" section in Review-missing |
| Per-File-Instance temporal anchor | `first_seen_at` | (not surfaced) |

**Critical**: `folder` is RESERVED for actual filesystem folders.
SmartView is not a folder. The user-facing label can be friendly
without poisoning the ontology.

---

## 10. Restoration checklist for a cold session

**Read in order** to recover working architectural context:

1. **This file** (`PROJECT_CONTEXT_PACK.md`) — orientation.
2. **`docs/architecture/system_ontology.md`** — the canonical
   conceptual model. Everything else derives from it. (~580 lines.)
3. **`docs/architecture/architectural_laws.md`** — the 12 invariants
   the ontology must preserve. (~200 lines.)
4. **`docs/architecture/ui_philosophy.md`** — surface philosophy,
   trust boundaries, operational language guardrails. (~360 lines.)
5. **`docs/architecture/resolver_architecture.md`** — design-only
   composition contract. The six unresolved questions to be answered
   by future implementation iteration. (~450 lines.)
6. **`docs/testing/manual_smoke.md`** — 9-scenario operational
   verification checklist.

**Memory files worth reading** (`~/.claude/projects/<sanitised-cwd>/memory/`):
- `project_library_knowledge_graph_direction.md` — original direction memo.
- `project_three_layer_identity_model.md` — identity ontology with Phase 2 supersession notes.
- `project_codec_as_operational_axis.md` — codec ≠ duplicate.
- `project_library_save_system.md` — folder layout + autosave semantics.
- `feedback_operational_state_language.md` — L10 guardrails.
- `feedback_save_trust_cycle.md` — the 5-property acceptance bar.
- `feedback_two_persistence_worlds.md` — `.library` vs `intelligence.json` gap.

**Commands to ground yourself in current state:**
```bash
git log --oneline -30                    # recent slices
flutter analyze 2>&1 | tail -3           # baseline clean?
flutter test 2>&1 | tail -3              # baseline green?
ls docs/architecture/                    # in-repo architecture docs
ls -la ~/Documents/Music\ Tracker/       # live LibraryRoot (if present)
```

**Critical files to know exist:**
- `lib/services/library_repository.dart` — the heart. All DB
  reads + writes. Heal pass. Supersession. Move/Copy.
- `lib/state/library_controller.dart` — the central command
  surface. Every workflow action lives here (L11). ~3500 lines.
- `lib/services/content_hash.dart` — async + sync hash; sync is
  test-only after the 2026-05-15 fix.
- `lib/services/content_hash_backfill.dart` — throttled background
  hash worker (10 rows / 500 ms, 30s per-file timeout).
- `lib/services/audio_scanner.dart` — directory walk in isolate
  via `compute()`.
- `lib/widgets/event_log_format.dart` — shared event-rendering
  formatter. Adding a new EventType means one edit here.
- `lib/widgets/track_table.dart` — ~2000 lines. Row builder,
  sticky-current logic, threshold animation, REV cell pulse.
- `lib/screens/home_screen.dart` — top-level layout +
  `HardwareKeyboard` handler + lifecycle observer.

**Tests to run when in doubt:**
- `test/architectural_invariants_test.dart` — L10 guard.
- `test/operational_journal_integration_test.dart` — causal pipeline.
- `test/library_repository_supersession_4cond_test.dart` — Phase 2.
- `test/library_repository_heal_test.dart` — heal pass.

---

## 11. How to use this pack — meta

**For a future Claude session:** read this doc + the four
companion architecture docs (system_ontology, architectural_laws,
ui_philosophy, resolver_architecture) before doing anything
substantive. Together they take maybe 30 minutes to read at a
density that restores working architectural context.

**For when this doc gets stale:** the "current system status,"
"active investigations," and "high-priority directions" sections
will drift fastest. Sections 1–4 (identity, ontology, laws, trust)
should be near-permanent. If a section in 1–4 starts feeling
wrong, that's a signal the ontology has shifted — update the
underlying architecture docs first, then update this pack.

**Compression test for this doc itself:** if you can read it in
under 15 minutes and articulate "what is Music Tracker, what are
its load-bearing invariants, what's shipped, what's queued, what's
forbidden" — it's doing its job. If it reads slow or repetitive,
it's failing.

---

## 12. Cross-doc index

| Doc | What it answers |
|---|---|
| `PROJECT_CONTEXT_PACK.md` (this) | "Where are we and how did we get here?" |
| `system_ontology.md` | "What are the entities and what do they mean?" |
| `architectural_laws.md` | "What invariants must hold?" |
| `ui_philosophy.md` | "How should the user surface look and feel?" |
| `resolver_architecture.md` | "How will multi-device composition eventually work?" |
| `docs/testing/manual_smoke.md` | "How do I verify it still works?" |

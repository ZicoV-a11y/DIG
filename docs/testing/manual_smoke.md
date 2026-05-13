# Manual Smoke Protocol

Run-by-hand checklist for things automated tests can't reach: visual
feel, transition timing, real-disk behavior, real-app lifecycle.
Codifies the validations that have been catching regressions
organically (the AIFF-disappearance bug, the Current/-as-authority
drift, the operational-state-vs-backup language drift, the
Save/Systems trust round-trip).

Run this checklist before tagging a release, after a slice that
touches identity / supersession / save semantics / event narration,
or whenever something feels off.

Last revised: 2026-05-13.

---

## How to use this document

Each section below is a *scenario*: a sequence of real actions in
the running app + the observable outcomes that must hold. If any
outcome fails, the slice that introduced the regression goes back
to the drawing board.

The order is roughly "highest blast radius first" — boot/identity
issues are catastrophic, UI-language drift is reversible. Run the
top three even when in a hurry.

The protocol intentionally references the architecture docs by
name. If a scenario stops making sense, the docs are the source of
truth — update either the doc or the scenario, not both
independently.

---

## 1. Boot identity & operational continuity (L1 + L2)

**Setup:** quit the app cleanly. Open Finder to
`~/Documents/Music Tracker/`.

**Scenario:**
- [ ] `machine_id.txt` exists in the LibraryRoot. Opening it in
      TextEdit shows a single sanitised line (e.g. `NEOMACS_MACBOOK_LOCAL`
      or `MACNEO`).
- [ ] `Systems/{MACHINE}.library` exists and is non-empty.
- [ ] `Current/CURRENT.library` exists and matches `Systems/`'s
      contents within an autosave tick (sizes should be the same or
      within a few KB).
- [ ] Relaunch the app. It boots without prompting, the track table
      populates, and the workspace looks identical to the previous
      session.
- [ ] The mtime on `Systems/{MACHINE}.library` advances after a few
      autosave ticks. `Current/CURRENT.library`'s mtime also
      advances (slightly later — Current/ is written as the mirror
      step, see L2).

**Fail mode to watch for:** if boot prompts for setup, or
`Current/` is newer than `Systems/`, or `machine_id.txt` is
missing — boot routing has drifted back to the pre-2026-05-12
shape.

---

## 2. Save / Systems trust round-trip (5 acceptance properties)

**Setup:** with the app running, take a manual save via the utility
rail (or wait for an autosave). Note the `Saves/{LIB}__{MACHINE}__{DATE}__{TIME}.library`
filename.

**Scenario:**
- [ ] **Save legibility:** the Save filename is readable in Finder
      with no app help — library, device, date, time all decodable.
- [ ] **Save isolation:** modify the library state (favourite a few
      tracks, play a few songs). The previously-noted Save file's
      *mtime* and *size* don't change.
- [ ] **Load fidelity:** open the Load Operational State dialog.
      Select the previously-noted Save. Click "Load this operational
      state." After the prompted restart, the library returns to the
      pre-modification state.
- [ ] **Lineage preservation:** the modifications you just made
      didn't *destroy* the Save you loaded from — it's still in
      `Saves/`. (The load action takes a final autosave of current
      state first; verify a new Save file appears with the moment-
      before-load timestamp.)
- [ ] **No backup language:** the Load dialog uses "Load operational
      state" / "Switch library state" — NEVER "Restore," "Revert,"
      "Backup," "Snapshot," "Import." If any of those words appear
      in user-facing copy, file a bug. (L10.)

---

## 3. Phase 2 supersession + temporal evidence

**Setup:** identify a song with a single File Instance in one
watched source. Note the exact path.

**Scenario:**
- [ ] In Finder, move the file from its current source folder to
      another watched-source folder. (Use cmd-drag for actual move,
      not copy.)
- [ ] Wait for the next scan tick (or trigger a manual rescan via
      the utility rail).
- [ ] The original row's `availability_state` flips from `available`
      to `superseded`. The destination row appears as `available`.
- [ ] **Open the Review-missing dialog.** The original path appears
      under the **MOVED** section.
- [ ] Beneath the path, the lineage narration reads:
      `→ {new basename}  ·  matched on content_hash  ·  {N}m overlap`
      (or "matched on fingerprint" if content_hash hasn't been
      backfilled for the row). The overlap value is small (0–10
      min) and reflects how briefly both rows were `available`
      simultaneously.
- [ ] Right-click the destination row in the main table → "View
      history." The popup shows the auto_move event with the same
      narration. The original (now-superseded) path is referenced
      as `successor_path` in the event payload.

**Fail modes to watch for:**
- Auto-supersession fires for a clearly-intentional duplicate (no
  Move event, both files coexisted for hours/days). The temporal-
  evidence overlap value would be unrealistically large — the
  Phase 2 rule should have rejected the supersession (the
  overlap-grace constant is 10 min).
- Auto-supersession refuses an obvious move. Check that both rows'
  filesize > 0 and duration_ms > 0 (junk-stat protection).

---

## 4. Codec / variant coexistence (L7 + L8)

**Setup:** find a Track Identity that exists in multiple codecs
(MP3 + AIFF, etc.). Note all variants and their paths.

**Scenario:**
- [ ] In the main table, the variants render as one row (collapsed
      bucket) with the format pill showing all codecs (e.g.
      `MP3 · AIFF ×2`).
- [ ] Right-click the row. The reveal-in-Finder submenu lists
      every variant with a disambiguator (folder or filename).
- [ ] Open the Move/Copy dialog from this row. The **VARIANT**
      picker section appears at the top with one row per File
      Instance, codec-labelled, source-attributed.
- [ ] Choose a single variant to copy to another source. Apply.
      After the copy lands, the bucket still shows ALL original
      variants + the new one. *No variant disappeared.*
- [ ] If a variant disappears: the `identity_override` propagation
      across 4-field siblings has regressed. (Slice 2 of the
      codec-siblings fix, May 2026.)

---

## 5. Lineage narration consistency across surfaces

**Setup:** trigger any event that gets recorded in `events`
(move a file, copy a file, link two tracks, edit tags externally).

**Scenario:**
- [ ] Open the **Activity Log** from the utility rail. The new
      event appears with icon + label + detail line (where
      applicable).
- [ ] Right-click the affected row → **View history**. The same
      event appears with the *same* label and *same* detail line.
- [ ] If the row qualified for an auto-move, open the
      **Review-missing** dialog. Same label + detail line beneath
      the path.
- [ ] If the row was loaded via a Save State, open the **Load
      Operational State** dialog → select that Save → preview pane
      shows the activity timeline. The same event renders the same
      way.

**Fail mode:** any of these four surfaces renders the event
differently. The shared formatter (`event_log_format.dart`) is
where the divergence must be fixed; the surface-specific code
should never embed its own event-rendering logic.

---

## 6. Operational-state language audit

**Setup:** open every dialog that shows operational state:
- Load Operational State dialog
- Save flow (utility rail save button)
- Review-missing dialog
- Activity Log dialog
- Track-history popup

**Scenario — look for forbidden words in user-facing copy:**
- [ ] **NEVER** see: "Backup," "Restore," "Restore from backup,"
      "Revert," "Snapshot," "Import," "Rollback," "Restore point,"
      "Roll back."
- [ ] **DO** see: "Load operational state," "Switch library state,"
      "Operational reality," "Lineage point," "Device state /
      channel," "Historical operational states," "Shared
      libraries."

**Fail mode:** any forbidden word in user-facing copy. This is the
single highest-leverage check in the whole protocol — language
drift collapses the ontology faster than any other surface bug.

---

## 7. Persistent autosave + healing pass

**Setup:** with the app running, monitor `Saves/` in Finder.

**Scenario:**
- [ ] Wait for an autosave tick. A new `Saves/{LIB}__{MACHINE}__{DATE}__{TIME}.library`
      file appears.
- [ ] `Systems/{MACHINE}.library` mtime advances (it's the live DB
      sqflite writes to).
- [ ] `Current/CURRENT.library` mtime advances shortly after (the
      mirror step).
- [ ] Restart the app. The `[hydrate]` debug log mentions either
      `0 orphaned identity_override siblings` (clean) or `N
      siblings healed` (post-codec-fix repair). Either is fine; a
      non-zero value should appear at most once per machine and
      then settle to zero.

---

## 8. Quick-fire visual feel checks

Calmer scope — visual hierarchy, not data. These catch the
"something feels off" class of regressions.

- [ ] **Three-zone layout:** 4 px breathing margin around all
      zones (Library/Nav, Workspace, Transport). No hard dividers
      between zones; only tonal contrast.
- [ ] **Transport row proportions:** play button 80×80, skip + prev/next
      48×64. Don't square the side buttons.
- [ ] **Selection in Load dialog:** selected row has a 3 px
      left-edge accent border; machineId is heavier weight than
      unselected rows.
- [ ] **No dashboard cards:** no rounded rects with shadows around
      zones. No floating panels. Music Tracker is a workstation,
      not a CRM.
- [ ] **Spreadsheet rhythm:** typing in search → results filter
      instantly. Keyboard navigation in the table doesn't lose
      focus on data updates.

---

## 9. After major changes only

Run when a slice touches schema, supersession, identity, or save
semantics.

- [ ] **Migration idempotency:** quit the app. Run any pending
      migration manually via `flutter run` once. Run it again.
      Second run reports `0 rows backfilled` for v12→v13, no
      schema changes for any version. Migration is idempotent or
      you have a bug.
- [ ] **Test parity:** `flutter analyze` clean, `flutter test`
      all passing. Manual flows match what automated tests claim
      to verify.
- [ ] **No raw SQL exceptions in user-facing dialogs:** open every
      dialog after a fresh boot. No `SqfliteFfiException` or
      `SQLiteException` text appears anywhere on screen. (Past
      regression: cumulative_listened_ms vs cumulative_ms leaked
      raw SQL into the Load dialog preview.)

---

## What's NOT covered by this protocol

Things that need their own (eventually-codified) checks:

- **Cross-device workflows.** The resolver hasn't shipped; multi-
  device exchange via `Shared Libraries/` is scaffolded but
  unconsumed. Add scenarios here when the resolver implementation
  slice begins.
- **Performance at scale.** No benchmark suite yet. If a slice
  starts feeling slow on 10k+ tracks, this protocol is the wrong
  place — write a performance test instead.
- **Crash recovery.** What happens if the app force-quits mid-
  autosave? Probably worth a scenario once the in-app reload
  slice lands.

---

## Companion documents

- [`docs/architecture/architectural_laws.md`](../architecture/architectural_laws.md) —
  the invariants this protocol verifies.
- [`docs/architecture/system_ontology.md`](../architecture/system_ontology.md) —
  the vocabulary the protocol uses.
- [`docs/architecture/ui_philosophy.md`](../architecture/ui_philosophy.md) —
  the trust-design rules behind §6's language audit.

# System Ontology

**`system_ontology.md` is the canonical conceptual model of the
application.** Every concept Music Tracker reasons about, defined
once, in one place, so future work can refer to terms by name
rather than rebuilding the model.

Everything else in `docs/architecture/` derives from this document:

- [`architectural_laws.md`](architectural_laws.md) = constraints
  derived from the ontology (invariant enforcement, failure
  detectors).
- `ui_philosophy.md` = surface derived from the ontology (the
  language and trust boundaries the user touches).
- [`resolver_architecture.md`](resolver_architecture.md) (design
  only, no implementation yet) = composition derived from the
  ontology.
- `runtime_state_flow.md` (deferred) = flows derived from the
  ontology.

Architectural layering: **Ontology defines reality. Laws enforce
reality. UI expresses reality. Resolver executes reality. Runtime
flow choreographs reality.** Identity bugs are ontology bugs —
anything that drifts from the model below is the bug, not the
model.

Last revised: 2026-05-13.

---

## 1. Core entities

### 1.1 Library

The user's entire music universe. A single conceptual thing — not
a folder, not a database, not a device. The Library is the
*intent*: every song the user owns, has played, has reviewed, or
has organised, considered as one whole.

Naming convention: `{USER}_LIBRARY` (e.g. `NEOMAC_LIBRARY`). One
library per user, not one library per genre, crate, or device.
Crates and views are *projections* of the Library, not Libraries.

### 1.2 Global Library Graph

The composed reality of the Library across every device that has
contributed to it. The output of the resolver (deferred work).
Today, with a single device, the Global Library Graph collapses
onto that device's contribution — but conceptually remains
distinct so multi-device composition can land without
re-architecting.

### 1.3 Device Contribution

One device's perspective on the Library. Each device contributes
its observations (favorites, plays, review state, file
availability) INTO the Global Library Graph but never claims to
*be* it. See [L4](architectural_laws.md#l4-devices-contribute-into-the-library-never-as-the-library).

A Device Contribution is concretely embodied by a single file:
`Systems/{MACHINE}.library`. Today that file is also the live
operational source for the running app (the device is alone in
the universe), but the contribution-vs-authority distinction
holds.

### 1.4 Operational State

A queryable, openable snapshot of the Library at a moment in
time. Every `.library` file is an Operational State.

Three operational-state kinds:
- **Live operational state** — the file the running app is
  currently writing to (`Systems/{MACHINE}.library`).
- **Historical operational state** — a frozen lineage entry in
  `Saves/`.
- **Foreign operational state** — a device-channel file in
  `Systems/` belonging to another machine, or a contribution in
  `Shared Libraries/`.

A user *loads* an Operational State (navigates between them); a
user never *restores* an Operational State (that would frame it
as recovery). See
[L10](architectural_laws.md#l10-operational-state-ui-never-sounds-like-backup-software).

### 1.5 Operational Truth

The single Operational State the running app is currently bound
to. Plural Operational States exist on disk; Operational Truth
is singular at any moment — it's the one sqflite has open.

### 1.6 Historical Lineage

The chronological chain of Save States in `Saves/`, newest first.
Lineage is *navigable* (Load dialog), *readable* (Finder), and
*non-authoritative* (loading from lineage does not "restore" the
library; it switches Operational Truth to a prior state). See
[L6](architectural_laws.md#l6-saves-is-lineage-not-authority).

### 1.7 Save State

One entry in Historical Lineage. A frozen-in-time copy of the
Live Operational State, named with a readable filename
(`{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library`). Saves are
written by the autosave timer and by manual save actions; they
are never deleted by the app, never auto-pruned, never opaque.

---

## 2. Filesystem entities

The on-disk embodiment of the conceptual model. Filesystem
layout IS the architecture — see
[L3](architectural_laws.md#l3-filesystem-layout-is-the-architecture).

```
~/Documents/Music Tracker/         ← the LibraryRoot
├── machine_id.txt                 ← filesystem-level device identity (L1)
├── Systems/
│   └── {MACHINE}.library          ← live Operational State (this device)
├── Current/
│   └── CURRENT.library            ← compatibility mirror (transitional)
├── Saves/
│   └── {LIB}__{MACHINE}__{DATE}__{TIME}.library
│                                  ← Save States (Historical Lineage)
├── Shared Libraries/              ← foreign Device Contributions (scaffold)
├── Cache/                         ← derived artifacts, safe to delete
└── Logs/                          ← debug / audit
```

### 2.1 LibraryRoot

The folder containing all of the above. Default:
`~/Documents/Music Tracker/`. User-relocatable in future, but the
directory's *shape* is fixed.

### 2.2 `machine_id.txt`

Plain text file holding this device's sanitised machine ID. Read
at boot *before* any DB operation so boot routing can choose the
right `Systems/{MACHINE}.library` without opening a DB first.
See [L1](architectural_laws.md#l1-device-identity-is-filesystem-level-not-db-resident).

### 2.3 `Systems/`

Device-channel directory. Holds one `.library` file per device
that has ever run the app against this LibraryRoot. The file
named for the current machine is the Live Operational State; the
others are foreign Operational States visible in the Load dialog.

### 2.4 `Saves/`

Historical Lineage directory. Holds the chronological chain of
Save States. Filenames are always parseable as
`{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library` so the Save
becomes meaningful from Finder alone — no app needed.

### 2.5 `Current/`

Compatibility mirror of the Live Operational State. Pre-boot-
transition code paths and external tools that expected
`Current/CURRENT.library` continue to find a copy here. Written
on every autosave as a `copy-after-snapshot` step. Long-term
fate (keep / cache / remove) is deliberately undecided.

### 2.6 `Shared Libraries/`

Foreign Device Contributions consciously exchanged between
devices (USB drop, AirDrop, cloud folder, etc.). Scaffolded in
the filesystem today; not yet consumed by the resolver. Files
here follow the same naming convention as Saves/ so Finder can
read them.

---

## 3. Track model

The most subtle layer of the ontology. Three independent
dimensions, never collapsed.

### 3.1 The three layers

```
Track Identity                      ← the musical work
    ├── Media Representation: MP3   ← the codec / encoding
    │       ├── File Instance: /DL Folder/song.mp3
    │       └── File Instance: /Z CRATE/song.mp3
    ├── Media Representation: AIFF
    │       └── File Instance: /DL Folder/song.aiff
    └── Media Representation: WAV
            └── File Instance: /external/song.wav
```

Each layer is independently mutable and independently queryable.
Conflating any two collapses the ontology and produces bugs
like the AIFF-disappearance regression of 2026-05-12. See
[L7](architectural_laws.md#l7-track-identity-media-representation-and-file-instance-are-independent-layers).

### 3.2 Track Identity

The musical work itself — one recording, one composition, one
creative artifact. Drives:
- Variant grouping in the table (one row per Track Identity).
- Shared behavioral intelligence (favorites, play count,
  cumulative listened, review state).
- Aggregated statistics.

Two file rows share Track Identity iff they pass
`sameSongIdentity` (see §3.6).

### 3.3 Media Representation

The codec / encoding format (MP3, AIFF, WAV, FLAC). An
**operationally meaningful axis** — DJs deliberately keep
multiple representations of the same Track Identity:
- Lossless (AIFF / WAV / FLAC) for home decks, mastering,
  archival.
- MP3 (320 / VBR) for travel USB drives, CDJ sticks, cloud
  sync, legacy gear.

Codec coexistence is intentional. It is *not* duplication.

### 3.4 File Instance

A specific row in `indexed_files`. Has its own:
- Path (unique key — two paths = two instances).
- Source membership (which watched folder).
- Availability state (available / missing / superseded).
- Filesize, modified-at timestamp.
- `first_seen_at` / `last_seen_at` lineage.
- Content hash (byte-level fingerprint, when computed).

A given Media Representation may correspond to multiple File
Instances (e.g. an MP3 master in `A/` and a working copy in
`Z CRATE/`). Each File Instance is independently real.

### 3.5 Identity signals

Three signals contribute to whether two File Instances share
Track Identity:

1. **`identity_override`** — explicit UUID stamped by user
   actions (Link, Unlink) or by Copy. Two rows with the same
   non-empty override always share Track Identity. A row whose
   override equals its own `uid` is *explicitly unlinked* (a
   singleton). See
   [L8](architectural_laws.md#l8-identity_override-mutations-propagate-across-all-4-field-matched-siblings).

2. **`fingerprint`** — `(basename + filesize + duration_ms)`
   hash. Detects "same file at a different path". Two rows
   with the same non-empty fingerprint share Track Identity
   (file-level equivalence).

3. **4-field match** — `(basename_no_ext, title, artist,
   duration_in_whole_seconds)` exact. The auto-matcher's
   primary rule for cross-codec pairing of the same recording.

Rule order is documented in `lib/utils/song_identity.dart`:
explicit override → fingerprint → 4-field. Tightness is the
safety property; manual link/unlink is the escape hatch.

### 3.6 `sameSongIdentity`

The decision function. Returns true iff two File Instances
share Track Identity under the rules in §3.5.

Asymmetric override states (one row has an override, the
other is NULL) are treated as intentionally distinct — that's
how unlink works. Pristine NULL-override siblings of a 4-field
match are *healed* at hydrate
(`healOrphanedIdentitySiblings`), not detected at query time.

### 3.7 Intentional duplicates

Two File Instances with **identical content hashes** are NOT
automatically the same Track Identity, are NOT automatically
superseded, and are NOT automatically merged.

DJs intentionally duplicate files: master + working copy,
crate-export staging copies, backup restores, re-rips. Both/all
physically exist; all have identical content. The app must not
silently collapse them.

Auto-supersession of one File Instance by another requires the
full four-condition check (see
[L9](architectural_laws.md#l9-auto-supersession-requires-all-four-conditions-not-content_hash-alone)):
missing + uniqueness + temporal-after + small-overlap.

### 3.8 Linked variants

Two File Instances explicitly bound to the same Track Identity
by the user (right-click → Link). Both rows receive the same
`identity_override` UUID. Linking overrides field-match
disagreements (different titles, different durations) — the
user has declared them the same recording.

### 3.9 Unlinked variants

A File Instance whose `identity_override` equals its own
`uid` — explicitly declared distinct from any auto-matcher
grouping. The heal pass never touches unlinked rows.

---

## 4. State model

How the Library's state moves through the system.

### 4.1 Operational truth

See §1.5. The single live Operational State the running app is
bound to.

### 4.2 Lineage

The chronological chain of past Operational States for this
device. Embodied in `Saves/`. Strictly historical — never
authoritative. Loading from lineage *switches* Operational
Truth to a prior state; it does not "restore" anything.

### 4.3 Contribution

The act of a single device producing its perspective on the
Library. The artifact: `Systems/{MACHINE}.library`. Today's
single-device runtime collapses contribution onto operational
truth (the device's contribution *is* the running app's live
DB), but conceptually they remain distinct.

### 4.4 Composition

The act of combining multiple Device Contributions into the
Global Library Graph. Deferred work. Composition is *additive*
(see §4.6) — every contribution lands; none silently overwrite
others.

### 4.5 Resolver

The composition engine (deferred). Reads every `Systems/*.library`
and `Shared Libraries/*.library`, produces the Global Library
Graph as a derived view. Pure function: same inputs → same
output. No mutation of contributions during composition.

### 4.6 Additive merge

The composition rule: every device's contribution is preserved.
Conflicts (e.g. same Track marked favorite on device A,
unfavorite on device B) are *recorded* and surfaced, not
silently resolved. See
[L5](architectural_laws.md#l5-the-resolver-is-additive-never-pick-newest).

Pick-newest is forbidden because it silently destroys a
contribution. Recency-based heuristics are valid *within* a
single device's lineage (Saves/), never *across* devices.

### 4.7 Cross-device state

Any state that flows between devices: Track Identity links,
favorites, plays, review states. Cross-device state must
survive Composition without loss; ergo, every cross-device
field needs a contribution-level record, not just a global
value.

---

## 5. Filesystem-as-architecture

Three structural commitments make the ontology readable from
Finder:

1. **Folders communicate kinds.** `Systems/` ≠ `Saves/` ≠
   `Shared Libraries/`. The kind of state is visible from the
   path, not from opening a database.

2. **Filenames carry semantics.**
   `NEOMAC_LIBRARY__MACNEO__2026-MAY-12__09-15AM.library` is
   parseable from Finder alone — library, device, date, time —
   without app cooperation.

3. **Device identity lives in plain text.** `machine_id.txt`
   is inspectable, editable, manually recoverable. Boot routing
   uses it before any DB is touched.

The pattern: anything the user is meant to navigate, anything
that supports rollback or recovery, anything that must survive
the app being uninstalled — surfaces as a visible folder or
filename. Hidden state is for derived artifacts (`Cache/`) and
debug (`Logs/`), nothing load-bearing.

---

## 6. Conceptual rulings

The explicit answers to recurring "what counts as" questions.

### "What counts as the same song?"

Two File Instances share **Track Identity** iff `sameSongIdentity`
returns true under the rules in §3.5 (override → fingerprint →
4-field). Same Track Identity = same row in the table, shared
behavioral intelligence.

### "What counts as a different representation?"

Two File Instances with the same Track Identity but different
file formats (MP3 vs AIFF vs WAV) are different **Media
Representations** of the same recording. They coexist
intentionally; the user picks between them per use case
(Move/Copy dialog's variant picker).

### "What counts as a different file instance?"

Two File Instances with the same Media Representation but
different paths (two MP3s of the same song at `/A/` and `/B/`)
are different **File Instances** of the same representation.
They also coexist intentionally — masters, working copies,
crate exports.

### "Why may AIFF + MP3 + WAV all coexist?"

Because codec is an operational axis, not a duplicate dimension
(§3.3). Each format serves a real DJ use case: lossless for
home decks, MP3 for travel, WAV for compatibility. Collapsing
them would destroy intent.

### "Why isn't identical `content_hash` enough to collapse files?"

Because DJs duplicate files intentionally (working copies,
crate exports, backup restores, re-rips). Content-hash match
alone is necessary but not sufficient evidence for
supersession; the four-condition check (§3.7) gates auto-merge.

### "Why is Contribution additive instead of pick-newest?"

Because pick-newest silently destroys a Contribution. Two
devices independently observing the Library may both have
legitimate state; composition must record both, not choose.
See [L5](architectural_laws.md#l5-the-resolver-is-additive-never-pick-newest).

### "Why must device identity be filesystem-level?"

Because boot routing decides *which DB to open*. If that
decision lives inside a DB, the routing is circular: you'd
have to open a DB to learn which DB to open. `machine_id.txt`
breaks the cycle. See
[L1](architectural_laws.md#l1-device-identity-is-filesystem-level-not-db-resident).

---

## 6.5 Forbidden Collapses

The negative-space companion to the rest of the ontology. §1–§5
define what the system *is*; this section enumerates what the
system must *never accidentally become*. Most difficult bugs in
this codebase have been ontology-collapse bugs, not implementation
bugs — accidentally treating two distinct concepts as one.

Each entry: the forbidden equation, then the bug it prevents.

- **codec ≠ duplicate.** Media Representation is operationally
  meaningful (DJs deliberately keep AIFF for home decks and MP3
  for travel). Collapsing → AIFF disappears from buckets after a
  Copy stamps overrides on the MP3 pair only. (Regression
  observed 2026-05-12.)

- **save ≠ backup.** Save States are navigable operational
  states, not disaster-recovery artifacts. Collapsing → the UI
  drifts into "restore" / "revert" language, the user assumes
  load is destructive, and the trust model collapses.

- **device ≠ library.** A Device Contribution is one
  perspective on the Library; the Library is the composed
  Global Graph. Collapsing → master-device thinking, pick-newest
  resolver, silent destruction of cross-device contributions.

- **`Systems/{DEVICE}.library` ≠ the library itself.** The
  device-channel file is one Contribution; the Library is the
  composed Global Graph. Single-device runtime collapses these
  *visually*, never *conceptually*. Collapsing → future
  multi-device composition becomes impossible without an
  architectural rewrite.

- **operational state ≠ historical lineage.** A live `.library`
  in `Systems/` is operational truth; the chain of `.library`
  files in `Saves/` is navigable history. Loading from lineage
  *switches* truth; it does not "recover" or "replay" it.
  Collapsing → Save States get authoritative semantics they
  weren't designed for; lineage becomes a write target.

- **hash match ≠ same operational file.** `content_hash` parity
  is necessary but not sufficient for supersession. Collapsing →
  auto-merge of intentional duplicates (master + working copy,
  crate exports, backup restores), silently destroying file
  intent.

- **newest ≠ authority.** Recency wins *within* a single
  device's lineage; never *across* devices. Collapsing → the
  resolver picks-newest, a phone with stale state overwrites
  the desktop's recent changes, contributions die silently.

- **representation ≠ instance.** A codec (Media Representation)
  may correspond to multiple File Instances at different paths.
  Collapsing → the variant picker silently picks for the user,
  Move/Copy targets the wrong physical file.

- **filesystem ≠ truth mirror.** The filesystem encodes the
  *architecture* but doesn't substitute for it; the DB still
  holds behavioral intelligence (favorites, plays, review
  state). Collapsing → "if it's not in Finder it's not real,"
  losing the operational/intelligence distinction.

- **`Current/` ≠ authority.** After the 2026-05-12 boot
  transition, `Current/` is a compatibility mirror;
  `Systems/{MACHINE}.library` is the live operational source.
  Collapsing → Current/ silently becomes authoritative again
  (most common via "open the DB at the most predictable path"
  shortcuts).

---

## 7. Glossary

| Term | One-line definition |
|---|---|
| Library | The user's entire music universe; named `{USER}_LIBRARY` |
| Global Library Graph | Composed Library state across all Device Contributions (deferred) |
| Device Contribution | One device's perspective on the Library; embodied as `Systems/{MACHINE}.library` |
| Operational State | A queryable `.library` snapshot — live, historical, or foreign |
| Operational Truth | The currently-loaded Operational State the running app is bound to |
| Historical Lineage | The chronological chain of Save States in `Saves/` |
| Save State | One entry in Historical Lineage; a frozen Operational State |
| LibraryRoot | The on-disk folder containing all Library state |
| Track Identity | The musical work; one row per Track Identity in the table |
| Media Representation | A codec/format encoding of a Track Identity |
| File Instance | A specific row in `indexed_files`; unique by path |
| Linked Variants | File Instances bound to the same Track Identity by user action |
| Unlinked Variant | A File Instance forced into a singleton bucket (override = own uid) |
| Intentional Duplicate | Two File Instances with identical content_hash that the user wants to keep separate |
| Fingerprint | `(basename + filesize + duration_ms)` hash — file-level equivalence signal |
| `identity_override` | Explicit UUID stamped on a File Instance to control Track Identity grouping |
| `sameSongIdentity` | The decision function combining override, fingerprint, and 4-field signals |
| Contribution | The act of a device producing its perspective on the Library |
| Composition | The act of combining contributions into the Global Library Graph |
| Resolver | The composition engine (deferred) |
| Additive merge | The composition rule: no contribution is silently overwritten |
| Cross-device state | State that flows between devices and must survive composition |

---

## 8. Why this doc stabilizes now (and others wait)

**The ontology documents what is already true. Deferred docs
would currently require speculation about truths that have not
stabilized yet.**

That single stabilization principle explains the entire
architecture-docs sequencing:

- **`system_ontology.md` ships now** because the entities,
  layers, and conceptual rulings have all been validated by
  real bugs (the AIFF-disappearance regression, the Current/-as-
  authority drift, the operational-state-vs-backup language
  drift). They are no longer hypotheses.
- **`runtime_state_flow.md` waits** because the resolver is
  still in the discovery phase; formalizing runtime flow before
  the contribution model stabilizes would prematurely freeze
  unresolved authority semantics.
- **`resolver_architecture.md` ships as design only** (2026-05-13)
  — it captures the conceptual contract every future resolver
  implementation must satisfy (additive-only composition,
  ephemeral derived view, no cross-device authority hierarchy).
  Implementation waits until empirical iteration answers the
  open questions enumerated in its §9.

Speculative formalization is more dangerous than no doc at all,
because it ossifies the wrong model and creates rework debt.
Ship the ontology first; everything else derives from it once
it's true.

---

## 9. Companion documents

- [`architectural_laws.md`](architectural_laws.md) — the load-
  bearing invariants derived from this ontology. *Which* terms
  here must hold under *which* constraints.
- `ui_philosophy.md` — the user-facing vocabulary and
  operational trust boundaries derived from this ontology.
- [`resolver_architecture.md`](resolver_architecture.md) (design
  only, no implementation yet) — graph composition, contribution
  reconciliation, state authority logic, lineage interpretation,
  multi-device ontology execution.
- `runtime_state_flow.md` (deferred, post-resolver-implementation)
  — *how* state moves between the entities defined here.

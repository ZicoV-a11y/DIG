# Resolver Architecture (Design)

> **Status: DESIGN ONLY.** The resolver has not shipped. This
> document captures the conceptual constraints any future
> implementation must satisfy. Anything that violates the rules
> below is the wrong implementation; anything consistent with them
> is fair game for an implementation slice when the time comes.

The resolver is the composition engine for multi-device
operation: the layer that turns N Device Contributions into one
Global Library Graph. It does not exist yet — single-device
runtime collapses contribution onto operational truth — but
several pieces of the system already assume its conceptual shape
(see Phase 2 supersession, the trust-cycle slice, the boot
authority transition).

This doc derives directly from
[`system_ontology.md`](system_ontology.md) (terms) and
[`architectural_laws.md`](architectural_laws.md) (invariants).
Read those first if any term below feels unfamiliar.

Last revised: 2026-05-13.

---

## 1. What the resolver is

The resolver **composes Device Contributions into the Global
Library Graph**. It is a *projection*, not an *authority*.

Key properties:

- **Pure function over contributions.** Given the same set of
  contribution files, the resolver always produces the same
  output. No hidden state, no time-dependent branching.
- **In-memory derived view, not persisted authority.** The
  resolver's output is a snapshot the running app uses for
  display + querying. The truth lives in the contributions
  themselves (`Systems/`, `Shared Libraries/`); the composed
  view is regenerated from them.
- **Read-only over contributions.** The resolver never mutates a
  contribution file. Mutations happen in the device's own
  operational state (`Systems/{THIS_MACHINE}.library`) and flow
  outward via Saves/lineage and Shared Libraries/exchange.

What the resolver is **not**:

- Not a database. It owns no on-disk artifact.
- Not the live operational source. The running app's writes
  still go to `Systems/{MACHINE}.library` first.
- Not a sync engine. It reads contributions present on disk; it
  does not fetch them.
- Not a conflict-resolution policy authority. It surfaces
  conflicts (see §5); humans resolve them.

---

## 2. Inputs: Device Contributions

The resolver reads contribution files from two directories of
the LibraryRoot:

```
Music Tracker/
├── Systems/
│   ├── MACNEO.library          ← this device's contribution
│   ├── IPHONE.library          ← another device's contribution
│   └── IPAD.library            ← another device's contribution
└── Shared Libraries/
    ├── NEOMAC_LIBRARY__MACMINI__2026-MAY-12__09-15AM.library
    └── NEOMAC_LIBRARY__STUDIO__2026-MAY-12__14-30PM.library
```

Each `.library` file is a Device Contribution: one device's
perspective on the Library at the point of the file's last write.
The resolver treats `Systems/*.library` and
`Shared Libraries/*.library` identically — both contribute
INTO the Global Library Graph. The folders differ in *who is
writing* (live app vs. user-curated exchange), not in *what role
the file plays* for composition.

Note: `Saves/*.library` is **NOT** a resolver input. Saves are
this device's historical lineage — operational states the user
navigates between. They are never composed into the Global
Graph. (See [L6](architectural_laws.md#l6-saves-is-lineage-not-authority).)

### What a contribution carries

A contribution is a full database snapshot. From the resolver's
perspective, the relevant per-Track-Identity attributes are:

- **Identity links** (`identity_override` UUIDs)
- **Favorites** (boolean per Track Identity)
- **Play counts and cumulative listened time**
- **Last played at** (per Track Identity)
- **Review state** (the user's curatorial annotations)
- **Content-hash observations** (per File Instance — but
  Track Identity is the cross-device key, see §4)
- **File-availability observations** (per File Instance — but
  see §4 about why these stay device-local)

Each contribution carries its **machine_id** (from
`machine_id.txt`) implicitly via the filename, so every observation
in the composed graph is traceable back to its contributing device.

---

## 3. Outputs: the Global Library Graph

The Global Library Graph is the composed reality across all
Device Contributions. Conceptually:

```
Global Library Graph
├── Track Identity { song_id }
│     ├── attributes (favorites, plays, review state, …)
│     │     └── per-attribute composition rule (see §4)
│     ├── Media Representations
│     │     ├── MP3 — observed by [MACNEO, IPHONE]
│     │     └── AIFF — observed by [MACNEO]
│     └── Per-device File Instances
│           ├── MACNEO: /Users/.../song.mp3 (available)
│           ├── MACNEO: /Users/.../song.aiff (available)
│           └── IPHONE: /var/.../song.mp3 (available)
```

Two key properties:

- **Track Identity is the cross-device key.** It is the only
  layer the resolver merges *across* devices. Two devices that
  observe the same Track Identity (via the 4-field rule + override
  + content_hash signals — see ontology §3.5) compose their
  attributes into one record in the Global Graph.
- **File Instance is per-device, not cross-device.** Paths,
  source memberships, and availability are device-local. A
  device's `missing` is its observation, not a global state.
  The composed graph attributes file-instance observations to
  their contributing device rather than aggregating them.

---

## 4. Composition rules (per attribute)

All composition follows L5: **additive, never pick-newest.** No
attribute resolves by "the most recent observation wins" across
devices. Recency wins *within* a device's lineage (`Saves/`),
never across the resolver boundary.

### Favorites — union

If ANY contribution says a Track Identity is favorited, the
composed graph says it's favorited. A device that *unfavorited*
the track does not override another device's favorite. (Open
question §10: should explicit unfavorite events override
implicit not-favorite?)

### Play count + cumulative listened — sum, with device
attribution

`composed.play_count = Σ(per-device play_count)`. Same for
cumulative ms. Each device's contribution is preserved so the
graph can answer "how many times has *this device* played this?"
without losing the aggregate. Plays are inherently additive —
two devices playing the same song produces a higher cumulative
count, not a contested one.

### Last played at — MAX across devices, with attribution

The composed "last played" is the most recent across all
devices. This is recency-as-fact (which timestamp is largest),
not recency-as-authority (no contribution is overwritten). The
graph also retains per-device last-played so the History panel
can narrate "last played on IPHONE 2 hours ago."

### Identity links (`identity_override`) — transitive closure

If device A linked Track-X and Track-Y, and device B linked
Track-Y and Track-Z, the composed graph treats X, Y, Z as one
bucket. Identity links union into equivalence classes. Note: an
explicit *unlink* on one device does **not** dissolve another
device's link — unlinking is a per-device declaration, see
§5 conflict semantics.

### Review state — see open question

Review state is more complex than a single attribute (it's a
small state machine per track). Composition design deferred to
the implementation slice. Tentative principle: review *progress*
unions (any device's "reviewed" stands); review *demotion* (the
user un-reviews something) requires a deliberate cross-device
gesture.

### Content-hash observations — record all, conflict if divergent

Two devices observing the same Track Identity but different
content hashes is a real signal: the user's "Song A" on one
device has different bytes than "Song A" on another. The
composed graph records both observations and surfaces the
divergence as a conflict (§5). The resolver does NOT auto-pick.

### File availability — device-local, never composed

A row's `availability_state` is per-device by construction.
Device A having a `missing` row does not affect device B's view.
The composed graph keeps each device's File Instances under
that device's attribution.

### Phase 2 supersession decisions — per-device, never composed

Same reason as availability: supersession is per-device
lifecycle reasoning. The composed graph reads supersession
results as availability hints but does not propagate them.

---

## 5. Conflict semantics

A **conflict** is any composed state where two devices' attributes
disagree in a way the additive merge cannot resolve without losing
information. Conflicts are **always surfaced**, never silently
resolved. See
[L10](architectural_laws.md#l10-operational-state-ui-never-sounds-like-backup-software)
and the trust-design section of `ui_philosophy.md` — silent
merge is forbidden.

Conflict cases the resolver must surface:

- **Divergent identity_override.** Device A linked Track X to
  bucket {A,B,C}; device B linked X to bucket {X,Y,Z}. The
  transitive closure would either merge {A,B,C,X,Y,Z} (lossy if
  the user meant them distinct) or hold them apart (lossy if the
  user meant them merged). Surface as: "two devices link this
  song to different identity buckets — pick which is correct."
- **Divergent content_hash for the same Track Identity.** The
  user's "Song A" has different bytes across devices. Surface
  as: "two devices have different bytes for this song — likely
  re-encode, retag, or two different recordings; verify."
- **Favorite vs explicit unfavorite (deferred — see §10).**
  Pending design: does an explicit "unfavorite" event override
  an implicit "not favorited"?

Conflict surface rule: each conflict carries the contributing
devices' identifiers and timestamps so the user has the
information needed to choose. The resolver never picks for them.

---

## 6. Authority & precedence

The resolver has **no global authority hierarchy**. There is no
"master device", no "primary contribution", no "newest wins"
override.

Within a single device's lineage (`Saves/`), recency wins —
loading a more recent Save State sets that device's operational
truth. That's a *local* time ordering, not a global one.

Across devices, every contribution is equally authoritative for
its own observations. The Global Graph is the union of all
device perspectives; no perspective is privileged. (This is the
direct consequence of L4 and L5.)

---

## 7. Composition lifecycle

When does the resolver run? Two viable patterns; the design
constraint says either is allowed as long as the output is
treated as ephemeral:

### Pattern A: lazy projection on read

The Global Library Graph is computed every time the running app
needs a cross-device view (e.g. the History panel asks "all
plays across devices for this song"). Cheap if contributions
are small; needs careful caching as libraries grow.

### Pattern B: cached materialisation with explicit invalidation

The Global Library Graph is computed once at boot (or on
explicit "refresh"), held in memory, and invalidated when a
contribution file changes. The materialisation is still
**ephemeral** — never persisted, never written to disk. On
restart, the resolver recomputes from contributions.

### What is forbidden under both patterns

- **Persisting the composed graph as authoritative state.** The
  composed graph is always derivable; persisting it would create
  an authority drift opportunity (composed graph stale vs.
  contributions fresh). If caching is needed for performance,
  the cache lives in memory and is treated as advisory.
- **Mutating contributions from composition output.** The
  resolver never writes back to a `Systems/` or `Shared Libraries/`
  file. Mutations originate from the running app's own
  contribution channel.
- **Cross-device write paths.** The running app writes to
  `Systems/{THIS_MACHINE}.library` only. Other devices' files
  are read-only inputs.

---

## 8. Shared Libraries — exchange semantics

`Shared Libraries/` exists in the filesystem layout today as
scaffolding; no code consumes it. The design intent:

- A user **deliberately** drops a foreign device's contribution
  here (USB transfer, AirDrop, cloud sync, etc.). The placement
  is a user gesture, not an automatic pull.
- The resolver treats Shared Libraries entries as additional
  Device Contributions. The composition rules in §4 apply.
- Shared Libraries entries are **read-only** to this device. The
  running app never modifies them.
- Naming follows the Save State format
  (`{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library`) so the
  Finder-readable semantics hold. The user can see which
  contribution came from where, at what time.

The resolver does **not** define how Shared Libraries files
arrive or leave. That's a separate sync/exchange concern; the
filesystem boundary is the architecture's seam.

---

## 9. Open questions (intentionally unresolved)

The implementation slice should resolve these via empirical
iteration, not by guessing now.

### Q1. Favorite vs explicit unfavorite

If device A favorited a track and device B explicitly toggled
the favorite OFF, does the composed graph say favorited or not?
Treating union as "any favorite wins" loses the unfavorite
signal. Treating recency wins violates L5.

Tentative direction: track explicit *unfavorite events* separately
from "not favorited," and treat them as a per-Track-Identity
flag the user resolves manually.

### Q2. Review-state composition

Review state is a small state machine (unreviewed → reviewing →
reviewed, plus user tags). What is the right composition rule
when two devices have the track at different states?
Implementation will likely need a per-stage union plus an
explicit demotion handshake.

### Q3. Identity-link conflict policy

When two devices link the same Track Identity to incompatible
buckets, the resolver must surface the conflict. *How* the user
resolves it (a UI gesture; a per-device override; etc.) is
deferred. The resolver's contract: never auto-merge, never
auto-split.

### Q4. Composition trigger granularity

Does the resolver re-run on every Shared Libraries change, or
only on explicit refresh? File-watching the directory is the
obvious mechanism; throttling vs immediacy is the trade-off.

### Q5. Cumulative listened — sum or max?

For a Track Identity played 5 times on device A (cumulative 22
min) and 3 times on device B (cumulative 14 min), should
composed cumulative be 36 min (sum, factual aggregate) or 22 min
(max, defensive)? Sum is the natural read; max is safer if
device clocks drift or one device double-counts. Decision
deferred until real cross-device telemetry exists.

### Q6. Boot ordering with composition

Should the resolver run before the table is rendered, or should
the table render this device's `Systems/{MACHINE}.library` view
first and then "fold in" cross-device contributions? UX trade-off:
fast first paint vs. consistent first paint. Decide when the
implementation slice starts measuring.

---

## 10. What this design does NOT decide

- The on-disk format of contribution files (it remains the
  full `.library` SQLite snapshot for now).
- The wire format for Shared Libraries exchange (out of scope —
  filesystem boundary stays the architectural seam).
- The persistence layer for composed-graph cache (any cache is
  in-memory and ephemeral; on-disk caching is forbidden under
  the "never persist composed authority" rule).
- The UI for cross-device conflict resolution. That's a UI slice
  derived from §5's contract.
- Per-attribute schema changes that composition might require
  (e.g. an `unfavorited_at` column to disambiguate Q1). Those
  come with implementation.
- Real-time multi-device sync. The architecture deliberately
  treats device exchange as user-mediated (drop a file in
  Shared Libraries/, not "auto-pull from cloud").

---

## 11. Why this design ships now

The resolver isn't implemented and won't be soon. So why a doc?

**The contract stabilizes the surrounding system.** Several
already-shipped pieces depend implicitly on resolver constraints:

- The Phase 2 supersession rewrite is per-device, not
  cross-device. That's only safe if the resolver never reads
  supersession results as composed truth (§4 confirms).
- The boot authority transition made `Systems/` the live source.
  That's only coherent if the resolver treats `Systems/` files
  as contributions, not as "the library" (§1, §2 confirm).
- The Saves/-as-lineage framing (L6) is only sustainable if the
  resolver explicitly excludes Saves/ from composition inputs
  (§2 confirms).
- The operational-state UI language refuses "backup" semantics
  because Saves are navigable per-device lineage, not
  authoritative state. That framing only holds up if cross-device
  composition is a separate concept from per-device navigation
  (§7 confirms).

Without this doc, those decisions accumulate as **implicit**
assumptions about a not-yet-built resolver. Implicit assumptions
about future infrastructure are exactly the failure mode the
architecture-docs effort is meant to prevent. Writing the
contract now lets future implementation be derived, not
discovered.

---

## 12. Companion documents

- [`system_ontology.md`](system_ontology.md) — the conceptual
  model this design composes (Track Identity, Device
  Contribution, Global Library Graph, etc.).
- [`architectural_laws.md`](architectural_laws.md) — the
  invariants every resolver implementation must respect (L4, L5,
  L6 are the load-bearing ones here).
- [`ui_philosophy.md`](ui_philosophy.md) — the Operational Trust
  Boundaries §3 informs how conflict surfaces must render to the
  user.
- `runtime_state_flow.md` (still deferred) — once the resolver
  enters concrete design (the questions in §9 start to get
  answered), runtime flow becomes designable. The two docs
  ship together when that work begins.

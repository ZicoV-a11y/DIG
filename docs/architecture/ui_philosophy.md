# UI Philosophy

The surface derived from the ontology. This document captures
*how* Music Tracker presents itself to the user — language,
layout, sizing, and operational trust — and *why* those choices
follow from what the system *is*.

Read alongside:

- [`system_ontology.md`](system_ontology.md) — defines reality
  (entities, layers, conceptual rulings). The vocabulary used
  here is defined there.
- [`architectural_laws.md`](architectural_laws.md) — enforces
  reality. Several UI rules below are the user-facing surface
  of a law (notably
  [L10](architectural_laws.md#l10-operational-state-ui-never-sounds-like-backup-software)
  and
  [L11](architectural_laws.md#l11-every-workflow-action-is-a-controller-method)).

The UI is not styling on top of the architecture; **the UI *is*
the architecture made user-touchable.** Drift in the surface is
drift in the ontology.

Last revised: 2026-05-13.

---

## 1. Three-Zone Hierarchy

Music Tracker divides into three operational zones. They should
feel **distinct, related, calm, operational** — never like
dashboard panels.

```
┌──────────┬──────────────────────────────────────┐
│          │                                      │
│  Zone 1  │              Zone 2                  │
│  Library │           Track Workspace            │
│  /Nav    │  (search + table — the hero)         │
│          │                                      │
│  ──────  │  ──────────────────────────────      │
│          │              Zone 3                  │
│          │            Transport                 │
│          │       (playback deck)                │
└──────────┴──────────────────────────────────────┘
```

### Zone 1 — Library / Navigation (left rail)

Folder nav, library selection, watched folders. Persistent
navigation structure. Tone: slightly darker / calmer than the
workspace, restrained contrast, supportive and anchored. Subtle
edge separation — no heavy cards or shadows.

### Zone 2 — Track Workspace (centre, hero)

Search / filter strip + track table + digging surface. The table
is the hero — calm, scan-friendly, information-dense without
noise. Search belongs to the workspace surface, not the app
chrome. Dividers are subtle and consistent.

### Zone 3 — Transport / Playback (bottom)

Studio transport deck. Visually connects to the workspace but
distinct enough to read as a separate playback layer. Calmer
contrast transitions, central focus around the play button.

### Separation rules

- **4 px breathing margin on all sides** of each zone — both
  *inside* (gaps between zones) and *outside* (against window
  edges). Canvas (`AppColors.background`) shows in the gaps.
- **No rounded corners** on zone containers.
- **No border-line dividers** between zones. Tonal contrast +
  4 px gap is the separator.
- Dividers remain valid for *intra-zone* structure (column
  dividers in the table, etc.).

Implementation: `Padding(EdgeInsets.all(4))` around the Scaffold
body for the outer breathing room; `SizedBox(width/height: 4)`
between zones for the inner.

### What to avoid

Hard boxed panels, dashboard-card separation, thick borders,
bright separators, floating panels, heavy outlines, large
shadows, aggressive borders, visually noisy segmentation. The
target feel: a dedicated music-digging environment / studio
utility / nighttime listening surface — **never** a SaaS
dashboard, admin panel, or dev utility window.

---

## 2. Operational Language Guardrails

The vocabulary IS the architecture's psychological model made
user-readable. Drift in language is drift in ontology — see
[L10](architectural_laws.md#l10-operational-state-ui-never-sounds-like-backup-software).

### Forbidden words

Never appear in user-facing copy for state-navigation UI:

| ❌ | Why forbidden |
|---|---|
| **Backup** | Frames Saves as disaster artifacts (collapses Save ≠ backup). |
| **Restore / Restore from backup** | Frames load as recovery (collapses load ≠ recover). |
| **Snapshot** | Internal code may use the word; UI must not. |
| **Revert / Rollback** | Frames navigation as undoing damage. |
| **Import** | Reserved for the legacy `intelligence.json` flow. |

### Required language

`.library` files are **operational identity objects**. Selecting
one means *entering another operational reality*:

| ✅ | Used for |
|---|---|
| **Load operational state** | The action of selecting a `.library` |
| **Load this operational state** | The dialog's primary button (exact label) |
| **Switch library state** | Verb-form when narrating navigation |
| **Operational reality / Library reality** | The state the app is bound to |
| **Lineage point / Lineage state** | A `Saves/` entry |
| **Contribution channel / Device channel / Device state** | A `Systems/{MACHINE}.library` |
| **Current device state** | This device's live `Systems/` file |
| **Historical operational states** | The Saves/ chain |
| **Shared libraries** | `Shared Libraries/` entries |

### The Load dialog's section labels

The dialog separates `.library` sources into four sections, top
to bottom — each surfacing the ontology layer it represents:

1. **CURRENT DEVICE STATE** — `Systems/{THIS_MACHINE}.library`.
   "LIVE" pill. Hint: "The live library this device is running
   right now."
2. **OTHER DEVICE STATES** — `Systems/{OTHER}.library`. Hint:
   "Operational states from other devices in this library root."
3. **HISTORICAL OPERATIONAL STATES** — `Saves/*.library`. Hint:
   "Rolling lineage points from this device."
4. **SHARED LIBRARIES** — `Shared Libraries/*.library`. Hint:
   "Future cross-device exchange (coming soon)." Scaffolded;
   no load action yet.

### Visually sacred selection

The user-selected row is unmistakable:
- 3 px left-edge accent border (`AppColors.accent`).
- Selected machine ID uses heavier font weight than unselected.
- The right pane preview shows ONLY the selected state.
- The "Load this operational state" footer is the most
  prominent action — the user should feel "I am about to enter
  another library reality."

---

## 3. Operational Trust Boundaries

This is not UI styling. It's an **operational trust philosophy**
— the user's emotional contract with the app about how it
handles their music library.

The recurring pattern: choose **explicitness over magic**,
**visible lineage over hidden state**, **readable structure
over abstraction**, **recoverability over cleverness**,
**operational clarity over seamlessness**.

### The trust boundaries

- **Visible filesystem.** Every load-bearing piece of state
  lives at a Finder-readable path. `Systems/`, `Saves/`,
  `Shared Libraries/`, `machine_id.txt` — the user can open
  Finder and reason about the system without launching the
  app. (Derives from
  [L3](architectural_laws.md#l3-filesystem-layout-is-the-architecture).)

- **Readable naming.** Save filenames parse to
  `{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library` in plain
  text. The architecture is legible from the directory listing.
  Opaque IDs are reserved for derived artifacts (`Cache/`).

- **Explicit device identity.** `machine_id.txt` is plain text.
  Inspectable, editable, manually operable. The user can see
  *which device this is* without opening a DB. (Derives from
  [L1](architectural_laws.md#l1-device-identity-is-filesystem-level-not-db-resident).)

- **Lineage visibility.** Every autosave produces a readable
  `Saves/` entry. The user can navigate their own history in
  Finder. The app never hides past states.

- **Snapshot before swap.** Every Load Operational State action
  takes a *final autosave snapshot of the current state first*,
  so every transition is itself a recoverable lineage point.
  The user is never one click from losing their working state.

- **Manual restart before auto-reload.** Loading a different
  operational state prompts the user to quit (Cmd+Q) and
  relaunch. The manual step reinforces "I am entering another
  reality" psychologically — and avoids the systems problem of
  tearing down sqflite handles / playback / watchers /
  pending writes mid-flight. In-app reload is a later polish
  slice, gated on resolver maturity.

- **No hidden magic.** New persistence concepts must surface
  as a visible folder or filename pattern. Dotfiles, hidden
  state, or "this just works" infrastructure is a smell.

- **No silent resolver behavior.** When the resolver lands, its
  composition must be *visible* — what was merged, from where,
  with what conflicts. Silent merges are forbidden. (Derives
  from [L5](architectural_laws.md#l5-the-resolver-is-additive-never-pick-newest).)

- **No hidden merge destruction.** A pick-newest resolver would
  silently destroy a Contribution. The architecture forbids it
  at the law level; the UI must never imply it's happening
  either.

- **Operational-state language instead of backup language.**
  See §2. The vocabulary itself is a trust boundary — calling
  Saves "backups" tells the user "you're recovering from
  something broken," which is a false story about what's
  actually happening.

### Why trust matters here specifically

A DJ's library is years of curation, plays, favorites, review
state, and tagged work. The app *must* feel like it cannot
silently lose, merge, or overwrite that work. Every choice
above traces back to: *the user must be able to trust the app
with their music universe.* Drifting on any of these surfaces
the wrong story to the user — even if the underlying mechanics
are safe.

---

## 4. Keyboard-First & Surface-Agnostic Actions

Music Tracker is built for long sessions, momentum, spreadsheet-
like rhythm. Keyboard-first is the operational stance.

The architectural commitment: **every workflow action is a
controller method.** See
[L11](architectural_laws.md#l11-every-workflow-action-is-a-controller-method).
Stream Deck, MIDI, keyboard shortcuts, the UI, and any future
automation all reach the *same surface*. UI-only handlers fork
the contract and silently diverge.

### Surface principles

- A keystroke handler that calls `repo.*` directly (bypassing
  `LibraryController`) is a violation.
- A right-click menu item must invoke the same controller
  method as the corresponding keyboard shortcut.
- New actions: design the controller method first; bind it to
  surfaces second.

### Spreadsheet rhythm

Column resize, keyboard navigation, in-row editing, focus
preservation across data updates — the table should feel like
a spreadsheet, not a SaaS data grid. Momentum-preserving is
non-negotiable; the user is in flow.

---

## 5. Typography & Sizing

### Fluid typography

For text that should grow with available container width (Now
Playing title/subtitle, etc.), use **`LayoutBuilder` + linear
interpolation** between min/max sizes keyed on
`constraints.maxWidth`. The pattern:

```dart
LayoutBuilder(builder: (ctx, c) {
  double scale(double minSize, double maxSize) {
    const minW = 114.0;
    const maxW = 480.0;
    final w = c.maxWidth.clamp(minW, maxW);
    return minSize + (maxSize - minSize) * (w - minW) / (maxW - minW);
  }
  final titleSize = scale(13, 20);
  // ...
});
```

Don't reach for `FittedBox` (only scales DOWN, may distort
weight) or `auto_size_text` (extra dependency). For static text
or text in tight rows where scaling disrupts rhythm, use fixed
font sizes.

### Transport row proportions

The user-validated values after iteration ("PERFECT"):

| Element | Size |
|---|---|
| Skip buttons | 48 × 64 (narrower than tall, deliberate) |
| Prev / Next circle buttons | 48 × 64 (matches skip) |
| Play / Pause button | 80 × 80 (focal anchor, stays square) |
| Skip-to-skip gap | 10 px |
| Cluster boundary (last skip ↔ prev) | 18 px |
| Cluster internal (prev ↔ play ↔ next) | 6 px |
| Deck end-pads | 16 px |
| Deck inner gaps | 16 px |
| Skip count | 6 (no ±5; `−1m / −30 / −10` and `+10 / +30 / +1m`) |

Window minimum at this layout: **1180 px**.

Default to these values; don't square the skip / circle
buttons (the taller-than-wide ratio is intentional).

---

## 6. Forbidden Surface Patterns

The negative-space companion to the rest of this doc.
Patterns the UI must never accidentally adopt:

- **Dashboard cards** — boxed panels with shadows, radii,
  borders. Music Tracker is a workstation, not a CRM.
- **Floating panels** — every zone is anchored.
- **Hard dividers between zones** — tonal contrast + 4 px gap
  is the separator.
- **Backup-software language** — see §2.
- **Recovery / disaster framing** — the app's vocabulary frames
  navigation, not rescue.
- **Hidden infrastructure** — anything load-bearing surfaces in
  Finder.
- **Silent resolver / silent merges** — composition must be
  visible.
- **Per-surface implementations of the same action** — UI,
  keyboard, MIDI, Stream Deck all reach the same controller.

---

## 7. The compression test

> *If it reads slow or repetitive, it has failed the
> compression test.*

The same discipline applies to UI copy. Every label, hint, and
button has earned its place by being conceptually load-bearing.
Padding text (helper strings that re-explain what the row
already says) is the surface-level equivalent of a redundant
doc paragraph. Strip it.

---

## 8. Companion documents

- [`system_ontology.md`](system_ontology.md) — the canonical
  conceptual model this UI expresses.
- [`architectural_laws.md`](architectural_laws.md) — the
  invariants this UI must surface honestly.
- [`resolver_architecture.md`](resolver_architecture.md) (design
  only, no implementation yet) — the composition engine whose
  visibility this trust philosophy demands. The §5 conflict
  semantics there are the contract that future cross-device UI
  must honour.
- `runtime_state_flow.md` (deferred, post-resolver-implementation)
  — how operational state moves through the system; will inform
  future UI for composition / conflict surfaces.

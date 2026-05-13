# Architectural Laws

Stable, load-bearing invariants for Music Tracker. **Laws derive
from the ontology** — [`system_ontology.md`](system_ontology.md)
defines reality; this document enforces it. A law is the
detection surface for a forbidden ontology-collapse or a
forbidden authority drift; if reality is correctly modeled,
every law here is a *failure detector* for something the model
already says cannot be true.

Each law has three lines: the rule, why it exists, and the
invariant check — the observation that would catch a violation
in code review or runtime.

Laws are *conceptual* constraints. They don't replace tests; they
explain *which* tests are load-bearing and which class of bug a
test is preventing. When a future change feels architecturally
expensive, check whether it's because it's brushing up against a
law here. When a law itself feels wrong, the ontology is wrong —
fix the ontology first, then re-derive the law.

Last revised: 2026-05-13.

---

## Filesystem & Boot

### L1. Device identity is filesystem-level, not DB-resident.

- **Why:** Boot routing must not require opening a DB to learn
  which DB to open. The chicken-and-egg of resolving `machine_id`
  from `app_settings` would silently re-elevate `Current/` to
  authoritative.
- **Check:** `machine_id.txt` lives at the LibraryRoot. If boot
  ever calls `AppDatabase.open(...)` before reading it, the law
  is broken.

### L2. Operational continuity outranks legacy location continuity.

- **Why:** After the 2026-05-12 boot transition,
  `Systems/{MACHINE}.library` is the live operational source;
  `Current/CURRENT.library` is a compatibility mirror. Never
  overwrite newer Systems/ state with stale Current/.
- **Check:** Any code path that writes to `Current/` before
  `Systems/`, or treats `Current/` mtime as authoritative,
  violates the law.

### L3. Filesystem layout IS the architecture.

- **Why:** Visible folders + readable filenames (`Systems/`,
  `Saves/`, `Shared Libraries/`, `NEOMAC_LIBRARY__MACNEO__DATE__TIME.library`)
  let the user reason about the system in Finder without opening
  the app. No hidden infrastructure.
- **Check:** New persistence concepts surface as visible folder
  or filename patterns. Dotfiles, opaque IDs, or DB-hidden state
  for things the user is meant to navigate is a violation.

---

## Library Composition & Contribution

### L4. Devices contribute INTO the library, never AS the library.

- **Why:** `Systems/{DEVICE}.library` is one device's perspective
  on the user's music universe. The library itself is the
  composed reality across all device contributions — not any
  single file.
- **Check:** Any path that treats `Systems/{MACHINE}.library` as
  "the truth" rather than "this device's contribution" collapses
  the ontology back into master-device thinking. Watch for
  language drift in docs, comments, and UI copy.

### L5. The resolver is additive, never pick-newest.

- **Why:** Pick-newest silently destroys a contribution from
  another device. The library state must compose every device's
  view, not overwrite older ones.
- **Check:** When the resolver lands, no merge path should
  consult timestamps to choose a winner *across devices*. (Within
  a single device's lineage, recency is fine — that's Saves/, not
  resolver work.)

### L6. Saves/ is lineage, not authority.

- **Why:** Loading a Save is navigating to a prior operational
  state, not recovering from corruption. Saves are a readable
  archive; they do not author the running state.
- **Check:** Save filenames always parse as
  `{LIBRARY}__{MACHINE}__{DATE}__{TIME}.library`. The Load
  dialog uses "operational state" language, not "backup". Saves
  never auto-trigger application logic on read.

---

## Identity Model

### L7. Track Identity, Media Representation, and File Instance are independent layers.

- **Why:** Codec is a deliberate DJ routing choice (AIFF/WAV for
  home decks, MP3 for travel/USB drives). Bytes-identical files
  can be intentional duplicates (master + working copy +
  crate-export staging).
- **Check:** A code path that collapses two layers into one
  ("same `content_hash` → same song" / "same song → can replace
  the file") is a violation. The three layers must each be
  separately mutable and separately queryable.

### L8. `identity_override` mutations propagate across ALL 4-field-matched siblings.

- **Why:** Asymmetric override state (one row has it, one is
  NULL) makes `sameSongIdentity` drop the NULL row from the
  bucket — sibling silently vanishes from the UI. Copy used to
  do this; the heal pass exists to repair pre-fix data.
- **Check:** Any write that stamps `identity_override` on a row
  without sweeping its 4-field siblings creates orphans. The
  hydrate-time `healOrphanedIdentitySiblings` is the safety
  net; new write paths must not require it.

### L9. Auto-supersession requires ALL FOUR conditions, not `content_hash` alone.

- **Why:** DJs duplicate files intentionally. A `content_hash`
  match alone is never sufficient evidence for "moved" — it
  could be a working copy, a crate export, a backup restore, a
  re-download. Auto-merging would silently hide files.
- **Check:** A supersession rule must check `missing` +
  `uniqueness` + `temporal-after` + `small-overlap`. If any of
  the four is skipped, the rule is too lax. (Today
  `markMovedSupersessions` is too lax; it's acceptable in Phase
  1 soak but must be rewritten before Phase 2.)

---

## UI & Surface

### L10. Operational state UI never sounds like backup software.

- **Why:** Saves are operational states the user navigates
  between. "Restore from backup" frames them as disaster
  recovery, which collapses the contribution / lineage / live
  ontology into a single linear timeline.
- **Check:** Words that NEVER ship to the user: *backup,
  restore, snapshot, revert, import.* Words that DO ship:
  *load operational state, switch library state, lineage,
  Saves, Systems, Shared Libraries.*

### L11. Every workflow action is a controller method.

- **Why:** Stream Deck, MIDI, keyboard shortcuts, the UI, and
  any future automation must all reach the same surface. UI-only
  handlers fork the contract and silently diverge.
- **Check:** A keystroke handler or UI callback that calls
  `repo.*` directly (bypassing `LibraryController`) is a
  violation. The action belongs on the controller.

---

## Persistence Boundaries

### L12. Two persistence worlds coexist intentionally — do not merge them yet.

- **Why:** `.library` (full operational-state DB snapshot) and
  `intelligence.json` (utility-rail Save/Export from before the
  save-system slice) serve different exchange semantics. The
  shape of Shared Libraries exchange will determine the right
  way to unify them; premature merging locks in wrong
  assumptions.
- **Check:** Auto-converting one format into the other, or
  loading one through the other's pipeline, is a violation
  until the Shared Libraries slice consciously decides the
  unification rule.

---

## How to use this document

- New slice → scan this list once. If the slice touches any
  layer mentioned here, the relevant law is the test the slice
  must survive.
- Reviewing a change → ask "which law would this violate?" If
  the answer is "none, but it feels off" — the law is missing,
  not the change. Add it.
- Memory drift → if a memory note contradicts a law here, this
  document wins. Update the memory note, not the law.
- Laws can be revised, but only deliberately. A revision should
  carry the date and the slice that prompted it (see L2's
  reference to the 2026-05-12 boot transition).

## Companion documents

- [`system_ontology.md`](system_ontology.md) — the canonical
  conceptual model. Every law here derives from a concept
  defined there. **The ontology is primary; the laws enforce
  it.**
- `ui_philosophy.md` — the surface derived from the ontology
  (operational-state language, three-zone hierarchy,
  Operational Trust Boundaries).
- [`resolver_architecture.md`](resolver_architecture.md) (design
  only, no implementation yet) — graph composition, contribution
  reconciliation, multi-device ontology execution. L4, L5, L6
  are the load-bearing laws there.
- `runtime_state_flow.md` (deferred, post-resolver-implementation)
  — how operational state moves through the system.

# Design: Native Tree-Style Tabs + Middle-Mouse Drag-Select for Zen

**Date:** 2026-06-04
**Status:** Approved (design); implementation plan pending
**Scope:** Two related tab-strip interaction features implemented natively in Zen's chrome code.

## 1. Overview & approach

Two native features, both implemented in Zen's chrome code (no Sidebery dependency):

- **Feature A — Tree-style tabs:** any unpinned tab can be a *parent* of other unpinned
  tabs. The parent stays a real, clickable tab; children indent beneath it with a collapse
  twisty. Built as a flat tab list with parent-pointers (the Tree Style Tabs / Sidebery
  model), *not* by wrapping tabs in folder/group containers.
- **Feature B — Middle-mouse drag-select:** middle-drag rubber-bands a contiguous range of
  tabs; releasing middle closes them; right-clicking while middle is still held aborts the
  close and opens the context menu on the selection.

### Why flat-list-with-parent-pointers, not the existing folder system

Zen folders (`nsZenFolder extends MozTabbrowserTabGroup`, `src/zen/folders/`) are *container*
elements: they render a separate header row and hold member tabs. Reusing them for tree tabs
would produce a "folder-on-drop" model where the parent is a header line, not a tab — which
is explicitly not what we want.

To make the parent *be a tab*, the hierarchy must live as a relationship between tab elements,
with the tab strip kept in depth-first order. This is the only model that yields a true
tab-as-parent tree. We reuse the folder system's *machinery* (the `--zen-folder-indent`
variable, collapse animation patterns, sessionstore persistence approach) without reusing its
container structure.

### Decisions captured from brainstorming

- Native implementation (Sidebery is not used).
- Tab-as-parent model (parent stays a clickable tab).
- Opener-based auto-nesting, behind a pref defaulting ON.
- Drag gestures: quick-drop-on-tab nests; hold (~300ms) escalates to split; gaps reorder.
- Close-parent behavior is a pref; default is "promote children".
- Scope is unpinned tabs only; pinned tabs keep the existing folder system, unchanged.
- Middle-mouse drag-select: contiguous range; release closes; right-click-while-held aborts
  the close and opens the context menu; clean middle-click still closes a single tab; new
  drag replaces prior selection (Ctrl to add).
- `max-depth` default = 4.

## 2. Component map

### New files

- `src/zen/tab-tree/ZenTabTree.mjs` (`gZenTabTree`) — tree state manager: parent/child model,
  DFS ordering invariant, collapse, open/close/pin hooks, opener auto-nest, persistence.
- `src/zen/tab-tree/zen-tab-tree.css` — collapse twisty on parent tabs, indentation,
  collapsed-subtree hiding, the "nest" drop indicator.
- `src/zen/tab-tree/ZenTabMultiSelectDrag.mjs` (`gZenTabMultiSelectDrag`) — the middle-mouse
  gesture state machine (Feature B).
- `prefs/zen/tab-tree.yaml` — new prefs (see §7).
- `src/zen/tests/tab-tree/` — mochitest browser tests, mirroring `src/zen/tests/folders/`.

### Modified files

- `src/zen/drag-and-drop/ZenDragAndDrop.js` — add a `#dragOverNest` machine alongside the
  existing `#dragOverSplit`; wire nest detection, the escalate-to-split timer, and the drop
  branch.
- `src/zen/sessionstore/ZenSessionManager.sys.mjs` — serialize/restore per-tab tree state.
- `src/zen/ZenComponents.manifest`, the relevant `jar.inc.mn` / `moz.build` — register the new
  components.
- Tab indentation already flows through `--zen-folder-indent` (applied to `.tabbrowser-tab` in
  `src/zen/tabs/zen-tabs/vertical-tabs.css:327`), so it is reused rather than reinvented.

### Existing mechanisms reused (file:line anchors)

- Drag-over-split machine: `#handle_tabDragOverToSplit` (`ZenDragAndDrop.js:762`),
  `#createFakeTabSplit` (`:848`), `_clearDragOverSplit` (`:869`), `#handle_dropCreateSplit`
  (`:992`), which calls `gZenViewSplitter.splitTabs()` (`ZenViewSplitter.mjs:1386`).
- Split prefs as a template: `zen.splitView.enable-drag-over-split`,
  `zen.splitView.drag-over-split-threshold`, `zen.splitView.drag-over-split-delayMC`
  (`ZenDragAndDrop.js:85-102`).
- Indentation calc precedent: `setFolderIndentation` (`ZenFolders.mjs:999`), 14px/level.
- Persistence precedent: folder serialize/restore with `parentId` + `prevSiblingInfo`
  (`ZenFolders.mjs:1142-1320`).
- Workspace scoping: tabs carry `zen-workspace-id`; normal tabs live in
  `.zen-workspace-normal-tabs-section` (`src/zen/spaces/ZenSpace.mjs`).

## 3. Tree data model (Feature A)

Per-tab state, held as element properties and persisted as custom tab values:

- `_zenTreeParent` → parent tab element (or null). Persisted as `zen-tree-parent` = parent's
  stable id.
- `_zenTreeLevel` → cached depth (0 = root).
- `_zenTreeCollapsed` → whether this tab's *subtree* is collapsed. Persisted as
  `zen-tree-collapsed`.

Children are not stored as a list; they are derived from DOM order + parent pointers. The
manager always maintains four invariants:

1. **DFS order** — within a workspace's normal-tabs container, DOM order equals a pre-order
   traversal of the forest, so a tab's descendants are contiguous and immediately follow it.
2. **Level** — `level(child) = level(parent) + 1`; roots are level 0.
3. **Indent** — `--zen-folder-indent = level × zen.tab-tree.indent` (default 14px), with depth
   capped at `zen.tab-tree.max-depth` (default 4).
4. **Collapse** — descendants of a collapsed tab carry `zen-tree-hidden` and are hidden via CSS.

Maintaining the DFS invariant on every move/open/close is the core complexity. All tree
mutations funnel through `gZenTabTree` so ordering cannot drift; the manager also observes
`TabMove` to repair any externally-induced reordering.

### Manager API (sketch)

- `nestTab(child, parent, { position })` — set parent; move child + its subtree to be
  contiguous after the parent's existing children; recompute levels/indent; persist.
- `detachTab(tab)` / `promoteSubtree(tab)` — make a tab a root or reparent it to its
  grandparent.
- `getChildren(tab)`, `getDescendants(tab)`, `getSubtreeRange(tab)`.
- `toggleCollapse(tab)` — flip collapsed; hide/show descendants (animated); if the active tab
  would be hidden, select the nearest visible ancestor.
- `onTabOpen(tab)` — opener auto-nest.
- `onTabClose(tab)` — promote children or close subtree per pref.
- `onTabMove(tab)` — re-derive parent from drop position and repair the DFS invariant.
- `onPin(tab)` — detach from tree (tree is unpinned-only).
- `serialize()` / `restore(state)`.

## 4. Tree interactions (Feature A)

### Drag gestures (extend `ZenDragAndDrop.js`)

A new `#dragOverNest` machine mirrors `#dragOverSplit`:

- **Drop on a tab's central body (quick)** → nest as child. Shows an indented drop line under
  the target; sets `#dragOverNest.canDrop = true` immediately (no delay).
- **Keep hovering ~300ms** (`zen.tab-tree.drag-nest-to-split-delayMC`) → escalates: the nest
  indicator clears, the existing `zen-split-fake-tab` appears, and split takes over (the
  current behavior, now reused as the "hold" tier).
- **Drop in the gap (top/bottom edge zone)** → reorder as sibling via the existing
  `_animateTabMove` path, keeping the current parent.
- On `handle_drop`: if `#dragOverSplit.canDrop` → split (existing `#handle_dropCreateSplit`);
  else if `#dragOverNest.canDrop` → `gZenTabTree.nestTab(draggedTab, targetTab)`; else →
  reorder (existing).
- A multi-selection dragged onto a tab nests all selected tabs as children.
- Excluded from nesting (mirroring split exclusions): essentials (`zen-essential`), glance
  (`zen-glance-tab`), empty (`zen-empty-tab`), split-view groups (`split-view-group`), live
  folders (`zen-live-folder-item-id`), and pinned tabs.

### Collapse

A twisty appears on any tab that has children; clicking it toggles `_zenTreeCollapsed` and
animates descendants hidden/shown. If the active tab is inside a subtree being collapsed,
selection moves to the nearest visible ancestor. Styling reuses the folder twisty CSS
(`zen-folders.css` triangle states) adapted to tabs.

### Opener auto-nest

Behind `zen.tab-tree.auto-nest-by-opener` (default on): a tab opened from another unpinned tab
(link-in-new-tab, middle/ctrl-click, "open in new tab") is auto-nested as that tab's child,
inserted as its last child. Uses Firefox's existing `openerTab`/owner relationship. This
mirrors the existing `zen.folders.owned-tabs-in-folder` pattern.

## 5. Tree lifecycle (Feature A)

- **Close a parent** (`zen.tab-tree.close-parent-behavior`, default `promote`):
  - `promote` — children re-parent up to the grandparent (or root); nothing is lost.
  - `close-subtree` — close all descendants too, with undo support.
- **Reorder** — sibling moves keep the parent; a move landing inside another tab's body
  changes the parent.
- **Pin** — pinning a tree tab detaches it (promotes its children), since the tree is
  unpinned-only. Pinned tabs keep using the existing folder system, untouched.
- **Persistence** — per-tab `zen-tree-parent` + `zen-tree-collapsed` serialized via
  `ZenSessionManager`. Restore is a two-pass process like folders' `parentId` restore: build
  tabs, rebuild parent links, then re-apply DFS order / levels / indent / collapse.
- **Window sync** — `ZenWindowSync` must carry the same tree state. Flagged as a correctness
  hotspot given recent churn there (e.g., gh-13027).

## 6. Middle-mouse drag-select (Feature B)

A gesture state machine bound to the tab strip (`#tabbrowser-tabs` / arrowscrollbox), behind
`zen.tabs.middle-drag-select.enabled` (default on):

1. **Middle mousedown on a tab** — record the anchor tab + start position; suppress autoscroll
   and Linux middle-paste for the duration.
2. **Move past ~4px threshold** — enter drag-select; select the contiguous *visible* range from
   the anchor to the tab under the cursor (set `multiselected`), replacing prior selection
   (hold Ctrl/Cmd to add to it). Selected tabs show a "pending close" hint. Live-updates as the
   cursor moves.
3. **Right-click while middle still held** — abort: stop selecting, open the multiselect tab
   context menu on the current selection, and mark the gesture so the eventual middle-release
   does nothing.
4. **Middle mouseup** — if not aborted, close the whole selection (`gBrowser.removeTabs`,
   animated, undoable); else no-op. Clear state.
5. **Clean middle-click, no drag** — falls through to the normal single-tab close (unchanged);
   the gesture only takes over once the movement threshold is crossed.

Safety nets: Firefox's undo-close-tab plus the right-click escape hatch.

## 7. Prefs

| Pref | Default | Purpose |
|---|---|---|
| `zen.tab-tree.enabled` | true | Master switch for tree tabs |
| `zen.tab-tree.auto-nest-by-opener` | true | New tabs nest under their opener |
| `zen.tab-tree.close-parent-behavior` | `promote` | `promote` \| `close-subtree` |
| `zen.tab-tree.indent` | 14 | px per nesting level |
| `zen.tab-tree.max-depth` | 4 | nesting cap (0 = unlimited) |
| `zen.tab-tree.drag-nest-to-split-delayMC` | 300 | hold time before nest→split escalation |
| `zen.tabs.middle-drag-select.enabled` | true | Feature B master switch |

## 8. Testing

Mochitest browser tests mirroring `src/zen/tests/folders/`:

- **Tree:** nest-by-drag; depth/level checks; `max-depth` cap; collapse hides descendants;
  promote-vs-close-subtree on parent close; opener auto-nest; reorder keeps vs changes parent;
  pin detaches; persistence across restart; split escalation still fires after the hold;
  exclusions (essential / glance / empty / split-group / live-folder / pinned).
- **Middle-mouse drag-select:** range select; release closes; right-click aborts and opens
  context menu; clean middle-click closes one; Ctrl additive; movement threshold respected.

## 9. Key risks

- **DFS-ordering invariant** is make-or-break — centralize all moves through the manager and
  observe `TabMove` to repair drift.
- **Three-way drag zones** (reorder / nest / split) must feel unambiguous — tuned thresholds +
  distinct indicators, all pref-gated.
- **Session restore + window sync** for tree state is the area most likely to harbor subtle
  bugs (recent commits touched exactly this code).
- **Middle-button defaults** (autoscroll, Linux paste, single middle-click-close) must survive
  the non-drag case.

## 10. Default decisions (changeable)

- `max-depth = 4`.
- Nesting a multi-selection nests all selected tabs.
- Pinning a tree tab detaches it (promotes its children).
- Collapsing moves selection to the nearest visible ancestor.
- New components live under `src/zen/tab-tree/`.

# Declarative managed spaces

## Why

Space Routing's managed routes (`zen.space-routing.managed-routes`) let dotfiles
declare routing rules that target a Space **by name**. But the Spaces themselves
still have to be created by hand in the UI — and a Space is referenced internally
by a random per-profile `uuid`, so it can't be expressed in config. If the named
Space doesn't exist, a managed route's `openInSpace` can't resolve.

This adds the missing half: declare the **Spaces** themselves from a managed
preference, keyed by name, so a full setup (Spaces + routes) is deterministic
from a Nix / home-manager dotfiles config, exactly like the Containerise model
referenced by the managed-routes work.

## What

A new string pref **`zen.space-routing.managed-spaces`** holds a JSON array of
Space definitions (an object form `{ "spaces": [ … ] }` is also accepted, to
match managed-routes). It pairs with `managed-routes` so all declarative Space
config lives in one namespace.

```jsonc
[
  // create a Space named "Work" using the built-in briefcase icon and the
  // "Work" container, first in the list
  { "name": "Work", "icon": "briefcase", "container": "Work", "position": 0 },
  // icon may be an emoji; container/position are optional
  { "name": "Personal", "icon": "🏠", "position": 1 }
]
```

### Entry schema

| field | required | meaning |
| --- | --- | --- |
| `name` | yes | The Space name and the stable key. Entries with an empty/missing name are skipped. |
| `icon` | no | An emoji (kept as-is); a bare icon name or `*.svg` (e.g. `"briefcase"`) expanded to `chrome://browser/skin/zen-icons/selectable/<name>.svg`; or a full chrome URL (kept as-is). |
| `container` | no | A container referenced by its label, resolved to a `userContextId` via `ContextualIdentityService.getPublicIdentities()`. An unknown name resolves to `0` (no container). Containers are never created here — Containerise / Firefox owns those. |
| `position` | no | Ordering index; falls back to the entry's index in the array. |

A `userContextId` number is also accepted for `container` directly, for parity
with how routes accept a literal id.

### Behavior

Managed spaces follow the same philosophy as managed routes — configuration is
the deterministic source of truth — adapted for the fact that a Space owns tabs,
a container, and bookmarks:

- **Ensure-exists + sync, never delete.** On reconcile: a managed name with no
  matching Space is **created**; an existing Space with that name has its
  `icon` / `containerTabId` / `position` **updated** to match config; a Space
  whose entry was removed from config is **left untouched** (never auto-deleted,
  so tabs are never lost).
- **Read-only in the UI.** A managed Space's name/icon/container can't be edited
  or deleted from the Space menu (controls greyed, with a "managed by your
  configuration" hint), mirroring how managed routes render read-only — so a
  Space the user didn't create by hand still has a visible explanation.
- **Robust.** A JSON parse error or unexpected shape yields no managed spaces
  (logged), so a bad pref can't break startup or Space switching.

Reconciliation runs **once after `gZenWorkspaces` finishes initializing** and
**before** any routing resolves Space names, so a managed route's `openInSpace`
always finds its Space.

## Architecture

A new `ZenManagedSpaces` module in `src/zen/space-routing/`, sibling to
`ZenSpaceRoutingManager`, owns parsing and reconciliation. It is the only new
unit; it delegates all Space mutation to the existing `gZenWorkspaces` API and
container lookup to `ContextualIdentityService`.

**`ZenManagedSpaces` (`src/zen/space-routing/ZenManagedSpaces.sys.mjs`)**
- `getManagedSpaces()` — memoized parse + normalize of the pref, re-parsed only
  when the raw value changes (lazy pref getter), identical in spirit to
  `ZenSpaceRoutingManager.getManagedRoutes()`.
- `#parseManagedSpaces(raw)` — JSON parse → array (or `{spaces}`), drop entries
  without a usable `name`, normalize `icon` (emoji vs `selectable/<name>.svg`
  URL), keep `container` and `position` as given. Errors → `[]` (logged).
- `#resolveContainer(name)` — label/userContextId → `userContextId` via
  `ContextualIdentityService.getPublicIdentities()`; unknown → `0`.
- `reconcile(win)` — for each managed entry, find a Space by name in
  `win.gZenWorkspaces`; create via `createAndSaveWorkspace(name, icon,
  /*dontChange*/ true, containerTabId)` or update `icon`/`containerTabId`/
  position on the existing one and `saveWorkspace(...)`; record managed names so
  the UI can mark them read-only.
- `isManaged(name)` — used by the Space UI to gate editing/deletion.

**Integration points**
- `gZenWorkspaces` init calls `gZenManagedSpaces.reconcile(window)` after its
  workspaces are loaded (one hook).
- The Space context/edit menu consults `gZenManagedSpaces.isManaged(space.name)`
  to disable rename / icon / container / delete for managed Spaces.

Unchanged: `ZenSpaceRoutingManager` (managed routes already resolve
`openInSpace` by name through `gZenWorkspaces`, so once the named Spaces exist
the existing path just works).

## Data flow

```
pref zen.space-routing.managed-spaces (JSON)
        │  getManagedSpaces() (parse + normalize, memoized)
        ▼
[{name, icon(url|emoji), containerTabId, position}, …]
        │  reconcile(win) after gZenWorkspaces init
        ▼
gZenWorkspaces: create missing / update existing (never delete)
        │  managed names recorded
        ▼
Space UI: isManaged(name) → read-only
managed routes: openInSpace name now always resolves
```

## Error handling

- Unparseable / wrong-shape pref → `[]`, logged, no throw (same guarantee as
  managed-routes).
- Entry missing `name` → skipped.
- Unknown `container` name → `0` (no container), not an error.
- Reconcile failures on a single entry are caught and logged so one bad entry
  can't block the rest or startup.

## Testing

`src/zen/tests/space_routing/` (browser-chrome), using a pushed
`zen.space-routing.managed-spaces` pref:
- creates a Space for a managed name that doesn't exist, with the resolved icon
  URL and `containerTabId`;
- syncs `icon`/`container`/`position` onto an existing same-named Space instead
  of creating a duplicate;
- leaves a Space in place when its entry is removed from config (no delete);
- a malformed pref produces no managed spaces and doesn't throw;
- `container` name resolves to the matching `userContextId`; an unknown name → 0;
- `isManaged(name)` is true for managed Spaces and false for user-created ones.

## Out of scope

- Creating containers (Containerise / Firefox owns those).
- Theme / gradient configuration (defaults / user-set for now).
- Deleting Spaces from config removal.

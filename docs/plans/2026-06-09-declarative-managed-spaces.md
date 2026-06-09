# Declarative Managed Spaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let dotfiles declare Spaces (name, icon, container, order) from a managed pref, so a full Space-Routing setup (Spaces + routes) is deterministic from config.

**Architecture:** A new `ZenManagedSpaces` sys.mjs singleton (sibling to `ZenSpaceRoutingManager`) parses `zen.space-routing.managed-spaces`, and `reconcile(win)` runs after `gZenWorkspaces` init to create-or-update Spaces by name via the existing `gZenWorkspaces.saveWorkspace(...)` (which materializes the UI through `propagateWorkspaces`). It never deletes. Managed Spaces are read-only in the Space menu.

**Tech Stack:** Firefox/Zen privileged JS (ES modules / sys.mjs), `ContextualIdentityService`, browser-chrome mochitests, surfer build (`./mach build faster`).

Design spec: `docs/plans/2026-06-09-declarative-managed-spaces-design.md`.

---

## File structure

| File | Responsibility | Action |
| --- | --- | --- |
| `src/zen/space-routing/ZenManagedSpaces.sys.mjs` | Parse the pref, resolve icon/container, `reconcile(win)`, `isManaged(name)` | Create |
| `src/zen/space-routing/moz.build` | Package the new module | Modify |
| `src/zen/common/ZenPreloadedScripts.js` | Expose `gZenManagedSpaces` as a window global | Modify |
| `prefs/zen/space-routing.yaml` | Default the new pref to `""` | Modify |
| `src/zen/spaces/ZenSpaceManager.mjs` | Call `reconcile` after init; gate delete/rename for managed Spaces | Modify |
| `src/zen/tests/space_routing/head.js` | Import `gZenManagedSpaces`; helper to set/clear the pref | Modify |
| `src/zen/tests/space_routing/browser.toml` | Register the new test file | Modify |
| `src/zen/tests/space_routing/browser_managed_spaces.js` | Tests | Create |

Build/test commands (run inside `devenv shell --`):
- Build front-end: `cd engine && ./mach build faster`
- Run these tests: `npm test -- space_routing/browser_managed_spaces.js --headless`
- Syntax check a module: `node --check <path>`

---

## Task 1: Scaffold `ZenManagedSpaces`, register it, parse the pref

**Files:**
- Create: `src/zen/space-routing/ZenManagedSpaces.sys.mjs`
- Modify: `src/zen/space-routing/moz.build`
- Modify: `src/zen/common/ZenPreloadedScripts.js:8-11`
- Modify: `prefs/zen/space-routing.yaml` (append)
- Modify: `src/zen/tests/space_routing/head.js:6-8`
- Modify: `src/zen/tests/space_routing/browser.toml`
- Test: `src/zen/tests/space_routing/browser_managed_spaces.js`

- [ ] **Step 1: Create the module with the pref getter, parse, and icon resolution**

Create `src/zen/space-routing/ZenManagedSpaces.sys.mjs`:

```js
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import { ContextualIdentityService } from "resource://gre/modules/ContextualIdentityService.sys.mjs";
import { XPCOMUtils } from "resource://gre/modules/XPCOMUtils.sys.mjs";

const lazy = {};

// Spaces seeded from configuration (a declarative dotfiles setup, an enterprise
// policy, …). The pref holds a JSON array of Space definitions; see
// getManagedSpaces() for the accepted shape. Live-updating so a changed pref is
// picked up without a restart.
XPCOMUtils.defineLazyPreferenceGetter(
  lazy,
  "managedSpacesJSON",
  "zen.space-routing.managed-spaces",
  ""
);

// Built-in selectable Space icons live here; see gZenEmojiPicker.getSVGURL().
const SELECTABLE_ICON_BASE = "chrome://browser/skin/zen-icons/selectable/";

class nsZenManagedSpaces {
  // Memoized parse of the managed-spaces pref. Re-parsed only when the raw pref
  // string changes.
  #managedSpacesRaw = null;
  #managedSpaces = [];
  #managedNames = new Set();

  /**
   * Parsed + normalized managed spaces. Accepted pref shape:
   *
   *   [ { "name": "Work", "icon": "briefcase",
   *       "container": "Work", "position": 0 }, … ]
   *
   * (an object `{ "spaces": [ … ] }` is also accepted). Each normalized entry is
   *   { name, icon, container, position }
   * where `icon` is an emoji kept as-is, or a chrome URL resolved from a bare
   * icon name / `*.svg`; `container` is the raw name or userContextId (resolved
   * at reconcile time); `position` is the entry's intended order.
   *
   * Invalid input never throws: a parse error or unexpected shape yields an
   * empty list (logged), so a malformed pref can't break startup.
   *
   * @returns {Array<object>}
   */
  getManagedSpaces() {
    const raw = lazy.managedSpacesJSON;
    if (raw === this.#managedSpacesRaw) {
      return this.#managedSpaces;
    }
    this.#managedSpacesRaw = raw;
    this.#managedSpaces = this.#parseManagedSpaces(raw);
    this.#managedNames = new Set(this.#managedSpaces.map(s => s.name));
    return this.#managedSpaces;
  }

  /**
   * @param {string} name
   * @returns {boolean} Whether a Space with this name is config-managed.
   */
  isManaged(name) {
    this.getManagedSpaces();
    return this.#managedNames.has(name);
  }

  #parseManagedSpaces(raw) {
    if (typeof raw !== "string" || raw.trim() === "") {
      return [];
    }

    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      console.error(
        "[ZenManagedSpaces] Could not parse zen.space-routing.managed-spaces:",
        e
      );
      return [];
    }

    const list = Array.isArray(parsed) ? parsed : parsed?.spaces;
    if (!Array.isArray(list)) {
      console.error(
        "[ZenManagedSpaces] zen.space-routing.managed-spaces must be a JSON " +
          "array of spaces, or an object with a `spaces` array."
      );
      return [];
    }

    const spaces = [];
    for (let index = 0; index < list.length; index++) {
      const entry = list[index];
      if (!entry || typeof entry.name !== "string" || entry.name.trim() === "") {
        continue;
      }
      spaces.push({
        name: entry.name.trim(),
        icon: this.#resolveIcon(entry.icon),
        container: entry.container ?? null,
        position: Number.isInteger(entry.position) ? entry.position : index,
      });
    }
    return spaces;
  }

  /**
   * Normalizes an icon value: emoji / arbitrary text kept as-is; a full chrome
   * (or moz-icon/data) URL kept as-is; a bare icon name or `*.svg` expanded to
   * the selectable-icon chrome URL.
   *
   * @param {*} icon
   * @returns {string|undefined}
   */
  #resolveIcon(icon) {
    if (typeof icon !== "string" || icon.trim() === "") {
      return undefined;
    }
    const value = icon.trim();
    if (
      value.startsWith("chrome://") ||
      value.startsWith("moz-icon:") ||
      value.startsWith("data:")
    ) {
      return value;
    }
    if (value.endsWith(".svg")) {
      return SELECTABLE_ICON_BASE + value;
    }
    // A bare slug like "briefcase" is a built-in icon name; anything else (an
    // emoji, free text) is used verbatim.
    if (/^[a-z0-9][a-z0-9-]*$/i.test(value)) {
      return SELECTABLE_ICON_BASE + value + ".svg";
    }
    return value;
  }
}

export const gZenManagedSpaces = new nsZenManagedSpaces();
```

- [ ] **Step 2: Package the module**

In `src/zen/space-routing/moz.build`, add the module to the existing array:

```python
EXTRA_JS_MODULES.zen.spacerouting += [
    "ZenManagedSpaces.sys.mjs",
    "ZenSpaceRoutingDialog.mjs",
    "ZenSpaceRoutingManager.sys.mjs",
]
```

- [ ] **Step 3: Expose it as a window global**

In `src/zen/common/ZenPreloadedScripts.js`, extend the `defineESModuleGetters` block (currently only `gZenSpaceRoutingManager`):

```js
  ChromeUtils.defineESModuleGetters(this, {
    gZenManagedSpaces:
      "resource:///modules/zen/spacerouting/ZenManagedSpaces.sys.mjs",
    gZenSpaceRoutingManager:
      "resource:///modules/zen/spacerouting/ZenSpaceRoutingManager.sys.mjs",
  });
```

- [ ] **Step 4: Default the pref**

Append to `prefs/zen/space-routing.yaml`:

```yaml
- name: zen.space-routing.managed-spaces
  value: "" # JSON array of declarative Spaces; see ZenManagedSpaces
```

- [ ] **Step 5: Import the manager in the test head**

In `src/zen/tests/space_routing/head.js`, after the existing import, add:

```js
const { gZenManagedSpaces } = ChromeUtils.importESModule(
  "resource:///modules/zen/spacerouting/ZenManagedSpaces.sys.mjs"
);

async function withManagedSpaces(json, fn) {
  await SpecialPowers.pushPrefEnv({
    set: [["zen.space-routing.managed-spaces", JSON.stringify(json)]],
  });
  try {
    await fn();
  } finally {
    await SpecialPowers.popPrefEnv();
  }
}
```

- [ ] **Step 6: Write the failing parse test**

Create `src/zen/tests/space_routing/browser_managed_spaces.js`:

```js
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_parse_normalizes_entries() {
  await withManagedSpaces(
    [
      { name: "Work", icon: "briefcase", container: "Work", position: 0 },
      { name: "Personal", icon: "🏠" },
      { name: "  ", icon: "x" }, // skipped: empty name
    ],
    async () => {
      const spaces = gZenManagedSpaces.getManagedSpaces();
      Assert.equal(spaces.length, 2, "empty-name entry dropped");

      Assert.equal(spaces[0].name, "Work");
      Assert.equal(
        spaces[0].icon,
        "chrome://browser/skin/zen-icons/selectable/briefcase.svg",
        "bare icon name expanded to selectable svg URL"
      );
      Assert.equal(spaces[0].container, "Work");
      Assert.equal(spaces[0].position, 0);

      Assert.equal(spaces[1].icon, "🏠", "emoji kept as-is");
      Assert.equal(spaces[1].position, 1, "position falls back to array index");

      Assert.ok(gZenManagedSpaces.isManaged("Work"), "Work is managed");
      Assert.ok(!gZenManagedSpaces.isManaged("Nope"), "unknown not managed");
    }
  );
});

add_task(async function test_malformed_pref_is_noop() {
  await withManagedSpaces("not json at all", async () => {});
  await SpecialPowers.pushPrefEnv({
    set: [["zen.space-routing.managed-spaces", "not json"]],
  });
  Assert.deepEqual(
    gZenManagedSpaces.getManagedSpaces(),
    [],
    "malformed pref yields no managed spaces and does not throw"
  );
  await SpecialPowers.popPrefEnv();
});
```

- [ ] **Step 7: Register the test file**

In `src/zen/tests/space_routing/browser.toml`, add (keep alphabetical-ish grouping):

```toml
["browser_managed_spaces.js"]
```

- [ ] **Step 8: Build and run — verify the parse tests pass**

```bash
node --check src/zen/space-routing/ZenManagedSpaces.sys.mjs
cd engine && ./mach build faster && cd ..
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: `test_parse_normalizes_entries` and `test_malformed_pref_is_noop` PASS.

- [ ] **Step 9: Commit**

```bash
git add src/zen/space-routing/ZenManagedSpaces.sys.mjs src/zen/space-routing/moz.build \
  src/zen/common/ZenPreloadedScripts.js prefs/zen/space-routing.yaml \
  src/zen/tests/space_routing/head.js src/zen/tests/space_routing/browser.toml \
  src/zen/tests/space_routing/browser_managed_spaces.js
git commit -m "feat(space-routing): parse zen.space-routing.managed-spaces"
```

---

## Task 2: Resolve a container name to a userContextId

**Files:**
- Modify: `src/zen/space-routing/ZenManagedSpaces.sys.mjs`
- Test: `src/zen/tests/space_routing/browser_managed_spaces.js`

- [ ] **Step 1: Write the failing test**

Append to `browser_managed_spaces.js`:

```js
add_task(async function test_resolve_container_by_name() {
  const created = ContextualIdentityService.create(
    "ZMS Test Container",
    "fingerprint",
    "blue"
  );
  registerCleanupFunction(() =>
    ContextualIdentityService.remove(created.userContextId)
  );

  Assert.equal(
    gZenManagedSpaces.resolveContainerId("ZMS Test Container"),
    created.userContextId,
    "container name resolves to its userContextId"
  );
  Assert.equal(
    gZenManagedSpaces.resolveContainerId("Does Not Exist"),
    0,
    "unknown container name resolves to 0 (no container)"
  );
  Assert.equal(
    gZenManagedSpaces.resolveContainerId(created.userContextId),
    created.userContextId,
    "a numeric userContextId is accepted directly"
  );
  Assert.equal(gZenManagedSpaces.resolveContainerId(null), 0, "null -> 0");
});
```

This test needs `ContextualIdentityService` in scope; add to `head.js`:

```js
const { ContextualIdentityService } = ChromeUtils.importESModule(
  "resource://gre/modules/ContextualIdentityService.sys.mjs"
);
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: FAIL — `gZenManagedSpaces.resolveContainerId is not a function`.

- [ ] **Step 3: Implement `resolveContainerId`**

In `ZenManagedSpaces.sys.mjs`, add a public method to the class (after `isManaged`):

```js
  /**
   * Resolves a container reference (its user-visible name, or a userContextId
   * number) to a userContextId. An unknown name yields 0 (no container).
   * Containers are never created here.
   *
   * @param {string|number|null} container
   * @returns {number}
   */
  resolveContainerId(container) {
    if (typeof container === "number" && Number.isInteger(container)) {
      return container;
    }
    if (typeof container !== "string" || container.trim() === "") {
      return 0;
    }
    const wanted = container.trim();
    for (const identity of ContextualIdentityService.getPublicIdentities()) {
      const label =
        ContextualIdentityService.getUserContextLabel(identity.userContextId) ||
        identity.name;
      if (label === wanted) {
        return identity.userContextId;
      }
    }
    return 0;
  }
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd engine && ./mach build faster && cd ..
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: `test_resolve_container_by_name` PASS.

- [ ] **Step 5: Commit**

```bash
git add src/zen/space-routing/ZenManagedSpaces.sys.mjs src/zen/tests/space_routing/head.js \
  src/zen/tests/space_routing/browser_managed_spaces.js
git commit -m "feat(space-routing): resolve managed-space container by name"
```

---

## Task 3: `reconcile(win)` — create a missing managed Space

**Files:**
- Modify: `src/zen/space-routing/ZenManagedSpaces.sys.mjs`
- Test: `src/zen/tests/space_routing/browser_managed_spaces.js`

- [ ] **Step 1: Write the failing test**

Append to `browser_managed_spaces.js`:

```js
add_task(async function test_reconcile_creates_missing_space() {
  const before = gZenWorkspaces.getWorkspaces().length;
  await withManagedSpaces(
    [{ name: "ZMS Created", icon: "briefcase" }],
    async () => {
      gZenManagedSpaces.reconcile(window);

      const space = gZenWorkspaces
        .getWorkspaces()
        .find(w => w.name === "ZMS Created");
      Assert.ok(space, "a managed Space was created for the missing name");
      Assert.equal(
        space.icon,
        "chrome://browser/skin/zen-icons/selectable/briefcase.svg",
        "created Space uses the resolved icon URL"
      );
      Assert.equal(
        gZenWorkspaces.getWorkspaces().length,
        before + 1,
        "exactly one Space created"
      );

      // cleanup
      gZenWorkspaces.removeWorkspace(space.uuid);
    }
  );
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: FAIL — `gZenManagedSpaces.reconcile is not a function`.

- [ ] **Step 3: Implement `reconcile` (create path only for now)**

In `ZenManagedSpaces.sys.mjs`, add:

```js
  /**
   * Reconciles managed Spaces into a window's workspaces: creates a Space for
   * any managed name that doesn't exist yet. Idempotent. Never deletes. Must run
   * after gZenWorkspaces has finished initializing (so saveWorkspace can
   * materialize the UI).
   *
   * @param {Window} win
   */
  reconcile(win) {
    const ws = win?.gZenWorkspaces;
    if (!ws?.workspaceEnabled) {
      return;
    }
    for (const entry of this.getManagedSpaces()) {
      try {
        const existing = ws.getWorkspaces().find(w => w.name === entry.name);
        if (existing) {
          continue; // update path added in Task 4
        }
        ws.saveWorkspace({
          uuid: win.gZenUIManager.generateUuidv4(),
          name: entry.name,
          icon: entry.icon,
          theme: win.nsZenThemePicker.getTheme([]),
          containerTabId: this.resolveContainerId(entry.container),
        });
      } catch (e) {
        console.error(
          "[ZenManagedSpaces] reconcile failed for",
          entry?.name,
          e
        );
      }
    }
  }
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd engine && ./mach build faster && cd ..
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: `test_reconcile_creates_missing_space` PASS.

- [ ] **Step 5: Commit**

```bash
git add src/zen/space-routing/ZenManagedSpaces.sys.mjs src/zen/tests/space_routing/browser_managed_spaces.js
git commit -m "feat(space-routing): reconcile creates missing managed Spaces"
```

---

## Task 4: `reconcile(win)` — update existing, never duplicate, never delete

**Files:**
- Modify: `src/zen/space-routing/ZenManagedSpaces.sys.mjs`
- Test: `src/zen/tests/space_routing/browser_managed_spaces.js`

- [ ] **Step 1: Write the failing tests**

Append to `browser_managed_spaces.js`:

```js
add_task(async function test_reconcile_updates_existing_not_duplicate() {
  // A user-created Space with the managed name, wrong icon.
  await gZenWorkspaces.createAndSaveWorkspace("Space", undefined, true);
  const existing = gZenWorkspaces.getWorkspaces().at(-1);
  existing.name = "ZMS Existing";
  existing.icon = "❓";
  gZenWorkspaces.saveWorkspace(existing);

  const countBefore = gZenWorkspaces.getWorkspaces().length;
  await withManagedSpaces(
    [{ name: "ZMS Existing", icon: "flask" }],
    async () => {
      gZenManagedSpaces.reconcile(window);

      const matches = gZenWorkspaces
        .getWorkspaces()
        .filter(w => w.name === "ZMS Existing");
      Assert.equal(matches.length, 1, "no duplicate Space created");
      Assert.equal(
        matches[0].icon,
        "chrome://browser/skin/zen-icons/selectable/flask.svg",
        "existing Space's icon synced to config"
      );
      Assert.equal(
        gZenWorkspaces.getWorkspaces().length,
        countBefore,
        "Space count unchanged"
      );
    }
  );

  gZenWorkspaces.removeWorkspace(existing.uuid);
});

add_task(async function test_reconcile_never_deletes() {
  await gZenWorkspaces.createAndSaveWorkspace("Space", undefined, true);
  const kept = gZenWorkspaces.getWorkspaces().at(-1);
  kept.name = "ZMS Kept";
  gZenWorkspaces.saveWorkspace(kept);

  // Config does NOT mention "ZMS Kept".
  await withManagedSpaces([{ name: "ZMS Other" }], async () => {
    gZenManagedSpaces.reconcile(window);
    Assert.ok(
      gZenWorkspaces.getWorkspaces().some(w => w.name === "ZMS Kept"),
      "a Space absent from config is left in place (never deleted)"
    );
    gZenWorkspaces.removeWorkspace(
      gZenWorkspaces.getWorkspaces().find(w => w.name === "ZMS Other").uuid
    );
  });

  gZenWorkspaces.removeWorkspace(kept.uuid);
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: FAIL — `test_reconcile_updates_existing_not_duplicate` (icon not synced).

- [ ] **Step 3: Implement the update path**

In `reconcile`, replace the `if (existing) { continue; }` block with:

```js
        if (existing) {
          if (entry.icon !== undefined) {
            existing.icon = entry.icon;
          }
          existing.containerTabId = this.resolveContainerId(entry.container);
          ws.saveWorkspace(existing);
          continue;
        }
```

(There is no delete branch — a Space absent from config is simply never touched, which already satisfies `test_reconcile_never_deletes`.)

- [ ] **Step 4: Run them to verify they pass**

```bash
cd engine && ./mach build faster && cd ..
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: both new tests PASS, plus all earlier tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add src/zen/space-routing/ZenManagedSpaces.sys.mjs src/zen/tests/space_routing/browser_managed_spaces.js
git commit -m "feat(space-routing): reconcile syncs existing managed Spaces, never deletes"
```

---

## Task 5: Run reconcile at startup

**Files:**
- Modify: `src/zen/spaces/ZenSpaceManager.mjs` (the `restoreWorkspacesFromSessionStore` `promise.finally` that sets `this.#hasInitialized = true`, ~line 753)

- [ ] **Step 1: Add the production hook**

In `src/zen/spaces/ZenSpaceManager.mjs`, find the `promise.finally(() => { this.#hasInitialized = true; … })` callback inside `restoreWorkspacesFromSessionStore`. Add the reconcile call right after `this.#hasInitialized = true;`:

```js
    promise.finally(() => {
      this.#hasInitialized = true;
      // Seed/refresh config-declared Spaces now that workspaces are live and
      // saveWorkspace() can materialize them. Runs before any routing resolves a
      // Space by name. Guarded so it never blocks init.
      try {
        window.gZenManagedSpaces?.reconcile(window);
      } catch (e) {
        console.error("[ZenManagedSpaces] startup reconcile failed", e);
      }
      // …existing body continues…
    });
```

(Keep the rest of the existing `finally` body unchanged — only insert the reconcile lines after `#hasInitialized = true`.)

- [ ] **Step 2: Write the startup integration test**

Append to `browser_managed_spaces.js`:

```js
add_task(async function test_startup_reconcile_in_new_window() {
  await SpecialPowers.pushPrefEnv({
    set: [
      [
        "zen.space-routing.managed-spaces",
        JSON.stringify([{ name: "ZMS Startup", icon: "globe" }]),
      ],
    ],
  });
  const win = await BrowserTestUtils.openNewBrowserWindow();
  try {
    await win.gZenWorkspaces.promiseInitialized;
    await TestUtils.waitForCondition(() =>
      win.gZenWorkspaces.getWorkspaces().some(w => w.name === "ZMS Startup")
    );
    const space = win.gZenWorkspaces
      .getWorkspaces()
      .find(w => w.name === "ZMS Startup");
    Assert.ok(space, "managed Space seeded during window init");
    win.gZenWorkspaces.removeWorkspace(space.uuid);
  } finally {
    await BrowserTestUtils.closeWindow(win);
    await SpecialPowers.popPrefEnv();
  }
});
```

- [ ] **Step 3: Build and run**

```bash
cd engine && ./mach build faster && cd ..
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: `test_startup_reconcile_in_new_window` PASS (plus all earlier).

- [ ] **Step 4: Commit**

```bash
git add src/zen/spaces/ZenSpaceManager.mjs src/zen/tests/space_routing/browser_managed_spaces.js
git commit -m "feat(space-routing): reconcile managed Spaces on workspace init"
```

---

## Task 6: Read-only — block delete/rename of a managed Space

**Files:**
- Modify: `src/zen/spaces/ZenSpaceManager.mjs` (`contextDeleteWorkspace`, ~line 2914; and the rename entry point)
- Test: `src/zen/tests/space_routing/browser_managed_spaces.js`

- [ ] **Step 1: Write the failing test**

Append to `browser_managed_spaces.js`:

```js
add_task(async function test_managed_space_is_read_only() {
  await withManagedSpaces([{ name: "ZMS RO", icon: "lock-closed" }], async () => {
    gZenManagedSpaces.reconcile(window);
    const space = gZenWorkspaces.getWorkspaces().find(w => w.name === "ZMS RO");
    Assert.ok(space, "managed Space exists");

    const countBefore = gZenWorkspaces.getWorkspaces().length;
    gZenWorkspaces.removeWorkspace(space.uuid);
    Assert.equal(
      gZenWorkspaces.getWorkspaces().length,
      countBefore,
      "removeWorkspace refuses to delete a managed Space"
    );

    // not managed -> still deletable
    await gZenWorkspaces.createAndSaveWorkspace("Space", undefined, true);
    const normal = gZenWorkspaces.getWorkspaces().at(-1);
    normal.name = "ZMS Normal";
    gZenWorkspaces.saveWorkspace(normal);
    gZenWorkspaces.removeWorkspace(normal.uuid);
    Assert.ok(
      !gZenWorkspaces.getWorkspaces().some(w => w.name === "ZMS Normal"),
      "a non-managed Space deletes normally"
    );

    // cleanup the managed one for the test run only
    gZenManagedSpaces.forceRemoveForTest?.(space.uuid);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: FAIL — managed Space gets deleted (count drops).

- [ ] **Step 3: Guard `removeWorkspace`**

In `src/zen/spaces/ZenSpaceManager.mjs`, at the top of `removeWorkspace(windowID)` (~line 1220), add:

```js
  removeWorkspace(windowID) {
    const target = this.getWorkspaceFromId(windowID);
    if (target && window.gZenManagedSpaces?.isManaged(target.name)) {
      gZenUIManager.showToast(
        "zen-workspaces-managed-readonly-toast"
      );
      return Promise.resolve();
    }
    // …existing body…
```

Add the toast string to `locales/en-US/browser/browser/zen-workspaces.ftl` (append near the other `zen-workspaces-*` strings):

```ftl
zen-workspaces-managed-readonly-toast = This Space is managed by your configuration.
```

- [ ] **Step 4: Hide rename + theme controls for managed Spaces**

In the context-menu-show handler in `ZenSpaceManager.mjs` (~line 1144, where `const workspaceName = document.getElementById("context_zenEditWorkspace")` and `themePicker` are resolved and their `.hidden` is set), compute whether the target Space is managed and fold it into both `.hidden` expressions:

```js
    const workspaceName = document.getElementById("context_zenEditWorkspace");
    const themePicker = document.getElementById(
      "context_zenChangeWorkspaceTheme"
    );
    const ctxSpace = this.getWorkspaceFromId(
      this.#contextMenuData.workspaceId || this.activeWorkspace
    );
    const isManagedSpace = !!(
      ctxSpace && window.gZenManagedSpaces?.isManaged(ctxSpace.name)
    );
    /* We can't show the rename input properly in collapsed state,
    so hide the workspace edit input */
    const isCollapsed = !Services.prefs.getBoolPref(
      "zen.view.sidebar-expanded"
    );
    workspaceName.hidden =
      isManagedSpace ||
      isCollapsed ||
      (this.#contextMenuData.workspaceId &&
        this.#contextMenuData.workspaceId !== this.activeWorkspace);
    themePicker.hidden =
      isManagedSpace ||
      (this.#contextMenuData.workspaceId &&
        this.#contextMenuData.workspaceId !== this.activeWorkspace);
```

(Only `isManagedSpace ||` and the two new `const` lines are added — the rest already exists.)

- [ ] **Step 5: Add a test-only escape hatch**

The read-only guard means tests can't clean up managed Spaces via `removeWorkspace`. Add to `ZenManagedSpaces.sys.mjs`:

```js
  // Test-only: bypasses the read-only guard so tests can clean up Spaces they
  // seeded. Never call from product code.
  forceRemoveForTest(uuid) {
    const win = Services.wm.getMostRecentBrowserWindow();
    const ws = win?.gZenWorkspaces;
    const space = ws?.getWorkspaces().find(w => w.uuid === uuid);
    if (space) {
      this.#managedNames.delete(space.name);
      ws.removeWorkspace(uuid);
    }
  }
```

Add `import { Services }` is already global in sys.mjs (`Services` is a global in privileged JS — no import needed).

- [ ] **Step 6: Build and run**

```bash
cd engine && ./mach build faster && cd ..
npm test -- space_routing/browser_managed_spaces.js --headless
```
Expected: `test_managed_space_is_read_only` PASS (plus all earlier).

- [ ] **Step 7: Commit**

```bash
git add src/zen/spaces/ZenSpaceManager.mjs src/zen/space-routing/ZenManagedSpaces.sys.mjs \
  locales/en-US/browser/browser/zenWorkspaces.ftl \
  src/zen/tests/space_routing/browser_managed_spaces.js
git commit -m "feat(space-routing): make config-managed Spaces read-only in the UI"
```

---

## Task 7: Full suite + PR description

**Files:**
- Modify: PR #9 description

- [ ] **Step 1: Run the whole space_routing suite (no regressions)**

```bash
cd engine && ./mach build faster && cd ..
npm test -- space_routing --headless
```
Expected: all tests PASS, including the pre-existing routing tests.

- [ ] **Step 2: Update the PR #9 description**

Add a "Declarative Spaces" section to PR #9 describing `zen.space-routing.managed-spaces`, the schema (name / icon / container / position), the ensure-exists-never-delete lifecycle, read-only UI, and a dotfiles example pairing it with `managed-routes`:

```nix
"zen.space-routing.managed-spaces" = builtins.toJSON [
  { name = "Work";     icon = "briefcase"; container = "Work"; }
  { name = "Personal"; icon = "home";                          }
];
"zen.space-routing.managed-routes" = builtins.toJSON [
  { reference = "github.com"; openInSpace = "Work"; }
];
```

- [ ] **Step 3: Push**

```bash
git push
```

---

## Notes for the implementer

- `Services`, `gBrowser`, `gZenUIManager`, `nsZenThemePicker`, `document`, `window`, `gZenWorkspaces` are ambient globals in the privileged window scope; in `ZenManagedSpaces.sys.mjs` (a sys.mjs) only `Services`, `ChromeUtils`, `console` are ambient — everything window-specific arrives via the `win` argument.
- `position` is honored as **creation order** in v1: managed Spaces are processed in config array order, so new ones are appended in that order. Precise numeric repositioning of pre-existing Spaces is out of scope for this plan (noted in the design's "out of scope").
- If `gZenWorkspaces.createAndSaveWorkspace` is ever used instead of `saveWorkspace`, note it overrides `name`/`containerTabId` from the selected tab for non-syncing windows — which is why this plan builds the workspace object and calls `saveWorkspace` directly.
- Built-in icon slugs (for `icon`) are listed in `src/zen/common/emojis/ZenEmojiPicker.mjs` (e.g. `briefcase`, `flask`, `globe`, `lock-closed`).

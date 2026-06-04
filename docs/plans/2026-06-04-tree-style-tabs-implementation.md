# Tree-Style Tabs + Middle-Mouse Drag-Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native tree-style tabs (any unpinned tab can parent other unpinned tabs, with drag-to-nest, collapse, opener auto-nest, depth-clamping, session persistence, and window sync) plus a middle-mouse drag-select gesture, to Zen Browser.

**Architecture:** A new chrome manager `gZenTabTree` (`src/zen/tab-tree/ZenTabTree.mjs`) holds the tree as per-tab parent-pointers + cached level + collapsed flag, keeping the tab strip in depth-first order. It reuses the existing `--zen-folder-indent` CSS variable for indentation and mirrors the folder system's sessionstore pattern. Drag-to-nest extends the existing `#dragOverSplit` machine in `ZenDragAndDrop.js`. A second manager `gZenTabMultiSelectDrag` (`src/zen/tab-tree/ZenTabMultiSelectDrag.mjs`) owns the middle-button gesture.

**Tech Stack:** Firefox/Zen chrome JavaScript (`.mjs` ES modules, XUL custom elements), `XPCOMUtils` lazy prefs, browser-chrome mochitests, prefs defined in YAML, packaging via `jar.inc.mn` / `surfer build`.

---

## Conventions used in every task

- **Build before testing:** chrome JS lives in `src/` and is copied into `engine/` at build time. After editing source, run `npm run build` (full) before tests pick up changes. For iterative work `cd engine && ./mach build faster` is usually enough for chrome JS/CSS.
- **Run a test file:** `npm test -- tab-tree/<file>.js` (maps to `./mach test zen/tests/tab-tree/<file>.js`). Run a whole dir: `npm test -- tab-tree`.
- **Lint:** `npm run lint` (runs `./mach lint zen`). Fix: `npm run lint:fix`.
- **License headers:** every new file starts with the MPL header block used across the repo:
  ```
  # This Source Code Form is subject to the terms of the Mozilla Public
  # License, v. 2.0. If a copy of the MPL was not distributed with this
  # file, You can obtain one at http://mozilla.org/MPL/2.0/.
  ```
  (`#` for `.mn`/`.yaml`/`.toml`/`.build`, `//` for `.mjs`, `/* ... */` for `.css`/`.js` test files.)
- **Per-tab tree state (canonical names — used everywhere):**
  - `tab._zenTreeParent` — parent `MozTabbrowserTab` element or `null` (runtime).
  - `tab._zenTreeLevel` — integer depth, root = 0 (runtime, cached).
  - `tab._zenTreeCollapsed` — boolean, this tab's subtree collapsed (runtime).
  - `tab.getAttribute("zen-tree-parent-id")` — parent's `id` (persisted/synced mirror).
  - `tab.hasAttribute("zen-tree-collapsed")` — collapsed mirror (persisted/synced).
  - `tab.hasAttribute("zen-tree-hidden")` — set on descendants of a collapsed tab (CSS hides them).
- **Eligibility:** a tab is "tree-eligible" when it is a normal unpinned tab in a workspace and NOT `zen-essential`, `zen-glance-tab`, `zen-empty-tab`, inside a `split-view-group`, or carrying `zen-live-folder-item-id`. This is the helper `gZenTabTree.isTreeEligible(tab)` defined in Task 2 and reused throughout.

---

## File structure

**New files**
- `prefs/zen/tab-tree.yaml` — feature prefs.
- `src/zen/tab-tree/jar.inc.mn` — packaging for the two `.mjs` + CSS.
- `src/zen/tab-tree/ZenTabTree.mjs` — `nsZenTabTree` / `gZenTabTree`: data model, ordering, collapse, lifecycle hooks, persistence, sync triggers.
- `src/zen/tab-tree/ZenTabMultiSelectDrag.mjs` — `nsZenTabMultiSelectDrag` / `gZenTabMultiSelectDrag`: middle-mouse gesture.
- `src/zen/tab-tree/zen-tab-tree.css` — twisty, indentation hook, collapsed hiding, nest drop indicator, pending-close hint.
- `src/zen/tests/tab-tree/browser.toml` + `head.js` + test files.

**Modified files**
- `src/browser/base/content/zen-assets.jar.inc.mn` — add `#include` for the new jar.
- `src/browser/base/content/zen-assets.inc.xhtml` — add `<link>` for `zen-tab-tree.css`.
- `src/zen/zen.globals.mjs` — add `gZenTabTree` and `gZenTabMultiSelectDrag`.
- `src/zen/drag-and-drop/ZenDragAndDrop.js` — add `#dragOverNest` machine + drop branch.
- `src/zen/sessionstore/ZenWindowSync.sys.mjs` — sync tree state across windows.
- `src/zen/common/modules/ZenSessionStore.mjs` — restore per-tab tree attributes.
- `src/zen/sessionstore/ZenSessionManager.sys.mjs` — carry tree state through save/restore (verify path; folders use `sidebarData.folders`).
- `src/zen/tests/moz.build` — register `tab-tree/browser.toml`.
- `src/zen/tests/window_sync/browser.toml` — add the tree sync test.

---

## Phase 0 — Scaffolding

### Task 1: Prefs, component registration, and empty managers that load

**Files:**
- Create: `prefs/zen/tab-tree.yaml`
- Create: `src/zen/tab-tree/jar.inc.mn`
- Create: `src/zen/tab-tree/ZenTabTree.mjs`
- Create: `src/zen/tab-tree/ZenTabMultiSelectDrag.mjs`
- Create: `src/zen/tab-tree/zen-tab-tree.css`
- Modify: `src/browser/base/content/zen-assets.jar.inc.mn`
- Modify: `src/browser/base/content/zen-assets.inc.xhtml`
- Modify: `src/zen/zen.globals.mjs`

- [ ] **Step 1: Create the prefs file** `prefs/zen/tab-tree.yaml`

```yaml
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

- name: zen.tab-tree.enabled
  value: true

- name: zen.tab-tree.auto-nest-by-opener
  value: true

# "promote" (children move up) or "close-subtree" (close descendants too)
- name: zen.tab-tree.close-parent-behavior
  value: promote

- name: zen.tab-tree.indent
  value: 14 # px per nesting level

- name: zen.tab-tree.max-depth
  value: 4 # maximum level; root = 0; 0 disables the cap

- name: zen.tab-tree.drag-nest-to-split-delayMC
  value: 300 # ms hold before nest escalates to split

- name: zen.tabs.middle-drag-select.enabled
  value: true
```

- [ ] **Step 2: Create the jar packaging file** `src/zen/tab-tree/jar.inc.mn`

```
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

        content/browser/zen-components/ZenTabTree.mjs                           (../../zen/tab-tree/ZenTabTree.mjs)
        content/browser/zen-components/ZenTabMultiSelectDrag.mjs                (../../zen/tab-tree/ZenTabMultiSelectDrag.mjs)
        content/browser/zen-styles/zen-tab-tree.css                             (../../zen/tab-tree/zen-tab-tree.css)
```

- [ ] **Step 3: Wire the jar include** — add this line to `src/browser/base/content/zen-assets.jar.inc.mn` immediately after the `folders/jar.inc.mn` include:

```
#include ../../../zen/tab-tree/jar.inc.mn
```

- [ ] **Step 4: Register the globals** — in `src/zen/zen.globals.mjs`, add the two names right after the `"gZenFolders",` line:

```javascript
  "gZenFolders",
  "gZenTabTree",
  "gZenTabMultiSelectDrag",
```

- [ ] **Step 5: Create the CSS file** `src/zen/tab-tree/zen-tab-tree.css` (filled in later tasks; create with header + load marker now)

```css
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/* zen-tab-tree styles are added in later tasks (twisty, collapse, drop indicator). */
```

The CSS is bundled at `chrome://browser/content/zen-styles/zen-tab-tree.css` by the jar, but it must be linked to load. Stylesheets are linked in `src/browser/base/content/zen-assets.inc.xhtml`. Add this line immediately after the existing `zen-folders.css` link (currently at `src/browser/base/content/zen-assets.inc.xhtml:21`):

```xml
<link rel="stylesheet" type="text/css" href="chrome://browser/content/zen-styles/zen-tab-tree.css" />
```

- [ ] **Step 6: Create the tree manager skeleton** `src/zen/tab-tree/ZenTabTree.mjs`

```javascript
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import { nsZenDOMOperatedFeature } from "chrome://browser/content/zen-components/ZenCommonUtils.mjs";

class nsZenTabTree extends nsZenDOMOperatedFeature {
  #enabled = false;

  init() {
    this.#enabled =
      Services.prefs.getBoolPref("zen.tab-tree.enabled", true) &&
      !gZenWorkspaces.privateWindowOrDisabled;
    if (!this.#enabled) {
      return;
    }
    this.#initEventListeners();
  }

  get enabled() {
    return this.#enabled;
  }

  #initEventListeners() {
    window.addEventListener("TabOpen", this);
    window.addEventListener("TabClose", this);
    window.addEventListener("TabMove", this);
    window.addEventListener("TabPinned", this);
  }

  handleEvent(aEvent) {
    const methodName = `on_${aEvent.type}`;
    if (methodName in this) {
      this[methodName](aEvent);
    }
  }

  on_TabOpen(_event) {}
  on_TabClose(_event) {}
  on_TabMove(_event) {}
  on_TabPinned(_event) {}
}

window.gZenTabTree = new nsZenTabTree();
```

- [ ] **Step 7: Create the multi-select manager skeleton** `src/zen/tab-tree/ZenTabMultiSelectDrag.mjs`

```javascript
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import { nsZenDOMOperatedFeature } from "chrome://browser/content/zen-components/ZenCommonUtils.mjs";

class nsZenTabMultiSelectDrag extends nsZenDOMOperatedFeature {
  #enabled = false;

  init() {
    this.#enabled = Services.prefs.getBoolPref(
      "zen.tabs.middle-drag-select.enabled",
      true
    );
    if (!this.#enabled) {
      return;
    }
    // listeners attached in Task 13
  }
}

window.gZenTabMultiSelectDrag = new nsZenTabMultiSelectDrag();
```

- [ ] **Step 8: Build and verify it loads with no errors**

Run: `npm run build`
Then: `npm start`
Expected: browser launches; open Browser Console (Ctrl+Shift+J) and run `gZenTabTree.enabled` → returns `true`; `gZenTabMultiSelectDrag` is defined. No "module not found" or syntax errors in the console.

- [ ] **Step 9: Commit**

```bash
git add prefs/zen/tab-tree.yaml src/zen/tab-tree/ src/browser/base/content/zen-assets.jar.inc.mn src/browser/base/content/zen-assets.inc.xhtml src/zen/zen.globals.mjs
git commit -m "feat(tab-tree): scaffold tree-tabs + middle-drag managers, prefs, packaging"
```

---

## Phase 1 — Tree data model & rendering

### Task 2: Core model — eligibility, level, children/descendants, reindent

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Create: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/head.js`
- Create: `src/zen/tests/tab-tree/browser_tree_model.js`
- Modify: `src/zen/tests/moz.build`

- [ ] **Step 1: Register the test manifest** — in `src/zen/tests/moz.build`, add `"tab-tree/browser.toml",` to the `BROWSER_CHROME_MANIFESTS` list (keep alphabetical-ish; after `"split_view/browser.toml",` is fine).

- [ ] **Step 2: Create the test manifest** `src/zen/tests/tab-tree/browser.toml`

```toml
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

[DEFAULT]
prefs = [
  "zen.tab-tree.enabled=true",
  "widget.macos.native-context-menus=false",
]
support-files = [
  "head.js",
]

["browser_tree_model.js"]
```

- [ ] **Step 3: Create shared test helpers** `src/zen/tests/tab-tree/head.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

async function addNormalTab(url = "about:blank") {
  const tab = BrowserTestUtils.addTab(gBrowser, url, { skipAnimation: true });
  await BrowserTestUtils.browserLoaded(gBrowser.getBrowserForTab(tab));
  return tab;
}

function domOrder(tabs) {
  // Returns the subset `tabs` sorted by their position in the tab strip.
  return [...tabs].sort((a, b) => {
    const pos = a.compareDocumentPosition(b);
    if (pos & Node.DOCUMENT_POSITION_FOLLOWING) {
      return -1;
    }
    if (pos & Node.DOCUMENT_POSITION_PRECEDING) {
      return 1;
    }
    return 0;
  });
}

async function cleanupTabs(...tabs) {
  for (const tab of tabs) {
    if (tab && tab.isConnected && !tab.closing) {
      BrowserTestUtils.removeTab(tab);
    }
  }
}
```

- [ ] **Step 4: Write the failing test** `src/zen/tests/tab-tree/browser_tree_model.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_eligibility_and_level() {
  const a = await addNormalTab();
  const b = await addNormalTab();

  ok(gZenTabTree.isTreeEligible(a), "normal tab is tree-eligible");
  Assert.equal(gZenTabTree.getLevel(a), 0, "root tab is level 0");
  Assert.deepEqual(gZenTabTree.getChildren(a), [], "no children initially");

  // Manually wire a parent pointer to exercise level/children derivation.
  b._zenTreeParent = a;
  gZenTabTree.reindex(a);

  Assert.equal(gZenTabTree.getLevel(b), 1, "child tab is level 1");
  Assert.deepEqual(gZenTabTree.getChildren(a), [b], "a has child b");
  Assert.deepEqual(gZenTabTree.getDescendants(a), [b], "a has descendant b");
  Assert.equal(
    b.style.getPropertyValue("--zen-folder-indent"),
    "14px",
    "child indent is one level (14px)"
  );

  b._zenTreeParent = null;
  await cleanupTabs(a, b);
});
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_model.js`
Expected: FAIL — `gZenTabTree.isTreeEligible is not a function`.

- [ ] **Step 6: Implement the model methods** — add to `nsZenTabTree` in `src/zen/tab-tree/ZenTabTree.mjs` (above the `on_*` handlers):

```javascript
  get #indentStep() {
    return Services.prefs.getIntPref("zen.tab-tree.indent", 14);
  }

  get #maxDepth() {
    return Services.prefs.getIntPref("zen.tab-tree.max-depth", 4);
  }

  isTreeEligible(tab) {
    return (
      gBrowser.isTab(tab) &&
      !tab.pinned &&
      !tab.hasAttribute("zen-essential") &&
      !tab.hasAttribute("zen-glance-tab") &&
      !tab.hasAttribute("zen-empty-tab") &&
      !tab.hasAttribute("zen-live-folder-item-id") &&
      !tab.group?.hasAttribute("split-view-group")
    );
  }

  getParent(tab) {
    const parent = tab._zenTreeParent;
    return parent && parent.isConnected ? parent : null;
  }

  getLevel(tab) {
    let level = 0;
    let node = this.getParent(tab);
    while (node) {
      level++;
      node = this.getParent(node);
    }
    return level;
  }

  getChildren(tab) {
    // Children in DOM order. Tree relationships only span same-workspace tabs.
    return domOrderOf(
      gBrowser.tabs.filter(t => this.getParent(t) === tab)
    );
  }

  getDescendants(tab) {
    const out = [];
    for (const child of this.getChildren(tab)) {
      out.push(child, ...this.getDescendants(child));
    }
    return out;
  }

  // Recompute cached level + indentation for `root` and all its descendants.
  reindex(root) {
    const apply = (tab, level) => {
      tab._zenTreeLevel = level;
      this.#applyIndent(tab, level);
      if (this.getParent(tab)) {
        tab.setAttribute("zen-tree-parent-id", this.getParent(tab).id || "");
      } else {
        tab.removeAttribute("zen-tree-parent-id");
      }
      for (const child of this.getChildren(tab)) {
        apply(child, level + 1);
      }
    };
    apply(root, this.getLevel(root));
  }

  #applyIndent(tab, level) {
    tab.style.setProperty("--zen-folder-indent", `${level * this.#indentStep}px`);
  }
```

Add this module-level helper near the top of the file (after the import), used by `getChildren`:

```javascript
function domOrderOf(tabs) {
  return [...tabs].sort((a, b) => {
    const pos = a.compareDocumentPosition(b);
    if (pos & Node.DOCUMENT_POSITION_FOLLOWING) {
      return -1;
    }
    if (pos & Node.DOCUMENT_POSITION_PRECEDING) {
      return 1;
    }
    return 0;
  });
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_model.js`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/ src/zen/tests/moz.build
git commit -m "feat(tab-tree): tree data model (eligibility, level, children, reindex)"
```

---

### Task 3: `nestTab` — move a tab + its subtree under a parent, keep DFS order

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_nest.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_nest.js"]` to `src/zen/tests/tab-tree/browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_nest.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_nest_single_tab() {
  const parent = await addNormalTab();
  const child = await addNormalTab();

  gZenTabTree.nestTab(child, parent);

  Assert.equal(gZenTabTree.getParent(child), parent, "child re-parented");
  Assert.equal(gZenTabTree.getLevel(child), 1, "child is level 1");
  // DFS order: child sits immediately after parent.
  Assert.equal(
    parent.nextElementSibling,
    child,
    "child placed directly after parent in the strip"
  );

  await cleanupTabs(parent, child);
});

add_task(async function test_nest_moves_whole_subtree() {
  const parent = await addNormalTab(); // future grandparent
  const mid = await addNormalTab();
  const leaf = await addNormalTab();
  gZenTabTree.nestTab(leaf, mid); // mid -> leaf

  const target = await addNormalTab();
  gZenTabTree.nestTab(mid, target); // target -> mid -> leaf

  Assert.equal(gZenTabTree.getParent(mid), target, "mid re-parented to target");
  Assert.equal(gZenTabTree.getParent(leaf), mid, "leaf still child of mid");
  Assert.equal(gZenTabTree.getLevel(mid), 1, "mid level 1 under target");
  Assert.equal(gZenTabTree.getLevel(leaf), 2, "leaf level 2");
  Assert.deepEqual(
    domOrder([target, mid, leaf]),
    [target, mid, leaf],
    "subtree stays contiguous and ordered after target"
  );

  await cleanupTabs(parent, mid, leaf, target);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_nest.js`
Expected: FAIL — `gZenTabTree.nestTab is not a function`.

- [ ] **Step 4: Implement `nestTab` and the subtree-move helper** — add to `nsZenTabTree`:

```javascript
  // Move `tab` (and its entire subtree) to become the last child of `parent`.
  nestTab(tab, parent, { position = "end" } = {}) {
    if (
      tab === parent ||
      !this.isTreeEligible(tab) ||
      !this.isTreeEligible(parent) ||
      this.#isAncestor(tab, parent) || // prevent cycles
      tab.getAttribute("zen-workspace-id") !==
        parent.getAttribute("zen-workspace-id")
    ) {
      return false;
    }

    const subtree = [tab, ...this.getDescendants(tab)]; // already DFS order
    tab._zenTreeParent = parent;

    // Determine insertion reference within the strip.
    let reference;
    if (position === "start") {
      reference = parent; // first child goes right after the parent
    } else {
      const existing = this.getChildren(parent).filter(c => c !== tab);
      const lastChild = existing[existing.length - 1];
      reference = lastChild
        ? this.#lastSubtreeNode(lastChild)
        : parent;
    }

    this.#moveSubtreeAfter(subtree, reference);
    const root = this.#rootOf(parent);
    this.reindex(root);
    this.clampDepth(root);
    this.#onTreeChanged(tab);
    return true;
  }

  #isAncestor(maybeAncestor, tab) {
    let node = this.getParent(tab);
    while (node) {
      if (node === maybeAncestor) {
        return true;
      }
      node = this.getParent(node);
    }
    return false;
  }

  #rootOf(tab) {
    let node = tab;
    while (this.getParent(node)) {
      node = this.getParent(node);
    }
    return node;
  }

  // Last tab (deepest, last) in `tab`'s subtree, in DFS order.
  #lastSubtreeNode(tab) {
    const desc = this.getDescendants(tab);
    return desc.length ? desc[desc.length - 1] : tab;
  }

  // Insert each subtree node, in order, immediately after `reference`,
  // advancing the reference so the block stays contiguous.
  #moveSubtreeAfter(subtree, reference) {
    let ref = reference;
    for (const node of subtree) {
      if (node !== ref && node.previousElementSibling !== ref) {
        ref.after(node);
      }
      ref = node;
    }
    gBrowser.tabContainer._invalidateCachedTabs();
  }

  // Hook for persistence + window sync; fully wired in Tasks 11/12.
  #onTreeChanged(tab) {
    this._persistSoon?.();
    this._syncTreeForTab?.(tab);
  }
```

Add a placeholder `clampDepth` (real body in Task 5) so `nestTab` works now:

```javascript
  clampDepth(_root) {
    // Implemented in Task 5.
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_nest.js`
Expected: PASS (both tasks).

- [ ] **Step 6: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): nestTab moves whole subtree, keeps DFS order"
```

---

### Task 4: `detachTab` / `promoteSubtree` and `nestTabsAsChildren`

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_detach_multi.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_detach_multi.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_detach_multi.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_promote_subtree_to_root() {
  const parent = await addNormalTab();
  const child = await addNormalTab();
  gZenTabTree.nestTab(child, parent);

  gZenTabTree.detachTab(child);
  Assert.equal(gZenTabTree.getParent(child), null, "child detached to root");
  Assert.equal(gZenTabTree.getLevel(child), 0, "detached child is level 0");

  await cleanupTabs(parent, child);
});

add_task(async function test_nest_multiselection_one_level() {
  const target = await addNormalTab();
  const s1 = await addNormalTab();
  const s2 = await addNormalTab();
  const s2child = await addNormalTab();
  gZenTabTree.nestTab(s2child, s2); // s2 has its own subtree

  gZenTabTree.nestTabsAsChildren([s1, s2], target);

  Assert.equal(gZenTabTree.getParent(s1), target, "s1 is direct child");
  Assert.equal(gZenTabTree.getParent(s2), target, "s2 is direct child");
  Assert.equal(gZenTabTree.getLevel(s1), 1, "s1 level 1");
  Assert.equal(gZenTabTree.getLevel(s2), 1, "s2 level 1");
  Assert.equal(gZenTabTree.getParent(s2child), s2, "s2's subtree followed it");
  Assert.equal(gZenTabTree.getLevel(s2child), 2, "s2child level 2");

  await cleanupTabs(target, s1, s2, s2child);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_detach_multi.js`
Expected: FAIL — `gZenTabTree.detachTab is not a function`.

- [ ] **Step 4: Implement** — add to `nsZenTabTree`:

```javascript
  // Re-parent `tab` to its grandparent (or root). Subtree follows.
  promoteSubtree(tab) {
    const grandparent = this.getParent(this.getParent(tab));
    if (grandparent) {
      this.nestTab(tab, grandparent, { position: "end" });
    } else {
      this.detachTab(tab);
    }
  }

  // Make `tab` a root: clear its parent, leave its subtree intact beneath it.
  detachTab(tab) {
    if (!this.getParent(tab)) {
      return;
    }
    tab._zenTreeParent = null;
    this.reindex(tab);
    this.#onTreeChanged(tab);
  }

  // Make every tab in `tabs` a DIRECT child (one level) of `parent`.
  // Each tab keeps its own subtree. Order follows `tabs` order.
  nestTabsAsChildren(tabs, parent) {
    const eligible = tabs.filter(
      t =>
        t !== parent &&
        this.isTreeEligible(t) &&
        !this.#isAncestor(t, parent)
    );
    for (const t of eligible) {
      this.nestTab(t, parent, { position: "end" });
    }
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_detach_multi.js`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): detach/promote and multi-selection one-level nesting"
```

---

### Task 5: `clampDepth` — flatten deepest levels first to respect `max-depth`

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_depth.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_depth.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_depth.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_depth_clamp_flattens_deepest_first() {
  await SpecialPowers.pushPrefEnv({ set: [["zen.tab-tree.max-depth", 2]] });

  // Build a chain a > b > c > d (would be levels 0,1,2,3).
  const a = await addNormalTab();
  const b = await addNormalTab();
  const c = await addNormalTab();
  const d = await addNormalTab();
  gZenTabTree.nestTab(b, a);
  gZenTabTree.nestTab(c, b);
  gZenTabTree.nestTab(d, c); // d would be level 3 > max 2

  Assert.equal(gZenTabTree.getLevel(a), 0, "a level 0");
  Assert.equal(gZenTabTree.getLevel(b), 1, "b level 1");
  Assert.equal(gZenTabTree.getLevel(c), 2, "c clamped at level 2");
  Assert.equal(
    gZenTabTree.getLevel(d),
    2,
    "d flattened up to the cap (level 2)"
  );
  Assert.equal(
    gZenTabTree.getParent(d),
    b,
    "d re-parented to the node at max-depth-1 (b)"
  );

  await cleanupTabs(a, b, c, d);
  await SpecialPowers.popPrefEnv();
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_depth.js`
Expected: FAIL — `d` ends up level 3 (no clamping yet).

- [ ] **Step 4: Implement `clampDepth`** — replace the placeholder in `nsZenTabTree`:

```javascript
  // Flatten any descendants of `root` whose level exceeds max-depth.
  // Deepest-first: a node beyond the cap is re-parented to the nearest
  // ancestor at (max-depth - 1), collapsing overflow at the cap boundary.
  clampDepth(root) {
    const max = this.#maxDepth;
    if (max <= 0) {
      return; // cap disabled
    }
    let changed = false;
    // Walk descendants; getDescendants() returns DFS order so parents precede.
    for (const node of this.getDescendants(root)) {
      if (this.getLevel(node) > max) {
        const anchor = this.#ancestorAtLevel(node, max - 1);
        if (anchor && this.getParent(node) !== anchor) {
          node._zenTreeParent = anchor;
          changed = true;
        }
      }
    }
    if (changed) {
      this.reindex(root);
    }
  }

  #ancestorAtLevel(tab, level) {
    let node = tab;
    while (node && this.getLevel(node) > level) {
      node = this.getParent(node);
    }
    return node;
  }
```

Note: `clampDepth` only adjusts parent pointers; DFS contiguity is preserved because re-parenting within an already-contiguous subtree does not change DOM order.

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_depth.js`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): depth cap clamping (flatten deepest levels first)"
```

---

## Phase 2 — Collapse / expand + twisty

### Task 6: Collapse twisty, toggle, descendant hiding, active-tab handling

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tab-tree/zen-tab-tree.css`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_collapse.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_collapse.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_collapse.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_collapse_hides_descendants() {
  const parent = await addNormalTab();
  const child = await addNormalTab();
  const grandchild = await addNormalTab();
  gZenTabTree.nestTab(child, parent);
  gZenTabTree.nestTab(grandchild, child);

  gZenTabTree.setCollapsed(parent, true);
  ok(parent._zenTreeCollapsed, "parent flagged collapsed");
  ok(parent.hasAttribute("zen-tree-collapsed"), "collapsed attribute set");
  ok(child.hasAttribute("zen-tree-hidden"), "child hidden");
  ok(grandchild.hasAttribute("zen-tree-hidden"), "grandchild hidden");

  gZenTabTree.setCollapsed(parent, false);
  ok(!parent._zenTreeCollapsed, "parent expanded");
  ok(!child.hasAttribute("zen-tree-hidden"), "child shown");
  ok(!grandchild.hasAttribute("zen-tree-hidden"), "grandchild shown");

  await cleanupTabs(parent, child, grandchild);
});

add_task(async function test_collapse_moves_active_selection_to_ancestor() {
  const parent = await addNormalTab();
  const child = await addNormalTab();
  gZenTabTree.nestTab(child, parent);

  gBrowser.selectedTab = child;
  gZenTabTree.setCollapsed(parent, true);
  Assert.equal(
    gBrowser.selectedTab,
    parent,
    "selection moved to nearest visible ancestor when active tab hidden"
  );

  gZenTabTree.setCollapsed(parent, false);
  await cleanupTabs(parent, child);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_collapse.js`
Expected: FAIL — `gZenTabTree.setCollapsed is not a function`.

- [ ] **Step 4: Implement collapse + twisty** — add to `nsZenTabTree`:

```javascript
  setCollapsed(tab, collapsed) {
    if (!this.getChildren(tab).length) {
      return; // nothing to collapse
    }
    tab._zenTreeCollapsed = collapsed;
    tab.toggleAttribute("zen-tree-collapsed", collapsed);

    const descendants = this.getDescendants(tab);
    for (const d of descendants) {
      // A descendant is hidden if ANY ancestor up to `tab` is collapsed.
      d.toggleAttribute("zen-tree-hidden", this.#isHiddenByCollapse(d));
    }

    if (
      collapsed &&
      gBrowser.selectedTab &&
      descendants.includes(gBrowser.selectedTab)
    ) {
      gBrowser.selectedTab = tab; // nearest visible ancestor
    }

    this.#updateTwisty(tab);
    this.#onTreeChanged(tab);
  }

  toggleCollapse(tab) {
    this.setCollapsed(tab, !tab._zenTreeCollapsed);
  }

  #isHiddenByCollapse(tab) {
    let node = this.getParent(tab);
    while (node) {
      if (node._zenTreeCollapsed) {
        return true;
      }
      node = this.getParent(node);
    }
    return false;
  }

  // Ensure a clickable twisty exists on parent tabs (and not on leaves).
  #updateTwisty(tab) {
    const hasChildren = this.getChildren(tab).length > 0;
    let twisty = tab.querySelector(".zen-tree-twisty");
    if (hasChildren && !twisty) {
      twisty = document.createXULElement("image");
      twisty.className = "zen-tree-twisty";
      twisty.addEventListener("mousedown", e => {
        e.stopPropagation();
        e.preventDefault();
        this.toggleCollapse(tab);
      });
      tab.insertBefore(twisty, tab.firstChild);
    } else if (!hasChildren && twisty) {
      twisty.remove();
    }
    tab.toggleAttribute("zen-tree-parent", hasChildren);
  }
```

Then call `#updateTwisty` for both the new parent and the (possibly now-childless) old parent inside `reindex`. Update `reindex`'s `apply` to also refresh the twisty:

```javascript
    const apply = (tab, level) => {
      tab._zenTreeLevel = level;
      this.#applyIndent(tab, level);
      if (this.getParent(tab)) {
        tab.setAttribute("zen-tree-parent-id", this.getParent(tab).id || "");
      } else {
        tab.removeAttribute("zen-tree-parent-id");
      }
      this.#updateTwisty(tab);
      for (const child of this.getChildren(tab)) {
        apply(child, level + 1);
      }
    };
```

Also, in `nestTab`, after computing `root`, refresh the twisty of the tab's previous parent if it lost its last child. Add right before `this.reindex(root)`:

```javascript
    const previousParent = tab._zenTreePreviousParent;
    tab._zenTreePreviousParent = null;
```

and set `tab._zenTreePreviousParent = this.getParent(tab);` as the very first line of `nestTab` (before reassigning). Then after `this.reindex(root)` add:

```javascript
    if (previousParent && previousParent !== parent) {
      this.reindex(this.#rootOf(previousParent));
    }
```

- [ ] **Step 5: Add the CSS** — append to `src/zen/tab-tree/zen-tab-tree.css`:

```css
/* Hide collapsed descendants. */
.tabbrowser-tab[zen-tree-hidden] {
  display: none !important;
}

/* Collapse twisty on parent tabs. */
.tabbrowser-tab .zen-tree-twisty {
  width: 12px;
  height: 12px;
  margin-inline: 2px;
  flex-shrink: 0;
  -moz-context-properties: fill;
  fill: currentColor;
  opacity: 0.7;
  list-style-image: url("chrome://global/skin/icons/arrow-down.svg");
  transition: transform 0.15s ease, opacity 0.15s ease;
  cursor: pointer;
}

.tabbrowser-tab .zen-tree-twisty:hover {
  opacity: 1;
}

/* Point right when collapsed, down when expanded. */
.tabbrowser-tab[zen-tree-collapsed] .zen-tree-twisty {
  transform: rotate(-90deg);
}

/* Only show the twisty on parent tabs when the sidebar is expanded. */
:root:not([zen-sidebar-expanded="true"]) .tabbrowser-tab .zen-tree-twisty {
  display: none;
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_collapse.js`
Expected: PASS (both tasks).

- [ ] **Step 7: Manual check** — `npm start`, open several tabs, `gZenTabTree.nestTab(gBrowser.tabs[3], gBrowser.tabs[2])` in the console, confirm a twisty appears on the parent and clicking it hides/shows the child.

- [ ] **Step 8: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tab-tree/zen-tab-tree.css src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): collapse/expand with twisty and active-tab handling"
```

---

## Phase 3 — Drag-to-nest interaction

### Task 7: Extend `ZenDragAndDrop` with a nest machine + escalate-to-split

**Files:**
- Modify: `src/zen/drag-and-drop/ZenDragAndDrop.js`
- Modify: `src/zen/tab-tree/zen-tab-tree.css`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_drag.js`

Context — verbatim current behavior (from `src/zen/drag-and-drop/ZenDragAndDrop.js`):
- Private fields start at line 64; `#dragOverSplit = {};` is at line 75.
- The pref getters block is in the constructor (lines 85–108).
- `#handle_tabDragOverToSplit(event)` (lines 762–846) bails in the edge zone and starts a split timer in the central band.
- `handle_drop` (lines 946–964) calls `this.#handle_dropCreateSplit(event)` then `this._clearDragOverSplit()`.
- `#handle_dropCreateSplit` (lines 992–1018) checks `this.#dragOverSplit.canDrop` and calls `gZenViewSplitter.splitTabs(...)`.

- [ ] **Step 1: Register the test** — add `["browser_tree_drag.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_drag.js` (drives the manager paths the drop handler calls, so it does not depend on synthesizing native drag pixels)

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

// The drop handler calls gZenTabTree.nestTab / nestTabsAsChildren depending on
// how many tabs are dragged. Verify that contract holds for a quick "nest" drop.
add_task(async function test_drop_quick_nests_single() {
  const parent = await addNormalTab();
  const dragged = await addNormalTab();

  // Simulate what #handle_dropNest does for a single-tab quick drop.
  const handled = gZenTabTree.handleNestDrop([dragged], parent);

  ok(handled, "nest drop handled");
  Assert.equal(gZenTabTree.getParent(dragged), parent, "dragged nested");

  await cleanupTabs(parent, dragged);
});

add_task(async function test_drop_quick_nests_multiselection() {
  const parent = await addNormalTab();
  const a = await addNormalTab();
  const b = await addNormalTab();

  gZenTabTree.handleNestDrop([a, b], parent);

  Assert.equal(gZenTabTree.getParent(a), parent, "a nested as direct child");
  Assert.equal(gZenTabTree.getParent(b), parent, "b nested as direct child");
  Assert.equal(gZenTabTree.getLevel(a), 1, "a level 1");
  Assert.equal(gZenTabTree.getLevel(b), 1, "b level 1");

  await cleanupTabs(parent, a, b);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_drag.js`
Expected: FAIL — `gZenTabTree.handleNestDrop is not a function`.

- [ ] **Step 4: Add `handleNestDrop` to the manager** — add to `nsZenTabTree`:

```javascript
  // Entry point used by the drag-and-drop drop handler.
  // `draggedTabs` is the set of tabs being dragged (1 = subtree move,
  // >1 = multi-selection one-level nest). Returns true if it nested anything.
  handleNestDrop(draggedTabs, target) {
    if (!this.enabled || !this.isTreeEligible(target)) {
      return false;
    }
    const tabs = draggedTabs.filter(t => this.isTreeEligible(t));
    if (!tabs.length) {
      return false;
    }
    if (tabs.length === 1) {
      return this.nestTab(tabs[0], target);
    }
    this.nestTabsAsChildren(tabs, target);
    return true;
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_drag.js`
Expected: PASS.

- [ ] **Step 6: Add the nest machine to `ZenDragAndDrop.js`** — add a field next to `#dragOverSplit = {};` (line 75):

```javascript
    #dragOverNest = {};
```

Add a pref getter in the constructor, right after the `_dndSplitDelay` getter block (after line ~102):

```javascript
      XPCOMUtils.defineLazyPreferenceGetter(
        this,
        "_dndNestToSplitDelay",
        "zen.tab-tree.drag-nest-to-split-delayMC",
        300
      );
      XPCOMUtils.defineLazyPreferenceGetter(
        this,
        "_dndTreeEnabled",
        "zen.tab-tree.enabled",
        true
      );
```

- [ ] **Step 7: Make the central-band hover nest immediately, then escalate to split** — modify `#handle_tabDragOverToSplit`. Keep all the existing guard/exclusion code (lines 762–799) and the zone math (lines 801–820) unchanged. Replace the tail of the method (the block from `// If the drop side or element changes` through the `setTimeout(...)`, lines ~822–845) with:

```javascript
      // Central band reached: offer NEST immediately, escalate to SPLIT on hold.
      const draggedTabs = [...movingTabsSet];
      const canNest =
        this._dndTreeEnabled &&
        window.gZenTabTree?.enabled &&
        window.gZenTabTree.isTreeEligible(dropElement) &&
        draggedTabs.every(t => window.gZenTabTree.isTreeEligible(t)) &&
        !movingTabsSet.has(dropElement);

      // If the target/side changed, reset both machines.
      if (
        this.#dragOverSplit.data?.dropElement !== dropElement ||
        this.#dragOverSplit.data?.dropSide !== dropSide
      ) {
        this._clearDragOverSplit();
        this._clearDragOverNest();
      }

      // Show the nest indicator right away (no delay) when nesting is allowed.
      if (canNest && this.#dragOverNest.dropElement !== dropElement) {
        this.#createNestIndicator(dropElement);
      }

      // (Re)arm the escalation-to-split timer for this target+side.
      if (
        !this.#dragOverSplit.timer ||
        this.#dragOverSplit.data?.dropElement !== dropElement ||
        this.#dragOverSplit.data?.dropSide !== dropSide
      ) {
        if (this.#dragOverSplit.timer) {
          clearTimeout(this.#dragOverSplit.timer);
        }
        this.#dragOverSplit.data = { dropElement, dropSide };
        this.#dragOverSplit.timer = setTimeout(() => {
          // Escalate: drop the nest offer, show the split fake-tab.
          this._clearDragOverNest();
          this.#createFakeTabSplit(dropElement, dropSide);
        }, canNest ? this._dndNestToSplitDelay : this._dndSplitDelay);
      }
```

Note: when `canNest` is false (e.g., a pinned target), behavior is unchanged from today — only the split timer arms, with the original `_dndSplitDelay`.

- [ ] **Step 8: Add nest indicator + clear helpers** — add right after `_clearDragOverSplit()` (after line 879):

```javascript
    #createNestIndicator(dropElement) {
      this.#clearNestIndicatorElement();
      const indicator = document.createXULElement("zen-tree-nest-indicator");
      const level = (window.gZenTabTree?.getLevel(dropElement) ?? 0) + 1;
      const indentStep = Services.prefs.getIntPref("zen.tab-tree.indent", 14);
      indicator.style.marginInlineStart = `${level * indentStep}px`;
      dropElement.after(indicator);
      this.#dragOverNest.indicator = indicator;
      this.#dragOverNest.dropElement = dropElement;
      this.#dragOverNest.canDrop = true;
    }

    #clearNestIndicatorElement() {
      this.#dragOverNest.indicator?.remove();
      this.#dragOverNest.indicator = null;
    }

    _clearDragOverNest() {
      this.#clearNestIndicatorElement();
      this.#dragOverNest.dropElement = null;
      this.#dragOverNest.canDrop = null;
    }
```

Also make the edge-zone bail clear the nest machine: in `#handle_tabDragOverToSplit`, the two early `this._clearDragOverSplit(); return;` exclusion blocks (lines ~786 and ~796) and the edge-zone bail (lines ~812–817) should each also call `this._clearDragOverNest();` before returning. Add `this._clearDragOverNest();` next to each `this._clearDragOverSplit();` in those three bail-out spots.

- [ ] **Step 9: Branch the drop** — in `handle_drop` (lines 946–964), replace the line `this.#handle_dropCreateSplit(event);` with:

```javascript
      // Split wins if the hold escalated; otherwise try a nest.
      if (this.#dragOverSplit.canDrop) {
        this.#handle_dropCreateSplit(event);
      } else {
        this.#handle_dropNest(event);
      }
```

And add `this._clearDragOverNest();` right after the existing `this._clearDragOverSplit();` at the end of `handle_drop`.

- [ ] **Step 10: Implement `#handle_dropNest`** — add after `#handle_dropCreateSplit` (after line 1018):

```javascript
    #handle_dropNest(event) {
      if (!this.#dragOverNest.canDrop || !window.gZenTabTree?.enabled) {
        return;
      }
      const dt = event.dataTransfer;
      const draggedTab = dt.mozGetDataAt(TAB_DROP_TYPE, 0);
      const target = this.#dragOverNest.dropElement;
      if (!draggedTab || !target) {
        return;
      }
      const movingTabsSet = draggedTab._dragData?.movingTabsSet;
      const draggedTabs = movingTabsSet?.size
        ? [...movingTabsSet]
        : [draggedTab];
      this._dontAnimateTabMove = true;
      this._clearDragOverNest();
      window.gZenTabTree.handleNestDrop(draggedTabs, target);
    }
```

- [ ] **Step 11: Clear nest on dragend** — find `handle_dragend` (search the file for `handle_dragend`) and add `this._clearDragOverNest();` next to its existing `this._clearDragOverSplit();` call.

- [ ] **Step 12: Add indicator CSS** — append to `src/zen/tab-tree/zen-tab-tree.css`:

```css
/* Drop-as-child indicator: a thin indented line under the target tab. */
zen-tree-nest-indicator {
  display: block;
  height: 2px;
  margin-block: 1px;
  margin-inline-end: 8px;
  border-radius: 1px;
  background-color: var(--zen-primary-color, AccentColor);
  pointer-events: none;
}
```

- [ ] **Step 13: Run tree tests + manual drag check**

Run: `npm run build && npm test -- tab-tree`
Expected: PASS (all tree tests).
Manual (`npm start`): drag one tab quickly onto another → it nests as a child; hold over a tab ~300ms → the split fake-tab appears and releasing splits; drop in the gap between tabs → normal reorder.

- [ ] **Step 14: Commit**

```bash
git add src/zen/drag-and-drop/ZenDragAndDrop.js src/zen/tab-tree/ src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): drag-to-nest with hold-to-split escalation"
```

---

## Phase 4 — Lifecycle hooks

### Task 8: Opener auto-nest on `TabOpen`

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_opener.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_opener.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_opener.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_opener_autonest_on() {
  await SpecialPowers.pushPrefEnv({
    set: [["zen.tab-tree.auto-nest-by-opener", true]],
  });
  const opener = await addNormalTab();
  gBrowser.selectedTab = opener;

  const child = gBrowser.addTab("about:blank", {
    ownerTab: opener,
    triggeringPrincipal: Services.scriptSecurityManager.getSystemPrincipal(),
  });
  await BrowserTestUtils.browserLoaded(gBrowser.getBrowserForTab(child));

  Assert.equal(
    gZenTabTree.getParent(child),
    opener,
    "tab opened from opener auto-nests as its child"
  );

  await cleanupTabs(opener, child);
  await SpecialPowers.popPrefEnv();
});

add_task(async function test_opener_autonest_off() {
  await SpecialPowers.pushPrefEnv({
    set: [["zen.tab-tree.auto-nest-by-opener", false]],
  });
  const opener = await addNormalTab();
  const child = gBrowser.addTab("about:blank", {
    ownerTab: opener,
    triggeringPrincipal: Services.scriptSecurityManager.getSystemPrincipal(),
  });
  await BrowserTestUtils.browserLoaded(gBrowser.getBrowserForTab(child));

  Assert.equal(gZenTabTree.getParent(child), null, "no auto-nest when pref off");

  await cleanupTabs(opener, child);
  await SpecialPowers.popPrefEnv();
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_opener.js`
Expected: FAIL — child has no parent (the `on_TabOpen` stub is empty).

- [ ] **Step 4: Implement `on_TabOpen`** — replace the stub in `nsZenTabTree`:

```javascript
  on_TabOpen(event) {
    if (
      !this.enabled ||
      !Services.prefs.getBoolPref("zen.tab-tree.auto-nest-by-opener", true)
    ) {
      return;
    }
    const tab = event.target;
    // `owner` is Firefox's opener-tab relationship for foreground/background
    // tabs opened from another tab (link-in-new-tab, ctrl/middle click).
    const opener = tab.owner;
    if (
      !opener ||
      !this.isTreeEligible(tab) ||
      !this.isTreeEligible(opener) ||
      tab.getAttribute("zen-workspace-id") !==
        opener.getAttribute("zen-workspace-id")
    ) {
      return;
    }
    this.nestTab(tab, opener);
  }
```

If `tab.owner` is null in the test (timing), fall back to `tab.openerTab`. Confirm which property carries the opener by logging in `on_TabOpen`; Firefox sets `tab.owner` for `ownerTab`-opened tabs. Use whichever is populated; the test asserts the behavior.

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_opener.js`
Expected: PASS (both tasks).

- [ ] **Step 6: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): opener-based auto-nesting behind a pref"
```

---

### Task 9: Close-parent behavior (`promote` vs `close-subtree`) on `TabClose`

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_close.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_close.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_close.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_close_parent_promotes_children() {
  await SpecialPowers.pushPrefEnv({
    set: [["zen.tab-tree.close-parent-behavior", "promote"]],
  });
  const grand = await addNormalTab();
  const parent = await addNormalTab();
  const child = await addNormalTab();
  gZenTabTree.nestTab(parent, grand);
  gZenTabTree.nestTab(child, parent);

  BrowserTestUtils.removeTab(parent);
  await TestUtils.waitForCondition(() => !parent.isConnected);

  Assert.equal(
    gZenTabTree.getParent(child),
    grand,
    "child promoted to grandparent when parent closed"
  );

  await cleanupTabs(grand, child);
  await SpecialPowers.popPrefEnv();
});

add_task(async function test_close_parent_closes_subtree() {
  await SpecialPowers.pushPrefEnv({
    set: [["zen.tab-tree.close-parent-behavior", "close-subtree"]],
  });
  const parent = await addNormalTab();
  const child = await addNormalTab();
  gZenTabTree.nestTab(child, parent);

  BrowserTestUtils.removeTab(parent);
  await TestUtils.waitForCondition(() => child.closing || !child.isConnected);
  ok(true, "descendants closed with the parent");

  await cleanupTabs(parent, child);
  await SpecialPowers.popPrefEnv();
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_close.js`
Expected: FAIL — children orphaned / not closed (empty `on_TabClose`).

- [ ] **Step 4: Implement `on_TabClose`** — replace the stub:

```javascript
  on_TabClose(event) {
    if (!this.enabled) {
      return;
    }
    const tab = event.target;
    const children = this.getChildren(tab);
    if (!children.length) {
      return;
    }
    const behavior = Services.prefs.getStringPref(
      "zen.tab-tree.close-parent-behavior",
      "promote"
    );
    if (behavior === "close-subtree") {
      const subtree = this.getDescendants(tab);
      // Defer so the current close finishes first.
      window.setTimeout(() => {
        gBrowser.removeTabs(
          subtree.filter(t => t.isConnected && !t.closing),
          { animate: true }
        );
      }, 0);
      return;
    }
    // promote: re-parent each direct child to the closing tab's parent.
    const newParent = this.getParent(tab);
    for (const child of children) {
      child._zenTreeParent = newParent;
    }
    for (const child of children) {
      this.reindex(this.#rootOf(child));
    }
    this.#onTreeChanged(tab);
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_close.js`
Expected: PASS (both tasks).

- [ ] **Step 6: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): close-parent behavior (promote/close-subtree)"
```

---

### Task 10: Pin detaches a tree tab; reorder re-parents from neighbor

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_pin_reorder.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_pin_reorder.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_pin_reorder.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_pin_detaches_and_promotes_children() {
  const parent = await addNormalTab();
  const child = await addNormalTab();
  gZenTabTree.nestTab(child, parent);

  gBrowser.pinTab(parent);
  await TestUtils.waitForCondition(() => parent.pinned);

  Assert.equal(gZenTabTree.getParent(parent), null, "pinned tab left the tree");
  Assert.equal(
    gZenTabTree.getParent(child),
    null,
    "orphaned child promoted to root"
  );

  gBrowser.unpinTab(parent);
  await cleanupTabs(parent, child);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_pin_reorder.js`
Expected: FAIL — relationships unchanged (empty `on_TabPinned`).

- [ ] **Step 4: Implement `on_TabPinned` and `on_TabMove`** — replace both stubs:

```javascript
  on_TabPinned(event) {
    if (!this.enabled) {
      return;
    }
    const tab = event.target;
    // Promote children to the tab's parent, then detach the tab itself.
    const newParent = this.getParent(tab);
    for (const child of this.getChildren(tab)) {
      child._zenTreeParent = newParent;
    }
    tab._zenTreeParent = null;
    tab._zenTreeCollapsed = false;
    tab.removeAttribute("zen-tree-parent-id");
    tab.removeAttribute("zen-tree-collapsed");
    tab.style.removeProperty("--zen-folder-indent");
    this.#updateTwisty(tab);
    // Reindex affected roots.
    const roots = new Set([newParent && this.#rootOf(newParent)].filter(Boolean));
    for (const root of roots) {
      this.reindex(root);
    }
    this.#onTreeChanged(tab);
  }

  on_TabMove(event) {
    if (!this.enabled || this._suppressMoveHandling) {
      return;
    }
    const tab = event.target;
    if (!this.isTreeEligible(tab) || !this.getParent(tab)) {
      // A reorder that drops a tab in a gap makes it a sibling of its new
      // previous neighbor. Re-derive its parent from that neighbor.
      this.#reparentFromNeighbor(tab);
    }
  }

  // After a plain reorder, set tab's parent to that of its previous visible
  // sibling (or root at container start).
  #reparentFromNeighbor(tab) {
    if (!this.isTreeEligible(tab)) {
      return;
    }
    let prev = tab.previousElementSibling;
    while (prev && !this.isTreeEligible(prev)) {
      prev = prev.previousElementSibling;
    }
    const newParent = prev ? this.getParent(prev) : null;
    if (newParent === tab || this.#isAncestor(tab, newParent)) {
      return; // never create a cycle
    }
    if (this.getParent(tab) !== newParent) {
      tab._zenTreeParent = newParent;
      this.reindex(this.#rootOf(tab));
      this.#onTreeChanged(tab);
    }
  }
```

To avoid feedback loops when *we* move tabs (in `#moveSubtreeAfter`), guard our own moves. In `#moveSubtreeAfter`, set the flag around the DOM moves:

```javascript
  #moveSubtreeAfter(subtree, reference) {
    this._suppressMoveHandling = true;
    let ref = reference;
    for (const node of subtree) {
      if (node !== ref && node.previousElementSibling !== ref) {
        ref.after(node);
      }
      ref = node;
    }
    gBrowser.tabContainer._invalidateCachedTabs();
    this._suppressMoveHandling = false;
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_pin_reorder.js`
Expected: PASS.

- [ ] **Step 6: Run the full tree suite for regressions**

Run: `npm test -- tab-tree`
Expected: PASS (all files).

- [ ] **Step 7: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): pin detaches from tree; reorder re-parents from neighbor"
```

---

## Phase 5 — Persistence

### Task 11: Persist & restore tree state across restart

**Files:**
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/common/modules/ZenSessionStore.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_persist.js`

Background (verbatim): per-tab Zen attributes are restored in `restoreInitialTabData(tab, tabData)` in `src/zen/common/modules/ZenSessionStore.mjs` (handles `zenWorkspace`, `zenSyncId`, etc.). Tab `id` survives restart via `tabData.zenSyncId`. We persist the parent relationship by parent `id` and rebuild after all tabs exist.

- [ ] **Step 1: Register the test** — add `["browser_tree_persist.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_tree_persist.js` (uses SessionStore tab-state round-trip, the same mechanism restart uses)

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_tree_state_in_tab_state() {
  const parent = await addNormalTab();
  const child = await addNormalTab();
  gZenTabTree.nestTab(child, parent);
  gZenTabTree.setCollapsed(parent, true);

  // Flush and read the persisted tab state for the child.
  await TabStateFlusher.flush(child.linkedBrowser);
  const state = JSON.parse(SessionStore.getTabState(child));

  Assert.equal(
    state.zenTreeParentId,
    parent.id,
    "child persists its parent id"
  );

  await TabStateFlusher.flush(parent.linkedBrowser);
  const pstate = JSON.parse(SessionStore.getTabState(parent));
  Assert.ok(pstate.zenTreeCollapsed, "parent persists collapsed state");

  gZenTabTree.setCollapsed(parent, false);
  await cleanupTabs(parent, child);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_tree_persist.js`
Expected: FAIL — `state.zenTreeParentId` is undefined.

- [ ] **Step 4: Write tree state into tab state** — Zen persists custom values by mirroring them onto the tab as attributes/properties that the session collector serializes. The collector that builds `tabData` lives alongside `restoreInitialTabData`. Add a collector hook in `nsZenTabTree` that writes the values into the tab's persisted state, and ensure the attributes (`zen-tree-parent-id`, `zen-tree-collapsed`) are already set by `reindex`/`setCollapsed` (they are).

   Add a method to `nsZenTabTree` that returns the serializable fields for a tab, and a `collect` that SessionStore can pick up. The simplest reliable mechanism in this codebase is to store them as `tab` properties that `ZenSessionStore` persists. In `src/zen/common/modules/ZenSessionStore.mjs`, locate the function that BUILDS tab data (the counterpart to `restoreInitialTabData`; search the file for where `zenWorkspace`/`zenSyncId` are written into the data object). Add:

```javascript
    // Tree-style tabs: persist parent id + collapsed.
    if (tab.getAttribute("zen-tree-parent-id")) {
      tabData.zenTreeParentId = tab.getAttribute("zen-tree-parent-id");
    }
    if (tab.hasAttribute("zen-tree-collapsed")) {
      tabData.zenTreeCollapsed = true;
    }
```

   (Place it next to the existing `tabData.zenWorkspace = ...` assignment. If the collector instead lives in `SessionStore`/`ZenSessionManager`, add the same two lines there — follow exactly where `zenWorkspace` is written.)

- [ ] **Step 5: Restore the attributes early** — in `restoreInitialTabData(tab, tabData)` in `src/zen/common/modules/ZenSessionStore.mjs`, add (next to the other `tabData.zen*` restores):

```javascript
    if (tabData.zenTreeParentId) {
      tab.setAttribute("zen-tree-parent-id", tabData.zenTreeParentId);
    }
    if (tabData.zenTreeCollapsed) {
      tab.setAttribute("zen-tree-collapsed", "true");
    }
```

- [ ] **Step 6: Rebuild pointers after restore** — add to `nsZenTabTree` a restore pass and call it after a session restore completes. Add a listener for `SSWindowStateReady` (fired when window session state is applied) in `#initEventListeners`:

```javascript
    window.addEventListener("SSWindowStateReady", this);
```

and implement:

```javascript
  on_SSWindowStateReady() {
    this.rebuildFromAttributes();
  }

  // Reconnect _zenTreeParent pointers from persisted zen-tree-parent-id, then
  // re-apply levels, indentation, collapse hiding, and twisties.
  rebuildFromAttributes() {
    if (!this.enabled) {
      return;
    }
    const byId = new Map();
    for (const tab of gBrowser.tabs) {
      if (tab.id) {
        byId.set(tab.id, tab);
      }
    }
    for (const tab of gBrowser.tabs) {
      const pid = tab.getAttribute("zen-tree-parent-id");
      const parent = pid ? byId.get(pid) : null;
      tab._zenTreeParent =
        parent && parent !== tab && this.isTreeEligible(tab) ? parent : null;
      tab._zenTreeCollapsed = tab.hasAttribute("zen-tree-collapsed");
    }
    // Reindex all roots, then re-apply collapse hiding for collapsed roots.
    for (const tab of gBrowser.tabs) {
      if (this.isTreeEligible(tab) && !this.getParent(tab)) {
        this.reindex(tab);
      }
    }
    for (const tab of gBrowser.tabs) {
      if (tab._zenTreeCollapsed) {
        for (const d of this.getDescendants(tab)) {
          d.toggleAttribute("zen-tree-hidden", this.#isHiddenByCollapse(d));
        }
      }
    }
  }
```

   Note: the persisted DOM order already encodes DFS order (SessionStore restores tabs in their saved order), so no explicit re-sorting is needed — only pointer/level/collapse reconstruction.

- [ ] **Step 7: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_tree_persist.js`
Expected: PASS.

- [ ] **Step 8: Manual restart check** — `npm start`, build a small tree, collapse a node, fully quit and reopen with session restore; confirm the tree, indentation, and collapsed state come back.

- [ ] **Step 9: Commit**

```bash
git add src/zen/tab-tree/ZenTabTree.mjs src/zen/common/modules/ZenSessionStore.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): persist and restore tree parent + collapse across restart"
```

---

## Phase 6 — Window sync (required)

### Task 12: Replicate tree state across synced windows

**Files:**
- Modify: `src/zen/sessionstore/ZenWindowSync.sys.mjs`
- Modify: `src/zen/tab-tree/ZenTabTree.mjs`
- Modify: `src/zen/tests/window_sync/browser.toml`
- Create: `src/zen/tests/window_sync/browser_sync_tree.js`

Background (verbatim from `src/zen/sessionstore/ZenWindowSync.sys.mjs`): sync flags `SYNC_FLAG_LABEL=1<<0`, `SYNC_FLAG_ICON=1<<1`, `SYNC_FLAG_MOVE=1<<2` (lines ~75–78). `#syncItemWithOriginal(aOriginalItem, aTargetItem, aWindow, flags)` copies state to the mirror tab. `getItemFromWindow(win, id)` finds the mirror by id. `#syncItemForAllWindows(aItem, flags)` fans out. Generic events route via `#delegateGenericSyncEvent(aEvent, flags)`; `on_TabMove` already syncs `SYNC_FLAG_MOVE`.

- [ ] **Step 1: Register the test** — add `["browser_sync_tree.js"]` to `src/zen/tests/window_sync/browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/window_sync/browser_sync_tree.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_nest_syncs_to_other_window() {
  await withNewSyncedWindow(async win => {
    // Create two synced tabs (open in this window, mirrored in `win`).
    const parent = gBrowser.addTrustedTab("https://example.com/", {
      inBackground: true,
    });
    const child = gBrowser.addTrustedTab("https://example.com/", {
      inBackground: true,
    });
    await TestUtils.waitForCondition(
      () =>
        win.gZenWindowSync.getItemFromWindow(win, parent.id) &&
        win.gZenWindowSync.getItemFromWindow(win, child.id)
    );

    gZenTabTree.nestTab(child, parent);

    await TestUtils.waitForCondition(() => {
      const mirror = win.gZenWindowSync.getItemFromWindow(win, child.id);
      return mirror?.getAttribute("zen-tree-parent-id") === parent.id;
    }, "child mirror gets the parent id");

    const mirrorChild = win.gZenWindowSync.getItemFromWindow(win, child.id);
    Assert.equal(
      win.gZenTabTree.getParent(mirrorChild)?.id,
      parent.id,
      "mirror window rebuilt the parent pointer"
    );

    BrowserTestUtils.removeTab(child);
    BrowserTestUtils.removeTab(parent);
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- window_sync/browser_sync_tree.js`
Expected: FAIL — mirror child has no `zen-tree-parent-id`.

- [ ] **Step 4: Add a sync flag + copy logic** — in `src/zen/sessionstore/ZenWindowSync.sys.mjs`, after the existing flag constants (line ~78) add:

```javascript
const SYNC_FLAG_TREE = 1 << 3;
```

In `#syncItemWithOriginal(...)`, add a block (after the `SYNC_FLAG_MOVE` block):

```javascript
  if (flags & SYNC_FLAG_TREE && aWindow.gZenTabTree?.enabled) {
    this.#maybeSyncAttributeChange(
      aOriginalItem,
      aTargetItem,
      "zen-tree-parent-id"
    );
    this.#maybeSyncAttributeChange(
      aOriginalItem,
      aTargetItem,
      "zen-tree-collapsed"
    );
    // Rebuild the mirror window's pointers + visual state from attributes.
    aWindow.gZenTabTree.rebuildFromAttributes();
  }
```

- [ ] **Step 5: Add an event the manager can fire and the sync listens for** — register a handler. Find where `ZenWindowSync` adds its window event listeners (search for `addEventListener("TabMove"` in the file) and add alongside it:

```javascript
    window.addEventListener("ZenTreeChanged", this);
```

and add the handler method near `on_TabMove`:

```javascript
  on_ZenTreeChanged(aEvent) {
    this.#delegateGenericSyncEvent(aEvent, SYNC_FLAG_TREE);
    return Promise.resolve();
  }
```

   If `#delegateGenericSyncEvent` expects `aEvent.target` to be the changed tab, that is satisfied below.

- [ ] **Step 6: Fire the event from the manager** — replace the `#onTreeChanged` body in `nsZenTabTree`:

```javascript
  #onTreeChanged(tab) {
    if (tab && tab.isConnected) {
      tab.dispatchEvent(
        new CustomEvent("ZenTreeChanged", { bubbles: true })
      );
    }
  }
```

   (Persistence in Task 11 already works through attributes + `SSWindowStateReady`, so `#onTreeChanged` is now solely the sync trigger. The `this._persistSoon?.()` / `this._syncTreeForTab?.()` placeholders from Task 3 are removed by this replacement.)

- [ ] **Step 7: Run to verify it passes**

Run: `npm run build && npm test -- window_sync/browser_sync_tree.js`
Expected: PASS.

- [ ] **Step 8: Also sync collapse + close** — verify collapse and parent-close replicate by extending the test with a collapse assertion (collapse fires `ZenTreeChanged` via `setCollapsed → #onTreeChanged`). Add to the test, before cleanup:

```javascript
    gZenTabTree.setCollapsed(parent, true);
    await TestUtils.waitForCondition(() => {
      const m = win.gZenWindowSync.getItemFromWindow(win, parent.id);
      return m?.hasAttribute("zen-tree-collapsed");
    }, "collapse syncs to mirror window");
```

Run: `npm run build && npm test -- window_sync/browser_sync_tree.js`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/zen/sessionstore/ZenWindowSync.sys.mjs src/zen/tab-tree/ZenTabTree.mjs src/zen/tests/window_sync/
git commit -m "feat(tab-tree): sync tree parent + collapse across windows"
```

---

## Phase 7 — Middle-mouse drag-select

### Task 13: Range selection on middle-drag

**Files:**
- Modify: `src/zen/tab-tree/ZenTabMultiSelectDrag.mjs`
- Modify: `src/zen/tab-tree/zen-tab-tree.css`
- Create: `src/zen/tests/tab-tree/browser_middledrag_select.js`
- Modify: `src/zen/tests/tab-tree/browser.toml`

Background (verbatim): the tab strip element is `#tabbrowser-tabs` (`MozTabbrowserTabs`). Multi-select API on `gBrowser`: `addToMultiSelectedTabs(tab)`, `addRangeToMultiSelectedTabs(tab1, tab2)` (selects the visible range inclusive), `removeFromMultiSelectedTabs(tab)`, `clearMultiSelectedTabs()`, `removeTabs(tabs, opts)`, getter `selectedTabs`. Native middle-click-close lives in `tabs.js` on the click handler for `event.button == 1` in the BUBBLING phase; we own the gesture on tabs and replicate close.

- [ ] **Step 1: Register the test** — add `["browser_middledrag_select.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_middledrag_select.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

function middle(tab, type, extra = {}) {
  EventUtils.synthesizeMouseAtCenter(
    tab,
    { type, button: 1, ...extra },
    window
  );
}

add_task(async function test_middle_drag_selects_range() {
  const t1 = await addNormalTab();
  const t2 = await addNormalTab();
  const t3 = await addNormalTab();
  gBrowser.clearMultiSelectedTabs();

  middle(t1, "mousedown");
  // Move onto t3 to drag-select the t1..t3 range.
  EventUtils.synthesizeMouseAtCenter(t3, { type: "mousemove", button: 1 }, window);

  Assert.ok(t1.multiselected, "t1 selected");
  Assert.ok(t2.multiselected, "t2 selected (in range)");
  Assert.ok(t3.multiselected, "t3 selected");

  // End the gesture without closing (abort path tested separately): press
  // Escape to cancel.
  EventUtils.synthesizeKey("KEY_Escape", {}, window);
  gBrowser.clearMultiSelectedTabs();
  await cleanupTabs(t1, t2, t3);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_middledrag_select.js`
Expected: FAIL — no selection occurs (gesture not implemented).

- [ ] **Step 4: Implement the gesture skeleton** — replace `nsZenTabMultiSelectDrag`'s body with:

```javascript
class nsZenTabMultiSelectDrag extends nsZenDOMOperatedFeature {
  #enabled = false;
  #strip = null;
  #state = null; // null | { anchor, startX, startY, dragging, aborted }
  static #THRESHOLD = 4; // px before a click becomes a drag

  init() {
    this.#enabled = Services.prefs.getBoolPref(
      "zen.tabs.middle-drag-select.enabled",
      true
    );
    if (!this.#enabled) {
      return;
    }
    this.#strip = document.getElementById("tabbrowser-tabs");
    if (!this.#strip) {
      return;
    }
    // Capture phase so we run before the native middle-click-close handler.
    this.#strip.addEventListener("mousedown", this, true);
  }

  handleEvent(event) {
    switch (event.type) {
      case "mousedown":
        this.#onMouseDown(event);
        break;
      case "mousemove":
        this.#onMouseMove(event);
        break;
      case "mouseup":
        this.#onMouseUp(event);
        break;
      case "contextmenu":
        this.#onContextMenu(event);
        break;
      case "keydown":
        if (event.key === "Escape") {
          this.#cancel();
        }
        break;
    }
  }

  #tabFrom(event) {
    return event.target?.closest?.(".tabbrowser-tab") || null;
  }

  #onMouseDown(event) {
    if (event.button !== 1) {
      return; // middle button only
    }
    const tab = this.#tabFrom(event);
    if (!tab) {
      return; // let native "open tab on empty space" behavior run
    }
    // Own the middle button on tabs: stop autoscroll + native close.
    event.preventDefault();
    event.stopPropagation();

    this.#state = {
      anchor: tab,
      startX: event.screenX,
      startY: event.screenY,
      dragging: false,
      aborted: false,
      additive: event.getModifierState("Accel"),
    };
    window.addEventListener("mousemove", this, true);
    window.addEventListener("mouseup", this, true);
    window.addEventListener("contextmenu", this, true);
    window.addEventListener("keydown", this, true);
  }

  #onMouseMove(event) {
    const s = this.#state;
    if (!s || s.aborted) {
      return;
    }
    if (!s.dragging) {
      const moved =
        Math.abs(event.screenX - s.startX) +
        Math.abs(event.screenY - s.startY);
      if (moved < nsZenTabMultiSelectDrag.#THRESHOLD) {
        return;
      }
      s.dragging = true;
      if (!s.additive) {
        gBrowser.clearMultiSelectedTabs();
      }
    }
    const over =
      event.target?.closest?.(".tabbrowser-tab") ||
      this.#tabUnderPoint(event.clientX, event.clientY);
    if (!over) {
      return;
    }
    // Rebuild range from anchor each move so shrinking the drag deselects.
    if (!s.additive) {
      gBrowser.clearMultiSelectedTabs();
    }
    gBrowser.addToMultiSelectedTabs(s.anchor);
    if (over !== s.anchor) {
      gBrowser.addRangeToMultiSelectedTabs(s.anchor, over);
    }
    this.#markPendingClose();
  }

  #tabUnderPoint(x, y) {
    const el = document.elementFromPoint(x, y);
    return el?.closest?.(".tabbrowser-tab") || null;
  }

  #markPendingClose() {
    for (const tab of gBrowser.tabs) {
      tab.toggleAttribute(
        "zen-pending-close",
        !this.#state?.aborted && tab.multiselected
      );
    }
  }

  #clearPendingClose() {
    for (const tab of gBrowser.tabs) {
      tab.removeAttribute("zen-pending-close");
    }
  }

  #onMouseUp(event) {
    if (event.button !== 1) {
      return;
    }
    // Behavior filled in Task 14.
    this.#cancel();
  }

  #onContextMenu(_event) {
    // Abort behavior filled in Task 14.
  }

  #cancel() {
    this.#clearPendingClose();
    window.removeEventListener("mousemove", this, true);
    window.removeEventListener("mouseup", this, true);
    window.removeEventListener("contextmenu", this, true);
    window.removeEventListener("keydown", this, true);
    this.#state = null;
  }
}

window.gZenTabMultiSelectDrag = new nsZenTabMultiSelectDrag();
```

- [ ] **Step 5: Add the pending-close CSS** — append to `src/zen/tab-tree/zen-tab-tree.css`:

```css
/* Visual hint that releasing the middle button will close these tabs. */
.tabbrowser-tab[zen-pending-close] {
  outline: 1px solid color-mix(in srgb, red 60%, transparent);
  outline-offset: -1px;
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_middledrag_select.js`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/zen/tab-tree/ZenTabMultiSelectDrag.mjs src/zen/tab-tree/zen-tab-tree.css src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): middle-mouse drag range selection"
```

---

### Task 14: Release-closes, right-click-aborts-to-context-menu, clean-click-closes-one

**Files:**
- Modify: `src/zen/tab-tree/ZenTabMultiSelectDrag.mjs`
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_middledrag_actions.js`

Background (verbatim): tab context menu is `#tabContextMenu` (`document.getElementById("tabContextMenu")`); each tab has `context="tabContextMenu"`. Multiple tabs close with `gBrowser.removeTabs(tabs, {animate:true})`; a single tab with `gBrowser.removeTab(tab, {animate:true})`.

- [ ] **Step 1: Register the test** — add `["browser_middledrag_actions.js"]` to `browser.toml`.

- [ ] **Step 2: Write the failing test** `src/zen/tests/tab-tree/browser_middledrag_actions.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_release_closes_selected_range() {
  const t1 = await addNormalTab();
  const t2 = await addNormalTab();
  const t3 = await addNormalTab();
  gBrowser.clearMultiSelectedTabs();

  EventUtils.synthesizeMouseAtCenter(t1, { type: "mousedown", button: 1 }, window);
  EventUtils.synthesizeMouseAtCenter(t3, { type: "mousemove", button: 1 }, window);
  const c1 = BrowserTestUtils.waitForTabClosing(t1);
  const c3 = BrowserTestUtils.waitForTabClosing(t3);
  EventUtils.synthesizeMouseAtCenter(t3, { type: "mouseup", button: 1 }, window);
  await Promise.all([c1, c3]);
  ok(t1.closing || !t1.isConnected, "t1 closed on release");
  ok(t3.closing || !t3.isConnected, "t3 closed on release");

  await cleanupTabs(t1, t2, t3);
});

add_task(async function test_rightclick_aborts_and_opens_menu() {
  const t1 = await addNormalTab();
  const t2 = await addNormalTab();
  gBrowser.clearMultiSelectedTabs();

  EventUtils.synthesizeMouseAtCenter(t1, { type: "mousedown", button: 1 }, window);
  EventUtils.synthesizeMouseAtCenter(t2, { type: "mousemove", button: 1 }, window);

  const menu = document.getElementById("tabContextMenu");
  const shown = BrowserTestUtils.waitForEvent(menu, "popupshown");
  EventUtils.synthesizeMouseAtCenter(t2, { type: "contextmenu", button: 2 }, window);
  await shown;
  ok(true, "context menu opened on right-click during middle-drag");

  // After abort, releasing middle does nothing (tabs stay open).
  EventUtils.synthesizeMouseAtCenter(t2, { type: "mouseup", button: 1 }, window);
  ok(t1.isConnected && t2.isConnected, "tabs not closed after abort");

  menu.hidePopup();
  gBrowser.clearMultiSelectedTabs();
  await cleanupTabs(t1, t2);
});

add_task(async function test_clean_middleclick_closes_one() {
  const t1 = await addNormalTab();
  gBrowser.clearMultiSelectedTabs();
  const closing = BrowserTestUtils.waitForTabClosing(t1);
  EventUtils.synthesizeMouseAtCenter(t1, { type: "mousedown", button: 1 }, window);
  EventUtils.synthesizeMouseAtCenter(t1, { type: "mouseup", button: 1 }, window);
  await closing;
  ok(t1.closing || !t1.isConnected, "clean middle-click closes the single tab");
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npm run build && npm test -- tab-tree/browser_middledrag_actions.js`
Expected: FAIL — nothing closes / no menu (handlers are stubs).

- [ ] **Step 4: Implement the up/contextmenu handlers** — replace `#onMouseUp` and `#onContextMenu` in `nsZenTabMultiSelectDrag`:

```javascript
  #onMouseUp(event) {
    if (event.button !== 1) {
      return;
    }
    const s = this.#state;
    if (!s) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();

    if (s.aborted) {
      this.#cancel(); // right-click already handled the gesture
      return;
    }

    if (!s.dragging) {
      // Clean middle-click: replicate native single-tab close.
      const tab = s.anchor;
      this.#cancel();
      if (tab?.isConnected) {
        if (tab.multiselected) {
          gBrowser.removeMultiSelectedTabs();
        } else {
          gBrowser.removeTab(tab, { animate: true });
        }
      }
      return;
    }

    // Drag release: close the whole selection.
    const toClose = gBrowser.selectedTabs.filter(
      t => t.isConnected && !t.closing
    );
    this.#cancel();
    if (toClose.length) {
      gBrowser.removeTabs(toClose, { animate: true });
    }
  }

  #onContextMenu(event) {
    const s = this.#state;
    if (!s || !s.dragging) {
      return;
    }
    // Abort the close; open the context menu on the current selection.
    event.preventDefault();
    event.stopPropagation();
    s.aborted = true;
    this.#clearPendingClose();

    const menu = document.getElementById("tabContextMenu");
    menu.openPopupAtScreen(event.screenX, event.screenY, true);
    // Keep selection; subsequent middle mouseup is a no-op (handled above).
  }
```

   Note on `removeMultiSelectedTabs`: it exists on `gBrowser` (used by the native middle-click path). If a clean middle-click lands on a multiselected tab, this closes the whole selection, matching native behavior.

- [ ] **Step 5: Run to verify it passes**

Run: `npm run build && npm test -- tab-tree/browser_middledrag_actions.js`
Expected: PASS (all three tasks).

- [ ] **Step 6: Manual QA** — `npm start`: middle-drag across several tabs (range highlights with red outline), release → all close; middle-drag then right-click before releasing → context menu opens, tabs stay; middle-click a single tab → closes just it; middle-click empty strip space → still opens a new tab (native behavior intact, since we only engage on tabs).

- [ ] **Step 7: Commit**

```bash
git add src/zen/tab-tree/ZenTabMultiSelectDrag.mjs src/zen/tests/tab-tree/
git commit -m "feat(tab-tree): middle-drag release-to-close, right-click abort, single-click close"
```

---

## Phase 8 — Exclusions, full QA, polish

### Task 15: Exclusion tests, full suite, lint, manual QA matrix

**Files:**
- Modify: `src/zen/tests/tab-tree/browser.toml`
- Create: `src/zen/tests/tab-tree/browser_tree_exclusions.js`

- [ ] **Step 1: Register the test** — add `["browser_tree_exclusions.js"]` to `browser.toml`.

- [ ] **Step 2: Write the exclusions test** `src/zen/tests/tab-tree/browser_tree_exclusions.js`

```javascript
/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_pinned_tab_is_not_tree_eligible() {
  const tab = await addNormalTab();
  gBrowser.pinTab(tab);
  await TestUtils.waitForCondition(() => tab.pinned);
  ok(!gZenTabTree.isTreeEligible(tab), "pinned tab excluded from tree");
  gBrowser.unpinTab(tab);
  await cleanupTabs(tab);
});

add_task(async function test_nest_rejects_ineligible_target() {
  const normal = await addNormalTab();
  const pinned = await addNormalTab();
  gBrowser.pinTab(pinned);
  await TestUtils.waitForCondition(() => pinned.pinned);

  Assert.equal(
    gZenTabTree.nestTab(normal, pinned),
    false,
    "cannot nest under a pinned (ineligible) tab"
  );
  Assert.equal(gZenTabTree.getParent(normal), null, "no relationship created");

  gBrowser.unpinTab(pinned);
  await cleanupTabs(normal, pinned);
});

add_task(async function test_cannot_nest_into_own_descendant() {
  const a = await addNormalTab();
  const b = await addNormalTab();
  gZenTabTree.nestTab(b, a); // a > b
  Assert.equal(
    gZenTabTree.nestTab(a, b),
    false,
    "nesting an ancestor under its descendant is rejected (no cycle)"
  );
  await cleanupTabs(a, b);
});
```

- [ ] **Step 3: Run the exclusions test**

Run: `npm run build && npm test -- tab-tree/browser_tree_exclusions.js`
Expected: PASS.

- [ ] **Step 4: Run the FULL tree + window-sync suites**

Run: `npm test -- tab-tree`
Then: `npm test -- window_sync`
Expected: ALL PASS. If any fail, fix before continuing (do not mark complete with failing tests).

- [ ] **Step 5: Run lint**

Run: `npm run lint`
Expected: no errors in `src/zen/tab-tree/`, `src/zen/drag-and-drop/ZenDragAndDrop.js`, `src/zen/sessionstore/ZenWindowSync.sys.mjs`, `src/zen/common/modules/ZenSessionStore.mjs`. Fix with `npm run lint:fix` where safe.

- [ ] **Step 6: Run adjacent regression suites** (these features touch shared drag/session code)

Run: `npm test -- folders`
Then: `npm test -- split_view`
Then: `npm test -- tabs`
Expected: PASS (no regressions to folders, split view, or general tab behavior).

- [ ] **Step 7: Manual QA matrix** (`npm start`) — verify and note results:
  - Quick drag tab → nests; hold → split; gap → reorder.
  - Drag a parent → whole subtree moves, hierarchy preserved.
  - Drag a multi-selection onto a tab → all become direct children.
  - Nest beyond `max-depth` (set pref to 2) → deepest flattens, nothing lost.
  - Collapse/expand twisty hides/shows subtree; active tab in collapsed subtree → selection jumps to ancestor.
  - Open link-in-new-tab from a tab → child appears nested (pref on); turn pref off → not nested.
  - Close a parent → children promote (default) / close-subtree (pref).
  - Pin a parent → it leaves the tree, children promote.
  - Restart with session restore → tree + collapse restored.
  - Two synced windows → nest/collapse/close replicate.
  - Middle-drag select+release closes; right-click aborts to menu; single middle-click closes one; middle-click empty space opens a tab.

- [ ] **Step 8: Final commit**

```bash
git add src/zen/tests/tab-tree/
git commit -m "test(tab-tree): exclusions + cycle guards; full QA pass"
```

- [ ] **Step 9: Push the branch and open a draft PR** (only if the user asks to publish)

```bash
git push -u origin feat/tree-style-tabs
gh pr create --base dev --draft --title "Native tree-style tabs + middle-mouse drag-select" --body "Implements docs/plans/2026-06-04-tree-style-tabs-design.md"
```

---

## Notes for the implementer

- **DFS invariant is sacred.** Every tab move that the tree performs goes through `#moveSubtreeAfter` (which guards `_suppressMoveHandling`). External reorders are caught by `on_TabMove → #reparentFromNeighbor`. If you add a new mutation, route it through `nestTab`/`detachTab`/`promoteSubtree` so ordering, levels, indent, twisty, and sync all update together.
- **Workspaces.** Tree relationships only span tabs sharing the same `zen-workspace-id`; `nestTab` enforces this. When a tab changes workspace, it should detach — if you find a `TabAttrModified`/workspace-change event, add a guard that calls `detachTab` when `zen-workspace-id` changes. (Add as a follow-up if not surfaced by QA.)
- **Property name discipline.** The persisted/synced mirror is the attribute `zen-tree-parent-id`; the live pointer is the property `_zenTreeParent`. `rebuildFromAttributes()` is the one place that converts attribute → pointer (used by both restore and sync).
- **`tab.owner` vs `tab.openerTab`.** Task 8 uses `tab.owner`; verify against the running build and switch to `openerTab` if `owner` is null for background opens.
- **If `#delegateGenericSyncEvent` signature differs** from `(aEvent, flags)`, match the actual signature found in `ZenWindowSync.sys.mjs` (it is used by `on_TabMove` right above where you add `on_ZenTreeChanged`).

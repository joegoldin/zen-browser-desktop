---
name: building-and-testing-zen
description: Use when building, running, linting, or writing browser-chrome tests for the Zen browser engine in this repo — devenv toolchain, mach build / build faster, surfer import/patches, en-US locale packaging, registering Zen chrome components, and diagnosing build/test errors (missing libxul.so, "Couldn't find a message", "patch does not apply", window_sync failures, hung about:blank tabs, uncaught ZenGlance rejections).
---

# Building and Testing Zen

Zen is a Firefox fork built with **surfer** (gluon). Source lives in `src/`; the
Firefox checkout + build output lives in `engine/` (git-ignored, its own git
repo whose HEAD is pristine Firefox). The toolchain only exists inside the
**devenv shell**.

## Run everything through devenv

`node`, `npm`, `cargo`, `rustc`, `mach`, `surfer` are NOT on the normal PATH —
they come from `devenv.nix`. Wrap commands:

```bash
devenv shell -- bash -c 'cd engine && ./mach <cmd>'
```

`devenv.nix` provides the toolchain + `firefox-unwrapped.buildInputs` (GTK/X/NSS/…)
and sets `LD_LIBRARY_PATH` for libstdc++. If a built binary fails with
`error while loading shared libraries: libgtk-3.so.0 / libstdc++.so.6`, the GUI
lib dirs aren't on `LD_LIBRARY_PATH` at run time — fix devenv, not the code.

## The mochitest proxy (ssltunnel) — the biggest test gotcha

Symptom: many URL-loading tests **time out ~47s** with `the window unloaded
while we were waiting for the browser to load`, and (non-headless) the test
browser shows **"The proxy server is refusing connections … example.com"**.
`about:blank`-only tests (e.g. `tab-tree`) pass — that's the tell.

Cause: the mochitest runner launches helper binaries (notably **`ssltunnel`**,
the SSL proxy that routes `https://example.com` / `mochi.test` to the local test
server) with a **sanitized env that drops `LD_LIBRARY_PATH`**, so ssltunnel
can't load libstdc++ (`ssltunnel: error while loading shared libraries:
libstdc++.so.6`), the proxy refuses connections, and every test that loads a real
URL hangs. NOT a `--headless` problem, NOT your code.

Fix: embed the lib path into ssltunnel's RUNPATH (env-independent). **`devenv.nix`
now does this automatically on shell entry** (`patchelf --add-rpath` on
`engine/obj-*/dist/bin/ssltunnel`). A full `mach build` rebuilds ssltunnel — just
re-enter the shell (or run the next `devenv shell`/`npm test`, which re-applies).
Manual one-off: `patchelf --add-rpath "$ORIGIN:<gcc-lib>/lib" <objdir>/dist/bin/ssltunnel`.

## src ↔ engine model (read this first)

- `engine/zen/*` and the Zen-authored `engine/browser/...` files are **symlinks
  to `src/...`** — your edits are live immediately; you only need to repackage.
- Firefox's own files are **patched in place** (real files) from `src/**/*.patch`.
- **Do NOT re-run `npm run import`** on an already-built engine. It re-applies all
  ~246 patches and is not idempotent — it fails on already-applied patches
  (e.g. `D284084.patch`). It's the wrong tool for iterating.
- To change a Firefox patch: `git -C engine checkout -- <target-file>` to restore
  pristine, then `git -C engine apply src/**/X.patch`. When editing a `.patch`,
  fix the hunk header counts `@@ -a,b +c,d @@` (b = orig context+removed,
  d = context+added) or it won't apply.

## Building

| Goal | Command | Notes |
|---|---|---|
| Full build (once) | `cd engine && ./mach build` | Long. Produces `dist/bin/libxul.so` + `dist/bin/zen`. |
| Front-end only | `cd engine && ./mach build faster` | ~20s. Use after editing src/zen, Zen browser content, **tests**, prefs, ZenPreloadedScripts. |

**Export `MOZCONFIG` when you call `mach` directly.** `surfer build` sets it for
you; `./mach build` does not, and there is no `engine/mozconfig` to fall back on,
so configure silently runs without the devenv gating in
`configs/linux/mozconfig` and dies with `Could not find libclang ...` (the
`--with-libclang-path` line never ran). Always:

```bash
devenv shell -- bash -c 'cd engine && MOZCONFIG=$DEVENV_ROOT/configs/linux/mozconfig ./mach build'
```

`mach build faster` **requires a prior full build** — if it errors
`No rule to make target 'libxul.so'`, run the full `mach build` first.

### Re-basing onto a new Firefox version

`surfer download` + `npm run import` re-fetch and re-patch from scratch (this is
the one time re-importing is correct — see the src↔engine section). Bumping the
base can also outgrow the pinned toolchain: Firefox 153 requires
**cbindgen >= 0.29.4**, and configure fails with `cbindgen version ... is too
old` until `devenv.nix` supplies it.

## en-US locale (critical, easy to miss)

Zen's English strings live in `locales/en-US/browser/browser/zen-*.ftl` but must
be copied into the build. **`devenv.nix` enterShell now does this automatically**
when they're missing; the manual command is:

```bash
python3 scripts/update_en_US_packs.py   # from repo root, then rebuild
```

If skipped, the browser/tests throw `Missing resource in locale en-US:
browser/zen-*.ftl` and `Couldn't find a message: ...`. These surface as
**uncaught rejections in new-window UI** and break the `window_sync` tests.

## Registering a new Zen chrome component (.mjs)

A component isn't loaded until ALL of these are done (the loader is the one
people forget — without it `window.gYourThing` is `undefined`):

1. `src/zen/<area>/jar.inc.mn`: `content/browser/zen-components/X.mjs (../../zen/<area>/X.mjs)`
2. `#include` that jar from `src/browser/base/content/zen-assets.jar.inc.mn`
3. CSS: `<link>` in `src/browser/base/content/zen-assets.inc.xhtml`
4. eslint globals: add the `gX` name to `src/zen/zen.globals.mjs`
5. **Loader (the gotcha):** add the chrome URL to the `scripts` array in
   `src/zen/common/ZenPreloadedScripts.js` — this is what actually
   `importESModule`s the component so its `window.gX = new nsX()` runs.

Manager pattern: `class nsX extends nsZenDOMOperatedFeature` (auto-`init()` on
`DOMContentLoaded`); end the file with `window.gX = new nsX();`. Make state
access null-safe (`tab?.…`) — `pinTab`/`removeTab` fire `TabMove`/`TabClose`
during teardown.

Per-tab persisted state: collect in
`src/browser/components/sessionstore/TabState-sys-mjs.patch`
(`tabData.zenX = tab.getAttribute("zen-x")`), restore in `restoreInitialTabData`
(`src/zen/common/modules/ZenSessionStore.mjs`) + the SessionStore restore patch.
Window sync: add a `SYNC_FLAG_X`, an `EVENTS` entry + `on_<Event>` handler, and a
copy block in `#syncItemWithOriginal` in `src/zen/sessionstore/ZenWindowSync.sys.mjs`.

## Testing (browser-chrome mochitests)

```bash
npm test -- <path-under-zen/tests> --headless    # ALWAYS --headless
# e.g.  npm test -- tab-tree --headless           (whole dir)
#       npm test -- folders/browser_folder_create.js --headless
```

Maps to `./mach test zen/tests/<path>`. Redirect output to a file under
`artifacts/` and grep it — never pipe `mach` through `tail`/`head` (you'll
re-run a slow command). Register a new dir's `browser.toml` in
`src/zen/tests/moz.build`; the toml lists `["browser_x.js"]` and
`support-files = ["head.js"]`.

### Test gotchas (all verified painfully)

- **`about:blank` + `browserLoaded()` hangs** (the load already fired). Just
  `BrowserTestUtils.addTab(gBrowser, "about:blank", {skipAnimation:true})` and
  use it — don't await `browserLoaded`.
- **Import test globals you use**, e.g.
  `const { TabStateFlusher } = ChromeUtils.importESModule("resource:///modules/sessionstore/TabStateFlusher.sys.mjs")`.
- **Benign pre-existing rejections fail tests** via `assertNoUncaughtRejections`:
  the ZenGlance actor teardown on tab close (`destroyed before query`) and, if
  the locale isn't built, Fluent `Couldn't find a message`. Whitelist them in
  `head.js` — **register inside `add_setup`**, not at top level (top-level lands
  in the wrong PromiseTestUtils scope and silently does nothing):
  ```js
  const { PromiseTestUtils } = ChromeUtils.importESModule(
    "resource://testing-common/PromiseTestUtils.sys.mjs"
  );
  add_setup(() =>
    PromiseTestUtils.allowMatchingRejectionsGlobally(
      /destroyed before query|Couldn't find a message/
    )
  );
  ```
- **window_sync tests**: window-sync works, but it mirrors the synced window's
  blank tab into the main window. Snapshot `new Set(gBrowser.tabs)` at the start
  and remove extras at the end, or you'll fail with "Found an unexpected tab".
- **Ignore the noise**: `TypeError: Property 'handleEvent' is not callable`, the
  l10n console errors, and `EmptyDatabaseError: nimbus-…` are pre-existing and
  harmless.

## Lint

```bash
npm run lint        # = ./mach lint zen   (operates on engine/, post-import)
```

## Quick fault table

| Symptom | Cause / fix |
|---|---|
| `No rule to make target 'libxul.so'` | No full build yet → `./mach build` |
| `libgtk-3.so.0 / libstdc++.so.6` not found | runtime `LD_LIBRARY_PATH` missing GUI libs → fix devenv |
| `Couldn't find a message` / `Missing resource ... zen-*.ftl` | run `python3 scripts/update_en_US_packs.py` + rebuild |
| `patch does not apply` during `npm run import` | engine already patched; don't re-import — restore the file pristine + `git -C engine apply` the one patch |
| `window.gX is undefined` | component not added to `ZenPreloadedScripts.js` |
| many URL-loading tests time out ~47s; "window unloaded while waiting for browser to load"; "proxy refusing connections at example.com" | `ssltunnel` can't load libstdc++ → fixed by devenv enterShell (patchelf rpath); a full `mach build` rebuilds it, re-enter the shell |
| one test hangs ~47s on `addNormalTab`/a tab open | `browserLoaded()` on `about:blank` — don't await it |
| test fails on `assertNoUncaughtRejections` | whitelist benign rejection via `add_setup` |
| `Found an unexpected tab` in window_sync | clean up the sync-mirrored blank tab |

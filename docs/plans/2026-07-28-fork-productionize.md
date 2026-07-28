# Fork Productionization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the fork from a working branch into a maintained product: cached Nix builds, an automated upstream merge that cannot destroy the fork, versioned releases, and installable Linux packages.

**Architecture:** Two non-overlapping pipelines. The self-hosted garnix instance builds the Nix flake and fills the binary cache, which is the only thing GitHub Actions structurally cannot do. GitHub runners produce every conventional artifact (tarball, deb, rpm, and later macOS/Windows), because upstream's Linux build already emits a relocatable tree while a Nix build hard-codes `/nix/store` into the ELF.

**Tech Stack:** Nix flakes, garnix CI, GitHub Actions, `fpm` for deb/rpm, Arch PKGBUILD.

## Global Constraints

- **Never build `aarch64-linux` in CI.** The only registered aarch64 builder is a 2-core box with `maxJobs = 1`. `builds.include` names x86_64 attributes explicitly.
- **Never reset `dev`.** `dev` is the product branch. Upstream arrives by merge only. A reset destroys the fork.
- **App identity stays identical to upstream Zen**: `appId: "zen"`, `binaryName: "zen"` in `surfer.json`. Do not change these.
- **Fork version format:** `<upstream-tag>-tst.<n>`, currently `1.21.9b-tst.1`.
- **Regression gate after any upstream merge:** `mach lint zen` clean, tab-tree 142/0, window_sync 28/0, space_routing 23283/0.
- **Run everything through devenv:** `devenv shell -- bash -c '<cmd>'`. `node`, `npm`, `mach` are not on the normal PATH.

---

### Task 1: Scope garnix to the x86_64 flake build

Without a `garnix.yaml` the repo runs on garnix defaults, building everything matching `*.x86_64-linux.*` plus the devShell. Scoping it makes the aarch64 exclusion explicit rather than incidental, and stops the devShell being rebuilt on every push.

**Files:**
- Create: `garnix.yaml`

**Interfaces:**
- Consumes: `packages.x86_64-linux.zen-browser-unwrapped` from `flake.nix`
- Produces: cached closures on the garnix binary cache; no artifacts

- [ ] **Step 1: Confirm the attribute name the flake actually exposes**

```bash
cd /home/joe/Development/zen-browser-desktop
git show origin/dev:flake.nix | grep -A3 "inherit zen-browser-unwrapped"
```

Expected: shows `zen-browser-unwrapped` and `default` under `packages`.

- [ ] **Step 2: Create `garnix.yaml`**

```yaml
# The self-hosted garnix instance builds this flake and uploads the closure to
# its binary cache, so every machine in the fleet downloads Zen instead of
# spending hours compiling it. That cache is the entire reason this repo is on
# garnix; conventional artifacts (tarball, deb, rpm, macOS, Windows) come from
# GitHub Actions instead, because a Nix build hard-codes /nix/store paths into
# the ELF interpreter and RPATH and will not run on a machine without a Nix
# store.
#
# x86_64 only, deliberately. The only registered aarch64 builder is a two-core
# box running maxJobs = 1 that is shared with game servers, so a Firefox build
# dispatched there would grind for days. The flake still declares
# aarch64-linux so that platform can build locally; CI stays away from it.
builds:
  include:
    - "packages.x86_64-linux.zen-browser-unwrapped"
```

- [ ] **Step 3: Verify the attribute resolves before pushing**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly
nix eval --raw .#packages.x86_64-linux.zen-browser-unwrapped.drvPath
```

Expected: a `/nix/store/...-zen-browser-unwrapped-<version>.drv` path. If this errors, `garnix.yaml` names an attribute that does not exist and every push will fail evaluation.

- [ ] **Step 4: Commit**

```bash
git add garnix.yaml
git commit -m "ci: scope garnix to the x86_64 flake build

The cache is the point: a push builds Zen once on erdtree and every other
machine downloads the closure instead of compiling for hours. Naming the
attribute explicitly also keeps CI off aarch64-linux, whose only registered
builder is a two-core box running maxJobs = 1."
```

- [ ] **Step 5: Push and confirm garnix picks it up**

```bash
git push origin HEAD:dev
```

Then check the build appears at `<garnixDomain>` for this repo. Expected: one build for `zen-browser-unwrapped`, not a fan-out including the devShell. If it sits at "Build starting" indefinitely, the per-repo build timeout is still 1 h and needs raising on the Configure page.

---

### Task 2: Fix the stale `zen-version` and adopt the `-tst` suffix

`zen-version` on `dev` is `1.20.2b`, which is wrong twice over: upstream's current tag is `1.21.9b`, and the fork needs a distinguishing suffix. This value names the Nix store path and the reported application version.

**Files:**
- Modify: `nix/zen-browser.nix:76`

**Interfaces:**
- Consumes: nothing
- Produces: `zen-version = "1.21.9b-tst.1"`, consumed by `nix/package.nix` as `packageVersion`

- [ ] **Step 1: Confirm the current stale value**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly
grep -n "zen-version =" nix/zen-browser.nix
```

Expected: `zen-version = "1.20.2b";`

- [ ] **Step 2: Set the fork version**

Replace that line with:

```nix
  # Zen's own version lives in the release tag rather than a tracked file
  # (package.json is a placeholder 1.0.0), so this is hand-maintained and wants
  # bumping alongside an upstream release. The -tst suffix marks this as the
  # tree-style-tabs fork and increments for fork-only fixes between upstream
  # releases. It names the store path and the reported application version; the
  # Firefox base is read from surfer.json and stays correct on its own.
  zen-version = "1.21.9b-tst.1";
```

- [ ] **Step 3: Verify the derivation name changes**

```bash
nix eval --raw .#packages.x86_64-linux.zen-browser-unwrapped.name
```

Expected: `zen-browser-unwrapped-1.21.9b-tst.1`

- [ ] **Step 4: Commit**

```bash
git add nix/zen-browser.nix
git commit -m "nix: set the fork version to 1.21.9b-tst.1

zen-version was still 1.20.2b, two upstream releases behind, and carried no
marker distinguishing fork builds from upstream ones. The suffix increments
for fork-only fixes between upstream releases."
```

---

### Task 3: Merge-only upstream sync workflow

The workflow that used to do this reset `dev` to upstream and replayed one commit on top. That design would now destroy the fork. The replacement only ever merges, never pushes to `dev`, and stops for a human exactly when the patch files conflict.

**Files:**
- Create: `.github/workflows/merge-upstream-zen.yml`

**Interfaces:**
- Consumes: `upstream/dev` from `zen-browser/desktop`
- Produces: a `sync/upstream-<date>` branch and a PR against `dev`

- [ ] **Step 1: Create the workflow**

```yaml
# Merges upstream Zen into this fork's dev.
#
# Named merge-upstream-zen, NOT sync-upstream: upstream already ships a
# sync-upstream.yml that pulls new Firefox point releases into Zen, and
# check-candidate-release.yml calls it as a reusable workflow. Overwriting it
# breaks that caller.
#
# This NEVER pushes to dev and NEVER resets it. The job it replaces reset dev
# to upstream and replayed a single commit on top, which was correct when dev
# was a mirror and would now delete the entire fork. Everything lands on a
# branch behind a PR.
#
# A conflict here is expected on Firefox version bumps and is concentrated in
# four .patch files plus surfer.json. See
# docs/plans/2026-07-28-fork-maintenance-design.md for the resolution procedure.
name: Merge upstream Zen

on:
  schedule:
    - cron: "0 9 * * 1" # Mondays, ~02:00 America/Los_Angeles
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  merge-upstream:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout dev
        uses: actions/checkout@v4
        with:
          ref: dev
          fetch-depth: 0

      - name: Merge upstream/dev
        id: merge
        run: |
          set -uo pipefail
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git remote add upstream https://github.com/zen-browser/desktop.git
          git fetch upstream dev

          branch="sync/upstream-$(date -u +%Y-%m-%d)"
          git checkout -b "$branch"

          if git merge --no-edit upstream/dev; then
            echo "conflict=false" >> "$GITHUB_OUTPUT"
          else
            echo "conflict=true" >> "$GITHUB_OUTPUT"
            # Keep the conflict markers: the PR is a place for a human to
            # resolve them, not a report that something went wrong.
            git add -A
            git commit -m "WIP: upstream merge with conflicts to resolve"
          fi

          if [ -z "$(git log origin/dev..HEAD --oneline)" ]; then
            echo "empty=true" >> "$GITHUB_OUTPUT"
          else
            echo "empty=false" >> "$GITHUB_OUTPUT"
            git push origin "$branch"
          fi
          echo "branch=$branch" >> "$GITHUB_OUTPUT"

      - name: Open PR
        if: steps.merge.outputs.empty == 'false'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          CONFLICT: ${{ steps.merge.outputs.conflict }}
          BRANCH: ${{ steps.merge.outputs.branch }}
        run: |
          if [ "$CONFLICT" = "true" ]; then
            title="Upstream sync ($BRANCH) — CONFLICTS, needs resolution"
            body=$'This merge conflicted. The conflict markers are committed on the branch for you to resolve.\n\nConflicts on a Firefox bump are expected and concentrate in the four engine .patch files plus surfer.json. The resolution procedure, including the hunk renumbering and the validation step that catches a silently corrupt patch, is in docs/plans/2026-07-28-fork-maintenance-design.md.\n\nRun the full regression gate before merging.'
          else
            title="Upstream sync ($BRANCH)"
            body=$'Merged cleanly. A clean textual merge of a .patch file can still produce a patch that no longer applies, so run the regression gate before merging:\n\n```\ndevenv shell -- bash -c "npm run lint"\ndevenv shell -- bash -c "npm test -- tab-tree --headless"\ndevenv shell -- bash -c "npm test -- window_sync --headless"\ndevenv shell -- bash -c "npm test -- space_routing --headless"\n```'
          fi
          gh pr create --base dev --head "$BRANCH" --title "$title" --body "$body"
```

- [ ] **Step 2: Validate the YAML and the embedded shell**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/merge-upstream-zen.yml')); print('YAML OK')"
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/merge-upstream-zen.yml'))
print(d['jobs']['merge-upstream']['steps'][1]['run'])" | bash -n && echo "BASH OK"
```

Expected: `YAML OK` then `BASH OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/merge-upstream-zen.yml
git commit -m "ci: merge-only upstream sync

Replaces the deleted nightly-integration job, which reset dev to upstream and
replayed a commit on top. That was right when dev mirrored upstream and would
now delete the fork. This only ever merges, never pushes to dev, and opens a
PR either way so a conflicting Firefox bump stops for a human."
```

- [ ] **Step 4: Dry-run it**

```bash
gh workflow run merge-upstream-zen.yml --repo joegoldin/zen-browser-desktop
sleep 60
gh run list --repo joegoldin/zen-browser-desktop --workflow=merge-upstream-zen.yml --limit 1
```

Expected: success, and either no PR (dev already current) or a PR titled `Upstream sync (sync/upstream-<date>)`. Verify `dev` did not move:

```bash
git fetch origin && git rev-parse origin/dev
```

Expected: the same SHA as before the run.

---

### Task 4: Fork-owned Linux release workflow

Upstream's `linux-release-build.yml` cannot run here as-is. It is `workflow_call`-only so nothing triggers it, targets `blacksmith-8vcpu-ubuntu-2404` and `self-hosted` runners this fork does not have, requires several secrets the fork lacks, and runs a two-stage PGO build that roughly doubles an already long build.

**Files:**
- Create: `.github/workflows/fork-linux-release.yml`

**Interfaces:**
- Consumes: the repo at a given ref
- Produces: a GitHub Release asset `zen.linux-x86_64.tar.xz`, consumed by Task 5 and Task 6

- [ ] **Step 1: Read the sequence being copied**

```bash
cd /home/joe/Development/zen-browser-desktop
git show origin/dev:.github/workflows/linux-release-build.yml | sed -n '76,182p'
```

Note the order, which the workflow below reproduces: apt deps, `npm ci`, `npm run surfer -- ci` (this is what sets the displayed version), `npm run download`, rustup pinned to `.rust-toolchain`, `npm run import`, language packs, `mach bootstrap`, then the build, then `npm run package`.

Three things are deliberately dropped for the fork: both PGO stages (they need a profile-generation run and an X server, and `ZEN_GA_DISABLE_PGO` exists precisely to skip them), the `.mar` update artifacts (the fork has no update server), and the aarch64 matrix leg.

- [ ] **Step 2: Create the workflow**

```yaml
# Linux release build for the fork.
#
# Copied from upstream's linux-release-build.yml with four changes: it is
# workflow_dispatch rather than workflow_call so it can actually be triggered,
# it runs on a stock ubuntu-latest runner rather than blacksmith/self-hosted,
# it drops the aarch64 leg, and it sets ZEN_GA_DISABLE_PGO to skip the
# two-stage PGO build (which needs a profile-generation run under Xvfb and
# roughly doubles the build time).
#
# The tarball this produces is the base for the deb, the rpm and the AUR
# package. It is deliberately NOT the Nix build: a Nix build hard-codes
# /nix/store into the ELF interpreter and RPATH, so it cannot be repackaged
# for a machine without a Nix store.
name: Fork Linux release

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Fork version, e.g. 1.21.9b-tst.1"
        required: true
        type: string

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Free disk space
        uses: jlumbroso/free-disk-space@main
        with:
          tool-cache: false

      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version-file: ".nvmrc"

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y python3 python3-pip dos2unix yasm nasm build-essential \
            libgtk2.0-dev libpython3-dev m4 uuid libasound2-dev libcurl4-openssl-dev \
            libdbus-1-dev libdrm-dev libdbus-glib-1-dev libgtk-3-dev libpulse-dev \
            libx11-xcb-dev libxt-dev xvfb lld llvm

      - name: Install npm dependencies
        run: npm ci

      - name: Surfer CI setup
        run: npm run surfer -- ci --brand release --display-version ${{ inputs.version }}

      - name: Download Firefox source
        run: npm run download

      - name: Pin Rust toolchain
        run: |
          curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
            --default-toolchain $(cat .rust-toolchain)
          . "$HOME/.cargo/env"
          rustup target add x86_64-unknown-linux-gnu

      - name: Import the Zen patchset
        env:
          SURFER_COMPAT: x86_64
        run: |
          . "$HOME/.cargo/env"
          npm run import

      - name: Build language packs
        run: sh scripts/download-language-packs.sh

      - name: Bootstrap
        run: |
          cd engine
          export SURFER_PLATFORM="linux"
          ./mach --no-interactive bootstrap --application-choice browser
          cd ..

      - name: Build
        env:
          SURFER_COMPAT: x86_64
          ZEN_RELEASE_BRANCH: release
          ZEN_GA_DISABLE_PGO: 1
        run: |
          export SURFER_PLATFORM="linux"
          bash .github/workflows/src/release-build.sh

      - name: Package
        env:
          SURFER_COMPAT: x86_64
          ZEN_GA_DISABLE_PGO: true
        run: |
          export SURFER_PLATFORM="linux"
          export ZEN_RELEASE=1
          npm run package

      - name: Rename artifact
        run: mv dist/zen-*.tar.xz "zen.linux-x86_64.tar.xz"

      - name: Upload tarball
        uses: actions/upload-artifact@v4
        with:
          name: zen.linux-x86_64.tar.xz
          path: ./zen.linux-x86_64.tar.xz
          retention-days: 7

      - name: Publish release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          VERSION: ${{ inputs.version }}
        run: |
          gh release create "$VERSION" \
            --title "$VERSION" \
            --notes "Zen with native tree-style tabs. Unofficial fork of zen-browser/desktop." \
            ./zen.linux-x86_64.tar.xz
```

- [ ] **Step 3: Validate the YAML**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/fork-linux-release.yml')); print('steps:', len(d['jobs']['build']['steps']))"
```

Expected: `steps: 16`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/fork-linux-release.yml
git commit -m "ci: fork-owned Linux release build

Upstream's workflow is workflow_call-only, targets blacksmith and self-hosted
runners this fork does not have, and runs a two-stage PGO build needing a
profile-generation pass under Xvfb. Same sequence on a stock runner, x86_64
only, PGO disabled via the existing ZEN_GA_DISABLE_PGO switch, publishing the
tarball the deb, rpm and AUR package are all cut from."
```

- [ ] **Step 5: Run it and expect to iterate**

```bash
gh workflow run fork-linux-release.yml --repo joegoldin/zen-browser-desktop -f version=1.21.9b-tst.1
```

This is the step most likely to fail first. Three known hazards, in order of likelihood:

1. **`release-build.sh` runs `bash ./scripts/mar_sign.sh -i`**, which sets up MAR signing. If it fails without signing keys, the build stops there and the script needs that line guarded for the fork.
2. **The 6 h job limit.** A Firefox build without PGO should fit, but not by a wide margin.
3. **Disk**, even after the free-disk-space action.

If any of these bite, the fallback is a self-hosted runner on erdtree, which removes the time and disk constraints together. Do not proceed to Task 5 until a tarball exists.

### Task 5: deb and rpm from the tarball

`fpm` turns an extracted directory tree into both package formats. The tarball is already relocatable, which is exactly why the packages are cut from it rather than from the Nix build.

**Files:**
- Modify: `.github/workflows/fork-linux-release.yml` (add a `package` job)
- Create: `packaging/zen.desktop`

**Interfaces:**
- Consumes: the `zen.linux-x86_64.tar.xz` artifact from Task 4
- Produces: `zen-browser-tst_<version>_amd64.deb` and `zen-browser-tst-<version>-1.x86_64.rpm` attached to the same release

- [ ] **Step 1: Create the desktop entry**

```ini
[Desktop Entry]
Version=1.0
Name=Zen Browser
GenericName=Web Browser
Comment=Experience tranquillity while browsing the web
Exec=/opt/zen-tst/zen %U
Icon=/opt/zen-tst/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
Categories=Network;WebBrowser;
StartupWMClass=zen
```

- [ ] **Step 2: Add the packaging job to the workflow**

Append to `.github/workflows/fork-linux-release.yml`:

```yaml
  package:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Download tarball
        uses: actions/download-artifact@v4
        with:
          name: zen.linux-x86_64.tar.xz

      - name: Install fpm
        run: |
          sudo apt-get update
          sudo apt-get install -y ruby ruby-dev build-essential rpm
          sudo gem install --no-document fpm

      - name: Lay out the tree
        env:
          VERSION: ${{ inputs.version }}
        run: |
          set -euo pipefail
          mkdir -p root/opt/zen-tst root/usr/bin root/usr/share/applications
          tar -xJf zen.linux-x86_64.tar.xz -C root/opt/zen-tst --strip-components=1
          ln -s /opt/zen-tst/zen root/usr/bin/zen
          cp packaging/zen.desktop root/usr/share/applications/zen.desktop

      - name: Build deb and rpm
        env:
          VERSION: ${{ inputs.version }}
        run: |
          set -euo pipefail
          # fpm rejects a dash in an rpm version, so the -tst.N suffix moves
          # into the iteration field for rpm and stays in the version for deb.
          rpm_version="${VERSION%%-*}"
          rpm_iteration="${VERSION#*-}"
          for target in deb rpm; do
            if [ "$target" = "rpm" ]; then
              ver="$rpm_version"; iter="$rpm_iteration"
            else
              ver="$VERSION"; iter="1"
            fi
            fpm -s dir -t "$target" \
              -n zen-browser-tst \
              -v "$ver" \
              --iteration "$iter" \
              --description "Zen Browser with native tree-style tabs (unofficial fork)" \
              --url "https://github.com/joegoldin/zen-browser-desktop" \
              --license MPL-2.0 \
              --conflicts zen-browser \
              --provides zen-browser \
              -C root .
          done

      - name: Attach to release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          VERSION: ${{ inputs.version }}
        run: gh release upload "$VERSION" ./*.deb ./*.rpm
```

- [ ] **Step 3: Validate the YAML**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/fork-linux-release.yml')); print('jobs:', list(d['jobs']))"
```

Expected: `jobs: ['build', 'package']`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/fork-linux-release.yml packaging/zen.desktop
git commit -m "ci: build deb and rpm from the release tarball

fpm against the extracted tree. Cut from the tarball rather than the Nix build
because a Nix build hard-codes /nix/store into the ELF interpreter and RPATH
and will not start on a machine without a Nix store.

Both declare conflicts and provides against zen-browser: the fork keeps
upstream's binaryName, so it owns the same /usr/bin/zen path."
```

- [ ] **Step 5: Verify the packages actually install**

On a throwaway container, not the workstation:

```bash
podman run --rm -it -v "$PWD:/w" debian:12 bash -c \
  "dpkg -i /w/zen-browser-tst_*.deb 2>&1 | tail -5; ls -l /usr/bin/zen; /opt/zen-tst/zen --version"
```

Expected: the symlink exists and `--version` prints the Zen version. A missing shared library here means the tarball is less relocatable than assumed and the package needs its dependencies declared with `--depends`.

---

### Task 6: AUR `-bin` package

**Files:**
- Create: `packaging/aur/PKGBUILD`
- Create: `packaging/aur/README.md`

**Interfaces:**
- Consumes: the GitHub Release tarball from Task 4
- Produces: an installable Arch package

- [ ] **Step 1: Write the PKGBUILD**

```bash
# Maintainer: joegoldin <joe@joegold.in>
pkgname=zen-browser-tst-bin
_pkgname=zen-tst
pkgver=1.21.9b_tst.1
pkgrel=1
pkgdesc="Zen Browser with native tree-style tabs (unofficial fork)"
arch=('x86_64')
url="https://github.com/joegoldin/zen-browser-desktop"
license=('MPL-2.0')
# The fork keeps upstream's binaryName, so it owns the same /usr/bin/zen.
# Without these, pacman fails the install with a bare file-conflict error.
conflicts=('zen-browser' 'zen-browser-bin' 'zen-browser-avx2-bin')
provides=('zen-browser')
depends=('gtk3' 'libxt' 'mime-types' 'dbus-glib' 'nss' 'ttf-font' 'libpulse')
options=('!strip')
source=("https://github.com/joegoldin/zen-browser-desktop/releases/download/${pkgver//_/-}/zen.linux-x86_64.tar.xz")
sha256sums=('SKIP')

package() {
  install -d "$pkgdir/opt/$_pkgname"
  cp -r "$srcdir/zen/." "$pkgdir/opt/$_pkgname"
  install -d "$pkgdir/usr/bin"
  ln -s "/opt/$_pkgname/zen" "$pkgdir/usr/bin/zen"
  install -Dm644 "$pkgdir/opt/$_pkgname/browser/chrome/icons/default/default128.png" \
    "$pkgdir/usr/share/icons/hicolor/128x128/apps/zen.png"
}
```

- [ ] **Step 2: Write the packaging note**

`packaging/aur/README.md`:

```markdown
# AUR packaging

`zen-browser-tst-bin` installs the fork's release tarball to `/opt/zen-tst`
with a `/usr/bin/zen` symlink.

## Why `conflicts` and `provides`

The fork deliberately keeps upstream Zen's `appId` and `binaryName`, so it
installs to the same `/usr/bin/zen` path and shares the same profile
directory. `conflicts` makes that a clear message from pacman instead of a
bare file-conflict error, and `provides` lets packages depending on
`zen-browser` be satisfied by this one.

You cannot have both installed at once. That is intended.

## Version mapping

Arch forbids a dash in `pkgver`, so `1.21.9b-tst.1` becomes `1.21.9b_tst.1`
and `${pkgver//_/-}` converts it back when building the download URL.

## sha256sums

`SKIP` is a placeholder for the first build. Replace it with the real digest
of the published tarball before submitting, and update it on every release.
```

- [ ] **Step 3: Verify the PKGBUILD parses**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly/packaging/aur
bash -n PKGBUILD && echo "PKGBUILD syntax OK"
bash -c 'source PKGBUILD; echo "pkgver=$pkgver url=${source[0]}"'
```

Expected: syntax OK, and the source URL resolving to `.../releases/download/1.21.9b-tst.1/zen.linux-x86_64.tar.xz`.

- [ ] **Step 4: Commit**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly
git add packaging/aur/PKGBUILD packaging/aur/README.md
git commit -m "packaging: AUR -bin package sourcing the release tarball

Declares conflicts and provides against zen-browser because the fork keeps
upstream's binaryName and therefore owns the same /usr/bin/zen. Documents the
pkgver mapping, since Arch forbids the dash in 1.21.9b-tst.1."
```

---

### Task 7: README note on the shared profile

The fork keeps upstream's `appId`, so it shares a profile directory with stock Zen. Its tree attributes survive a round trip through upstream Zen as ignored data, which flattens the tree. That is surprising rather than destructive, and it needs saying.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Insert the fork notice after the badges**

Find the line beginning `[![Crowdin]` in `README.md` and insert immediately after that block:

```markdown
---

> ### Unofficial fork
>
> This is a fork of [zen-browser/desktop](https://github.com/zen-browser/desktop)
> that adds native tree-style tabs, which upstream
> [declined](https://github.com/zen-browser/desktop/pull/14746). It is not
> affiliated with or endorsed by the Zen team.
>
> It keeps upstream's application id and binary name, so it is a drop-in
> replacement and **shares the same profile directory as stock Zen**. Two
> consequences:
>
> - You cannot install both from a package manager; they own the same paths.
> - Opening the same profile in stock Zen works, but stock Zen ignores the
>   `zen-tree-*` attributes this fork stores, so a round trip through it
>   flattens the tab tree. Back up your profile before switching back and
>   forth.

---
```

- [ ] **Step 2: Check it renders as a quote block, not a code block**

```bash
cd /home/joe/Development/zen-browser-desktop/zen-wt/nightly
sed -n '/Unofficial fork/,/^---$/p' README.md | head -20
```

Expected: every line inside the notice starts with `>`, with no leading four-space indentation (which would turn it into a code block).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: note that this is a fork sharing stock Zen's profile

Keeping upstream's appId makes this a drop-in replacement, which also means
one profile directory and one /usr/bin/zen between the two. Round-tripping a
profile through stock Zen flattens the tab tree, because it reads the session
fine but ignores the zen-tree-* attributes."
```

---

## Verification

After all tasks, confirm nothing regressed:

```bash
cd /home/joe/Development/zen-browser-desktop
git checkout dev -- src
devenv shell -- bash -c 'npm run lint'
devenv shell -- bash -c 'npm test -- tab-tree --headless'
devenv shell -- bash -c 'npm test -- window_sync --headless'
devenv shell -- bash -c 'npm test -- space_routing --headless'
```

Expected: lint clean, tab-tree 142/0, window_sync 28/0, space_routing 23283/0.

End-to-end, the pipeline is working when:

1. A push to `dev` produces one garnix build and a cached closure, and `nix build` on another machine downloads rather than compiles.
2. `gh workflow run merge-upstream-zen.yml` leaves `dev` untouched and opens a PR.
3. `gh workflow run fork-linux-release.yml -f version=1.21.9b-tst.1` publishes a release with a tarball, a deb and an rpm.
4. The deb installs in a Debian container and `/opt/zen-tst/zen --version` runs.

## Known risks

- **Task 4 is the one likely to fail first.** A full Firefox build on a stock GitHub runner may exceed the 6 h job limit or run out of disk. The fallback is a self-hosted runner on erdtree, which also removes the disk constraint.
- **Task 5 Step 5 is a real test, not a formality.** If the tarball turns out to depend on libraries the container lacks, the packages need `--depends` entries and the `depends` array in Task 6 needs the same additions.
- **The garnix build timeout is not covered by any task here** because it is an instance setting, not a repo change. Task 1 Step 5 will sit at "Build starting" until it is raised.

# Running this fork: Zen Browser with tree-style tabs

## Context

Upstream declined native tree-style tabs ([#14746](https://github.com/zen-browser/desktop/pull/14746)) and the managed-preferences work ([#14749](https://github.com/zen-browser/desktop/pull/14749)). Both are features this fork wants, and one of upstream's own contributors asked for a fork to exist and offered to package it for the AUR. So the fork stops being a staging area for upstream contributions and becomes a product that has to survive on its own.

Two of the four PRs are still open upstream: [#14750](https://github.com/zen-browser/desktop/pull/14750) (container routing on Space move) and [#14751](https://github.com/zen-browser/desktop/pull/14751) (the Nix flake). Those stay open, on branches held off `dev`, so their diffs stay small and reviewable.

The thing this document is really about is the maintenance burden. A Zen fork is a patchset against a patchset: Zen patches Firefox, and this fork patches Zen. Every Firefox version bump moves the ground under both. The design below is shaped around keeping that survivable by one person.

## Branch model

`dev` is the product. It is upstream Zen plus the fork's features, and it is what releases and packages build from.

```
upstream/dev ──(scheduled merge)──▶ dev  ← the browser
                                     │
                                     ├── feat/space-container-routing  → upstream #14750
                                     └── feat/nix-flake                → upstream #14751
```

The four feature branches were merged into `dev` as merge commits rather than squashes, so `git log --follow` still explains why a given line exists when a Firefox bump breaks it. The `nightly` branch that previously held "dev as if all my PRs were merged" is gone; `dev` is that now. Its final state is tagged `backup/nightly-final`.

`feat/space-container-routing` and `feat/nix-flake` stay off `dev` for as long as their upstream PRs are open. If upstream merges either, the change arrives back through the next sync and conflicts with the copy already in `dev`. That conflict is expected and resolves to "already have this".

## App identity and versioning

The fork keeps Zen's name, icons, `appId` and `binaryName`. It is a drop-in replacement: an existing Zen profile opens in it unchanged. Two consequences follow and both need stating rather than avoiding.

The AUR package installs to the same `/usr/bin/zen`, so its PKGBUILD needs `conflicts=('zen-browser' 'zen-browser-bin')` and `provides=('zen-browser')`. Without that, installs fail in a way that looks like a packaging bug.

The profile is shared with stock Zen. This fork writes `zen-tree-id` and `zen-tree-parent-id` into the session; stock Zen reads that session happily but ignores those attributes, so a round trip through upstream Zen flattens the tree. Not data loss, but surprising, so the README should say so.

Versions follow upstream's tag with a fork suffix: `1.21.9b-tst.1`. The suffix increments for fork-only fixes between upstream releases. It lands in the git tag and in `zen-version` in `nix/zen-browser.nix`, which is hand-maintained because Zen's version lives in its release tag rather than a tracked file.

## Upstream sync

A scheduled workflow attempts `git merge upstream/dev` on a scratch branch and never touches `dev` directly:

- clean merge: push `sync/upstream-YYYY-MM-DD`, open a PR
- conflict: open a PR that says so, leaving the markers in place

The job that used to do this reset `dev` to upstream and replayed a single commit on top. That design is now actively dangerous, because a reset would destroy the fork. The replacement must only ever merge.

Keeping the cadence short matters more than it looks. Four one-week gaps are much easier than one six-week gap, because Firefox-bump conflicts compound.

## The five recurring conflict points

Everything fragile is concentrated in five files:

| File | Why it breaks |
|---|---|
| `src/browser/components/tabbrowser/content/tabbrowser-js.patch` | Firefox line numbers shift on every bump |
| `src/browser/components/sessionstore/TabState-sys-mjs.patch` | session-store internals move |
| `src/browser/components/sessionstore/TabAttributes-sys-mjs.patch` | added by the tree-tabs work |
| `src/browser/components/sessionstore/SessionStore-sys-mjs.patch` | restore paths change |
| `surfer.json` | Firefox version bump; trivial now that identity fields are untouched |

### Resolving a patch-file conflict

The 152 to 153 bump produced 51 conflicts in `tabbrowser-js.patch`, of which exactly one carried real content. The other 50 were shifted `@@` headers. The procedure that worked:

1. Take upstream's version of the patch file wholesale (`git checkout --ours`).
2. Re-insert the fork's block at the right place.
3. Renumber every subsequent hunk's new-side start by the number of lines added.
4. Validate every hunk: declared `@@ -a,b +c,d @@` counts must match the body, where `b` is context plus removed lines and `d` is context plus added lines.

Step 4 is not optional. A patch with wrong counts fails as "corrupt patch" at import time, long after the merge looks fine. The real proof is that the patch applies to a fresh Firefox checkout.

## Verification

After any upstream merge, before it reaches `dev`:

```bash
devenv shell -- bash -c 'npm run lint'
devenv shell -- bash -c 'npm test -- tab-tree --headless'
devenv shell -- bash -c 'npm test -- window_sync --headless'
devenv shell -- bash -c 'npm test -- space_routing --headless'
```

Current baselines, all measured: lint clean, tab-tree 142/0, window_sync 28/0, space_routing 23283/0. These are the signal for whether a merge was correct rather than merely textually clean, which is the distinction that decides whether the fork survives.

Two devenv details are load-bearing for lint and worth knowing if it breaks: jemalloc is filtered out of `LD_LIBRARY_PATH` (it breaks the `uv` that mach uses to build its virtualenvs) and `zstandard` is in the devenv python (mach needs it to extract toolchain archives).

Note that `engine/zen` is a tree of symlinks into `src/zen` created at import time. After switching branches it can hold dangling links, which make eslint fail with ENOENT, and be missing links for new files, which then go unlinted silently.

## Distribution

Two pipelines with no overlap. garnix builds the Nix flake and feeds the binary cache. GitHub's runners produce every conventional artifact: tarball, deb, rpm, macOS and Windows.

The split falls out of one hard constraint rather than preference. A Nix build hard-codes store paths into the ELF, verified on the current build:

```
interpreter: /nix/store/…-glibc-2.42-61/lib/ld-linux-x86-64.so.2
rpath:       /nix/store/…-glibc-2.42-61/lib:/nix/store/…-gcc-15.2.0-lib/lib
```

and `bin/zen` is a bash launcher pointing at a store bash. A `.deb` cut from that will not start on a machine without `/nix/store`. Making it relocatable means patchelfing the interpreter, rewriting RPATH to `$ORIGIN`, and vendoring libraries by hand. Upstream's own Linux build already produces a conventional, relocatable tree, so deb and rpm come from there instead.

### garnix: the Nix flake and the binary cache

The repo has no `garnix.yaml`, so it currently runs on garnix defaults and builds anything matching `*.x86_64-linux.*` plus the devShell. Scope it explicitly:

```yaml
builds:
  include:
    - "packages.x86_64-linux.zen-browser-unwrapped"
```

The cache is the whole point. Every machine in the fleet already substitutes from it, so a push builds Zen once on erdtree and every other machine downloads the closure instead of compiling for hours. Nothing GitHub Actions produces can do that: a tarball still leaves `nix build` recompiling locally. This serves the fleet and any NixOS user, and it is the only thing garnix is asked to do here.

Two instance-side settings, neither in this repo:

- **Build timeout.** The per-repo default is 1 h and a Firefox build runs several hours, so it gets killed mid-compile. Raise it on the Configure page. `maxSilent = 14400` in `nix/package.nix` is Nix's silence timer, a different limit that does not help here.
- **Never build `aarch64-linux`.** The only registered aarch64 builder is farum-azula, a 2-core box shared with game servers running `maxJobs = 1`, so a Firefox build there would grind for days. The `builds.include` list names an `x86_64-linux` attribute explicitly and must stay that way. That is why it is explicit rather than leaning on garnix's default scope, which is x86_64-only today but is not a guarantee. The flake still declares `aarch64-linux` so that platform can build locally; it is CI that stays away.

### GitHub runners: tarball, deb, rpm, macOS, Windows

Upstream's `linux-release-build.yml`, `macos-universal-release-build.yml` and `windows-release-build.yml` are inherited and already produce conventional artifacts. The Linux tarball is the base everything else on that side is cut from: deb and rpm via `fpm` against the extracted tree, and the AUR `-bin` package sourcing the published tarball.

macOS goes here rather than to a garnix darwin builder because `torrent` is Apple Silicon only, and upstream's workflow already produces the universal build.

Windows is worth recording accurately, because "Nix can't build Windows" is not quite true. Nix has no native Windows target, but nixpkgs can cross-compile through `pkgsCross.mingwW64`, and Mozilla itself cross-builds Windows Firefox from Linux with `clang-cl`. The real blocker is that Firefox's Windows build needs the Microsoft Windows SDK, which is not freely redistributable, so nixpkgs carries no Windows Firefox and `buildMozillaMach` does not support it. Mozilla fetches SDK toolchain artifacts from their own taskcluster to get around it. Reproducing that inside a Nix sandbox is a project in itself with a licensing question at the centre.

### Order of work

1. `garnix.yaml` scoped to `zen-browser-unwrapped`, plus the timeout raise. Ends local rebuilds for the fleet.
2. Adapt `linux-release-build.yml` and publish the tarball as a GitHub Release.
3. deb and rpm from that tarball via `fpm`, attached to the same release.
4. AUR `-bin` sourcing the release tarball, with the `conflicts`/`provides` fields above.
5. macOS and Windows workflows, once the patchset has survived a Firefox bump.

## Known-good state at time of writing

- `dev` is 76 commits ahead of `upstream/dev`, 0 behind, containing all four merged features.
- The Nix flake builds past configure on Firefox 153 with `rust-cbindgen` 0.29.4 and `nss_latest` 3.126, both pinned from a newer nixpkgs than `nixos-26.05`. The full build has not been run to completion.
- `~/dotfiles` tracks `zen-src` at this fork's `dev`.

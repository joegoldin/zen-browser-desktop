<!--
   - This Source Code Form is subject to the terms of the Mozilla Public
   - License, v. 2.0. If a copy of the MPL was not distributed with this
   - file, You can obtain one at http://mozilla.org/MPL/2.0/.
   -->
<img src="./docs/assets/zen-dark.svg" width="100px" align="left">

### `Zen Browser` with tree-style tabs

[![Crowdin](https://badges.crowdin.net/zen-browser/localized.svg)](https://crowdin.com/project/zen-browser)

Tree-style tabs built into the browser rather than layered on with userChrome
CSS or an extension. Tabs nest under a parent, collapse, and keep their shape
across a restart. Everything else is stock Zen, tracking upstream `dev`.

---

> ### Unofficial fork
>
> A fork of [zen-browser/desktop](https://github.com/zen-browser/desktop).
> Upstream [declined](https://github.com/zen-browser/desktop/pull/14746) the
> tree-style tabs work, so it lives here instead. Not affiliated with or
> endorsed by the Zen team.
>
> It keeps upstream's application id and binary name, so it is a drop-in
> replacement and shares the same profile directory as stock Zen. Two
> consequences:
>
> - You cannot install both from a package manager; they own the same paths.
> - Opening the same profile in stock Zen works, but stock Zen ignores the
>   `zen-tree-*` attributes this fork stores, so a round trip through it
>   flattens the tab tree. Back up your profile before switching back and
>   forth.

---

### What this fork adds

#### Tree-style tabs

Tabs carry a parent, so opening a link from a tab nests it underneath instead
of appending it to a flat list. A twisty appears on any tab with children and
collapses the subtree. The structure is written into the session as
`zen-tree-id` and `zen-tree-parent-id`, so it survives a restart rather than
being rebuilt from heuristics. Middle-drag selects and closes across a subtree.
Lives in `src/zen/tab-tree`, with mochitests in `src/zen/tests/tab-tree`.

#### Managed Spaces

`src/zen/space-routing/ZenManagedSpaces.sys.mjs` lets Spaces and their
container assignments be declared from an enterprise policy file rather than
clicked in by hand, which is what makes the browser configurable from a Nix
module. Upstream [declined](https://github.com/zen-browser/desktop/pull/14749)
this too.

#### Container routing on Space move

Moving a tab into a Space adopts that Space's container. Still
[open upstream](https://github.com/zen-browser/desktop/pull/14750).

#### A Nix flake

Also [open upstream](https://github.com/zen-browser/desktop/pull/14751), and
described below.

### Installing

Releases are tagged `<upstream-tag>-tst.<n>`, so `1.21.9b-tst.1` is the first
fork build on top of upstream's `1.21.9b`.

- Tarball, deb and rpm are attached to each
  [release](https://github.com/joegoldin/zen-browser-desktop/releases). The deb
  and rpm install to `/opt/zen-tst` with a `/usr/bin/zen` symlink, and both
  declare `conflicts`/`provides` against `zen-browser`.
- On Arch, `packaging/aur/PKGBUILD` builds a `zen-browser-tst-bin` package from
  that tarball.
- On Nix, see below.

### Nix

The flake builds Zen from source with `buildMozillaMach`, patching a pristine
Firefox tarball with this fork's patchset. Nothing prebuilt is fetched:

```nix
{
  inputs.zen-src.url = "github:joegoldin/zen-browser-desktop/dev";
}
```

```bash
nix build github:joegoldin/zen-browser-desktop#zen-browser-unwrapped
```

`nix/zen-browser.nix` reads the Firefox version out of `surfer.json` so the
fetched source always matches the base the patches target. The source hash next
to it is pinned by hand and has to move with it.

Two build inputs outrun `nixos-26.05` on Firefox 153 and come from a newer
nixpkgs through an overlay in `flake.nix`: `rust-cbindgen` (configure refuses
below 0.29.4) and `nss_latest` (below 3.125). Both can go once the main pin
catches up.

`devenv.nix` provides the development shell that `mach` and `npm run lint`
need. Two details in it are load-bearing: jemalloc is filtered off
`LD_LIBRARY_PATH`, because it breaks the `uv` that mach uses to build its
virtualenvs, and `zstandard` is added to the devenv python, because mach needs
it to extract toolchain archives.

### Build and cache

Two pipelines that do not overlap.

**garnix** builds the flake and uploads the closure to a self-hosted binary
cache, so machines substitute Zen instead of compiling it. `garnix.yaml` names
`packages.x86_64-linux.zen-browser-unwrapped` explicitly, which keeps CI off
`aarch64-linux`. The only aarch64 builder registered against that instance is
a two-core box, where a Firefox build would run for days. The flake still
declares aarch64 so that platform can build locally. The cache is private and
netrc-authenticated; its host and public key are configured out of band.

**GitHub Actions** produces the conventional artifacts.
`fork-linux-release.yml` builds the x86_64 tarball and publishes a release,
then packages the deb and rpm from that tarball with `fpm`. It is deliberately
not cut from the Nix build: a Nix build hard-codes `/nix/store` into the ELF
interpreter and RPATH, so a deb made from it will not start on a machine
without a Nix store.

### Tracking upstream

`merge-upstream-zen.yml` runs weekly. It merges `upstream/dev` on a scratch
branch and opens a PR; it never pushes to `dev` and never resets it. A conflict
is expected on Firefox bumps and is not treated as an error. The markers are
committed and the PR says so.

Conflicts concentrate in four `.patch` files plus `surfer.json`, because a
Firefox bump shifts the line numbers every hunk header refers to. The
resolution procedure, the regression gate, and the measured test baselines are
in [docs/fork-maintenance.md](./docs/fork-maintenance.md).

### Contributing

Bugs and feature requests for the fork's own behaviour go to
[this repo's issues](https://github.com/joegoldin/zen-browser-desktop/issues).
Anything that reproduces on stock Zen belongs
[upstream](https://github.com/zen-browser/desktop/issues) instead.

Upstream's [contribution guidelines](./docs/contribute.md) still apply to the
shared code.

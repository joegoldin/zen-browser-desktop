# Maintaining this fork

A Zen fork is a patchset against a patchset: Zen patches Firefox, and this fork
patches Zen. Every Firefox version bump moves the ground under both. This
describes what breaks, how to fix it, and how to tell whether a merge was
correct rather than merely textually clean.

## Branch model

`dev` is the product: upstream Zen plus the fork's features. Releases and
packages build from it.

```
upstream/dev ──(scheduled merge)──▶ dev  ← the browser
                                     │
                                     ├── feat/space-container-routing
                                     └── feat/nix-flake
```

The feature branches held off `dev` are the ones with open PRs upstream, kept
separate so their diffs stay small and reviewable. If upstream merges one, it
arrives back through the next sync and conflicts with the copy already in
`dev`. That conflict is expected and resolves to "already have this".

Features were merged into `dev` as merge commits rather than squashes, so
`git log --follow` still explains why a given line exists when a Firefox bump
breaks it.

## App identity and versioning

The fork keeps Zen's name, icons, `appId` and `binaryName`. It is a drop-in
replacement, and an existing Zen profile opens in it unchanged. Two
consequences follow:

The AUR, deb and rpm packages install to the same `/usr/bin/zen`, so each one
declares `conflicts` and `provides` against `zen-browser`. Without that,
installs fail in a way that looks like a packaging bug.

The profile is shared with stock Zen. This fork writes `zen-tree-id` and
`zen-tree-parent-id` into the session; stock Zen reads that session happily but
ignores those attributes, so a round trip through upstream Zen flattens the
tree. Not data loss, but surprising.

Versions follow upstream's tag with a fork suffix: `1.21.9b-tst.1`. The suffix
increments for fork-only fixes between upstream releases. It lands in the git
tag and in `zen-version` in `nix/zen-browser.nix`, which is hand-maintained
because Zen's version lives in its release tag rather than a tracked file.

## Upstream sync

`.github/workflows/merge-upstream-zen.yml` runs weekly. It attempts
`git merge upstream/dev` on a scratch branch and never touches `dev` directly:
a clean merge pushes `sync/upstream-YYYY-MM-DD` and opens a PR, a conflict
opens a PR that says so with the markers left in place.

It only ever merges. The job it replaced reset `dev` to upstream and replayed a
single commit on top, which was correct when `dev` was a mirror and would now
delete the fork.

Keeping the cadence short matters more than it looks. Four one-week gaps are
much easier than one six-week gap, because Firefox-bump conflicts compound.

## The five recurring conflict points

Everything fragile is concentrated in five files:

| File | Why it breaks |
|---|---|
| `src/browser/components/tabbrowser/content/tabbrowser-js.patch` | Firefox line numbers shift on every bump |
| `src/browser/components/sessionstore/TabState-sys-mjs.patch` | session-store internals move |
| `src/browser/components/sessionstore/TabAttributes-sys-mjs.patch` | added by the tree-tabs work |
| `src/browser/components/sessionstore/SessionStore-sys-mjs.patch` | restore paths change |
| `surfer.json` | Firefox version bump |

### Resolving a patch-file conflict

The 152 to 153 bump produced 51 conflicts in `tabbrowser-js.patch`, of which
exactly one carried real content. The other 50 were shifted `@@` headers. The
procedure that worked:

1. Take upstream's version of the patch file wholesale (`git checkout --ours`).
2. Re-insert the fork's block at the right place.
3. Renumber every subsequent hunk's new-side start by the number of lines added.
4. Validate every hunk: declared `@@ -a,b +c,d @@` counts must match the body,
   where `b` is context plus removed lines and `d` is context plus added lines.

Step 4 is not optional. A patch with wrong counts fails as "corrupt patch" at
import time, long after the merge looks fine. The real proof is that the patch
applies to a fresh Firefox checkout.

## Verification

After any upstream merge, before it reaches `dev`:

```bash
devenv shell -- bash -c 'npm run lint'
devenv shell -- bash -c 'npm test -- tab-tree --headless'
devenv shell -- bash -c 'npm test -- window_sync --headless'
devenv shell -- bash -c 'npm test -- space_routing --headless'
```

Baselines, all measured: lint clean, tab-tree 142/0, window_sync 28/0,
space_routing 23283/0. These decide whether a merge was correct, which a clean
textual merge does not.

Two devenv details are load-bearing for lint. jemalloc is filtered out of
`LD_LIBRARY_PATH`, because it breaks the `uv` that mach uses to build its
virtualenvs, and `zstandard` is in the devenv python, because mach needs it to
extract toolchain archives.

`engine/zen` is a tree of symlinks into `src/zen` created at import time. After
switching branches it can hold dangling links, which make eslint fail with
ENOENT, and be missing links for new files, which then go unlinted silently.

## Distribution

Two pipelines with no overlap. garnix builds the Nix flake and feeds the binary
cache. GitHub's runners produce every conventional artifact.

The split falls out of one constraint. A Nix build hard-codes store paths into
the ELF:

```
interpreter: /nix/store/…-glibc-2.42-61/lib/ld-linux-x86-64.so.2
rpath:       /nix/store/…-glibc-2.42-61/lib:/nix/store/…-gcc-15.2.0-lib/lib
```

and `bin/zen` is a bash launcher pointing at a store bash. A `.deb` cut from
that will not start on a machine without `/nix/store`. Making it relocatable
means patchelfing the interpreter, rewriting RPATH to `$ORIGIN`, and vendoring
libraries by hand. The GitHub Linux build already produces a conventional,
relocatable tree, so deb and rpm come from there instead.

`garnix.yaml` names an `x86_64-linux` attribute explicitly. The only registered
aarch64 builder is a 2-core box running `maxJobs = 1`, so a Firefox build there
would grind for days. CI stays away from aarch64; the flake still declares it
so that platform can build locally.

The per-repo garnix build timeout defaults to 1 h and a Firefox build runs
several hours, so it needs raising on the Configure page. `maxSilent` in
`nix/package.nix` is Nix's silence timer, a different limit that does not help.

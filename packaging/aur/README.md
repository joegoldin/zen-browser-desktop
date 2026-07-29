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

The first entry is the published tarball's digest and changes with every
release; refresh it with `updpkgsums` (or `sha256sum` on the downloaded
asset) whenever `pkgver` moves. The second is `zen.desktop`, which only
changes if that file does.

The tarball source is renamed to `$pkgname-$pkgver.tar.xz` because the
release asset carries the same bare filename every version, and makepkg's
source cache keys on the filename: without the rename, an upgrade silently
reuses the previous release's cached tarball.

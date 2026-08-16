# buildMozillaMach wrapper for the Zen fork (tree-style-tabs), modelled on the
# proven nixpkgs PR https://github.com/NixOS/nixpkgs/pull/496647 (Hythera):
# build the pristine Firefox source + the Zen patchset via the standard
# buildMozillaMach rather than Zen's own `surfer` tool.
{
  lib,
  apple-sdk_26,
  buildMozillaMach,
  callPackage,
  stdenv,
  zen-src-tree,
}:
let
  zen-browser-src = callPackage ./zen-browser.nix { inherit zen-src-tree; };

  base =
    (buildMozillaMach {
      inherit (zen-browser-src) extraNativeBuildInputs extraPostPatch;
      pname = "zen-browser";
      allowAddonSideload = true;
      applicationName = "Zen";
      binaryName = "zen";
      branding = "browser/branding/release";
      extraPassthru = {
        inherit (zen-browser-src) ffprefs;
        inherit zen-browser-src;
        # The directory under $out/lib the browser lives in. Anything that has
        # to write inside the application directory, an autoconfig injector for
        # instance, should read this rather than guess at the name, which is
        # not stable across nixpkgs revisions.
        libName = "zen";
      };
      packageVersion = zen-browser-src.zen-version;
      requireSigning = false;
      src = zen-browser-src.firefox-src;
      version = zen-browser-src.firefox-version;

      meta = {
        # since Firefox 60, build on 32-bit platforms fails with "out of memory".
        broken = stdenv.buildPlatform.is32bit;
        description = "Firefox fork with a focus on looks and privacy (tree-style-tabs build)";
        homepage = "https://zen-browser.app";
        license = lib.licenses.mpl20;
        mainProgram = "zen";
        maxSilent = 14400; # 4h, double the default of 7200s (c.f. #129212, #129115)
        # Linux + macOS (aarch64-darwin proven by nixpkgs PR #496647).
        platforms = lib.platforms.unix;
      };
    }).override
      {
        crashreporterSupport = false;
        enableOfficialBranding = false;
        # Firefox >= 145 asks buildMozillaMach for apple-sdk_26, and configure
        # rejects anything below 26.5 ("SDK version 26.4 is too old"), which is
        # exactly what nixos-26.05 pins. The flake hands us a 26.5 build of it;
        # overriding here rather than in an overlay keeps the swap scoped to
        # this derivation instead of rebuilding the ~450 Darwin packages that
        # also reference apple-sdk_26. Inert on Linux, where the SDK is never
        # forced.
        inherit apple-sdk_26;
        # ltoSupport + pgoSupport stay at buildMozillaMach's defaults (true on
        # x86_64-linux): PGO gives profile-guided optimization, and ltoSupport wires
        # up the LLVM/lld bintools. We only change the LTO *mode* below.
      };
in
# Full cross-LTO (--enable-lto=cross,full, what ltoSupport injects) links libxul
# in a single ~32 GB process and OOM-thrashed this 62 GB box for 14 h. Rewrite it
# to thin cross-LTO: per-module, parallel, bounded link memory, for ~90-95% of
# the runtime perf. PGO (the second compile pass + profile run) stays on.
base.overrideAttrs (old: {
  configureFlags = map (
    f: if f == "--enable-lto=cross,full" then "--enable-lto=cross,thin" else f
  ) old.configureFlags;

  # zen-browser-flake's home-manager module installs the Sine bootloader by
  # globbing $out/lib/zen-bin-*, which is how its own repacked release tarball
  # is laid out. A mach build is not, so without this the glob matches nothing
  # and enabling sine silently does nothing at all. Point the name it looks for
  # at the real directory rather than renaming that directory, which the
  # launcher, the desktop entry and wrapFirefox all resolve against.
  #
  # The real directory is discovered rather than named, because what
  # buildMozillaMach calls it varies with the nixpkgs it comes from: both
  # lib/zen and lib/zen-<version> occur.
  #
  # Linux only: on Darwin buildMozillaMach installs an app bundle to
  # $out/Applications/Zen.app and never creates $out/lib at all, so the find
  # below aborts the install with "No such file or directory". Nothing is lost
  # by skipping it — the home-manager module asserts sine.enable is
  # unsupported on macOS (it would break the bundle's code signature), so the
  # glob this shim feeds is never run there.
  postInstall =
    (old.postInstall or "")
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      appdir=$(find "$out/lib" -mindepth 1 -maxdepth 1 -type d \
        -exec test -e '{}/zen' \; -print -quit)
      if [ -n "$appdir" ]; then
        ln -sn "$(basename "$appdir")" "$out/lib/zen-bin-${zen-browser-src.zen-version}"
      else
        echo "no application directory under $out/lib; the sine shim is stale" >&2
        exit 1
      fi
    '';
})

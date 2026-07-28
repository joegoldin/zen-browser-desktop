# buildMozillaMach wrapper for the Zen fork (tree-style-tabs), modelled on the
# proven nixpkgs PR https://github.com/NixOS/nixpkgs/pull/496647 (Hythera):
# build the pristine Firefox source + the Zen patchset via the standard
# buildMozillaMach rather than Zen's own `surfer` tool.
{
  lib,
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
  postInstall = (old.postInstall or "") + ''
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

# The package set and the Zen package, as a function of store paths. The flake
# calls this with its inputs; the dynamic build (./dynamic) calls it again at
# build time with the same paths, so the derivations it generates are exactly
# the ones the flake evaluates.
{
  nixpkgs,
  nixpkgs-newer,
  system,
  src,
}:
let
  # Only the parts of the fork the build reads (see ./zen-browser.nix), so
  # editing anything else, these Nix files included, does not rebuild Zen.
  buildInputsOfFork = [
    "configs"
    "locales"
    "prefs"
    "scripts"
    "src"
    "surfer.json"
    "tools"
  ];
  forkRoot = "${src}/";
  zen-src-tree = builtins.path {
    name = "source";
    path = "${src}";
    filter =
      path: _type:
      let
        relative = builtins.substring (builtins.stringLength forkRoot) (-1) path;
      in
      builtins.elem (builtins.head (builtins.split "/" relative)) buildInputsOfFork;
  };

  # An overlay rather than extraNativeBuildInputs entries: buildMozillaMach
  # (and mach's own configure, which the lint app also runs) reach for
  # rust-cbindgen and nss_latest themselves, so they have to be replaced at
  # the pkgs level for configure to see the newer ones.
  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      (_final: _prev: {
        inherit (import nixpkgs-newer { inherit system; })
          rust-cbindgen
          nss_latest
          ;
      })
    ];
  };
in
{
  inherit pkgs;

  # `src` is the fork tree itself — the thing the build patches into the
  # Firefox source — so building this builds whatever commit is referenced
  # (locally: the checkout; from dotfiles: the pinned rev).
  zen-browser-unwrapped = pkgs.callPackage ./package.nix {
    inherit zen-src-tree;
    # The 26.5 SDK macOS needs, built by the *pinned* nixpkgs rather
    # than taken from nixpkgs-newer wholesale: apple-sdk's package.nix
    # and setup-hooks/ are byte-identical between the two pins, so
    # calling the newer file (which carries the newer
    # metadata/versions.json) against our own package set yields 26.5
    # without dragging a second nixpkgs' stdenv, libiconv and
    # compiler-rt into the closure.
    #
    # Deliberately passed here rather than added to the overlay above.
    # Much of the Darwin package set depends on apple-sdk_26 even
    # though the stdenv's own default SDK is 14.4, so overlaying it
    # rebuilds ~450 packages — cups, gnutls, unbound, sphinx and the
    # rest of Firefox's Darwin buildInputs — from source with no cache
    # hits. Scoped to this derivation (./package.nix forwards it into
    # buildMozillaMach's `.override`), only Zen itself rebuilds, and
    # its dependencies keep their cached 26.4-built outputs. That mix
    # is fine: the SDK version governs the headers and stubs each
    # package is compiled against, not a shared ABI.
    #
    # Never forced on Linux, where buildMozillaMach only reaches for
    # the SDK inside its own `isDarwin` branch.
    apple-sdk_26 = pkgs.callPackage "${nixpkgs-newer}/pkgs/by-name/ap/apple-sdk/package.nix" {
      darwinSdkMajorVersion = "26";
    };
  };
}

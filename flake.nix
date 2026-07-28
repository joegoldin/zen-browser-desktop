{
  description = "Zen Browser built from source — joegoldin fork (tree-style-tabs)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Firefox 153 outruns nixos-26.05 on two build inputs: configure refuses
    # cbindgen below 0.29.4 (the pin has 0.29.2) and nss below 3.125 (the pin's
    # nss_latest is 3.124). Take just those two from a newer nixpkgs rather than
    # moving the whole toolchain. Both can go once the main pin catches up.
    nixpkgs-newer.url = "github:NixOS/nixpkgs/7525d999cd850b9a488817abc89c75dc733acf17";
  };

  outputs =
    { self, nixpkgs, nixpkgs-newer }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          # An overlay rather than extraNativeBuildInputs entries: buildMozillaMach
          # reaches for rust-cbindgen and nss_latest itself, so they have to be
          # replaced at the pkgs level for configure to see the newer ones.
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              (_final: _prev: {
                inherit (nixpkgs-newer.legacyPackages.${system})
                  rust-cbindgen
                  nss_latest
                  ;
              })
            ];
          };
          # `self` is the fork tree itself — the thing the build patches into the
          # Firefox source — so building this flake builds whatever commit is
          # referenced (locally: the checkout; from dotfiles: the pinned rev).
          zen-browser-unwrapped = pkgs.callPackage ./nix/package.nix {
            zen-src-tree = self;
          };
        in
        {
          inherit zen-browser-unwrapped;
          default = zen-browser-unwrapped;
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      # `npm run lint` (`cd engine && ./mach lint zen`), packaged as a garnix CI
      # action instead of a GitHub Actions job, so it runs on the self-hosted
      # runner on every push. x86_64-linux only: it's the only builder garnix
      # actions run on here, and lint has no platform-specific behaviour anyway.
      #
      # This is deliberately NOT the devenv/build toolchain. `mach lint zen`
      # only touches the `zen` subtree (JS/CSS/Fluent/license/text checks) and
      # never compiles Firefox, so it needs none of clang/lld/nasm/cbindgen or
      # Firefox's own GTK/X11/NSS runtime libraries — those exist so the browser
      # can be *built and run*, not linted. What it does need is the chain that
      # produces `engine/zen` in the first place (`npm ci`, `npm run download`,
      # `npm run import`), since that's a tree of symlinks into `src/zen`
      # created at import time (see the building-and-testing-zen skill).
      apps.x86_64-linux.lint =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          # `mach lint`'s clang-format linter (tools/lint/clang-format/__init__.py
          # setup()) downloads Mozilla's prebuilt clang-tidy.tar.zst toolchain
          # archive (clang-format ships in the same bundle) the first time it's
          # needed, and that build (taskcluster/kinds/toolchain/clang-tidy.yml)
          # is linked against a linux64-libxml2 fetched alongside it. It's a
          # foreign, non-Nix-patched C++ binary, so it needs libstdc++ and zlib
          # too, same as any such binary. This is intentionally NOT
          # devenv.nix's full `engineLibPath`: that one also carries the
          # GTK/Cairo/X11/audio/NSS stack Firefox itself links, which is only
          # for *running* the built browser (mach run/mach test) — lint never
          # does that, so none of it belongs here.
          lintLibPath = pkgs.lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib
            pkgs.zlib
            pkgs.libxml2
          ];
        in
        {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "zen-lint";
              runtimeInputs = with pkgs; [
                git
                nodejs_22
                # zstandard: not a `pypi-optional` fallback here, unlike
                # devenv.nix's comment about it — `mach lint zen` unconditionally
                # needs it to unpack the .tar.zst clang-format/clang-tidy
                # toolchain archives it fetches, and there's no interactive
                # devenv shell around to have installed it beforehand.
                (python311.withPackages (ps: [ ps.zstandard ]))
                # `npm run import` runs `npm run ffprefs` first (a small Rust
                # CLI under tools/ffprefs), which needs a linker even though
                # it's pure Rust with no C code of its own. clang+lld is the
                # same pair devenv.nix supplies and is proven to satisfy it;
                # the rest of devenv's C/C++ toolchain (nasm, cbindgen, the
                # full mozconfig-driven clang setup) is for compiling Firefox
                # itself and isn't needed here.
                cargo
                rustc
                clang
                lld
                # mach prefers `uv` over pip for building its virtualenvs
                # (mach/site.py: `use_uv()` just checks `shutil.which("uv")`).
                # On a real workstation that's often whatever the developer
                # happens to have on PATH; a garnix action runner starts from a
                # fresh, minimal environment with nothing preinstalled, so it
                # has to be supplied explicitly or mach silently falls back to
                # the slower, less-exercised plain-pip path.
                uv
                # mozlint's ruff and ruff-format linters shell out to a bare
                # `ruff`, which mach normally supplies from the virtualenv it
                # builds out of python/sites/lint.txt. That virtualenv does not
                # get populated on a runner that starts from an empty $HOME, so
                # the linters die on FileNotFoundError before looking at
                # anything. src/zen has two Python files, so they do have work
                # to do and skipping them is not an option.
                #
                # nixpkgs is a patch release behind the pin in lint.txt
                # (0.15.14 against 0.15.15), so CI and a local devenv run can in
                # principle disagree. Worth checking here first if lint ever
                # fails in one place and passes in the other.
                ruff
                cacert
              ];
              # devenv.nix filters nixpkgs' jemalloc out of the LD_LIBRARY_PATH
              # it builds from firefox-unwrapped.buildInputs, because leaving
              # it there breaks `uv` (jemalloc's `_rjem_`-prefixed malloc gets
              # picked up by dynamically linked tools ahead of glibc's own,
              # and `uv: undefined symbol: _rjem_malloc` takes out `mach lint`
              # before it reaches a linter). That risk doesn't apply to
              # `lintLibPath` above: it's never built from
              # firefox-unwrapped.buildInputs (see the comment on it), so
              # jemalloc never enters this closure in the first place, and
              # `uv` itself comes from nixpkgs (properly RPATH'd by its own
              # build) rather than needing LD_LIBRARY_PATH help at all. Keep
              # it that way if this list ever grows: don't let a future
              # addition pull firefox-unwrapped.buildInputs back in here
              # without re-filtering it.
              text = ''
                # TLS trust root for npm/cargo/git's HTTPS fetches (registry.npmjs.org,
                # crates.io, github.com). Nix doesn't wire this up by default outside
                # an interactive devenv shell.
                export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
                export GIT_SSL_CAINFO="$SSL_CERT_FILE"
                export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
                export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}${lintLibPath}"

                # `surfer download` does a `git init && git commit` in the
                # fresh engine/ checkout (see surfer's commands/init.js), which
                # fails without a configured identity.
                git config --global user.name "garnix-lint-action"
                git config --global user.email "garnix-lint-action@localhost"

                npm ci
                npm run download
                npm run import
                (cd engine && ./mach lint zen)
              '';
            }
          }/bin/zen-lint";
        };
    };
}

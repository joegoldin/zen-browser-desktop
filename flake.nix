{
  description = "Zen Browser built from source — joegoldin fork (tree-style-tabs)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Build inputs configure is strict about, where nixos-26.05 lags: cbindgen
    # below 0.29.4, and nss below the version Firefox bundles (configure wants
    # system nss >= security/nss/lib/nss/nss.h, 3.129 on Firefox 157), and — on
    # macOS — an Apple SDK below 26.5. Pinned to a master commit because
    # nixos-unstable was still at nss 3.128 when Firefox 157 landed. The SDK is
    # not a matter of waiting: nixpkgs bumped apple-sdk_26 to 26.5 in a81408d1
    # (2026-05-17), after the 26.05 branch-off, and never backported it, so both
    # nixos-26.05 and nixpkgs-26.05-darwin are stuck at 26.4 for the life of
    # the release.
    nixpkgs-newer.url = "github:NixOS/nixpkgs/0a59a4df5fb1b3ff45c63d7d9d308686e85cda55";
    # Dynamic derivations, for the per-directory build in nix/dynamic.
    drowse = {
      url = "github:figsoda/drowse";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-newer,
      drowse,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      zenFor =
        system:
        import ./nix {
          inherit nixpkgs nixpkgs-newer system;
          src = self;
        };
      pkgsFor = system: (zenFor system).pkgs;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          zen-browser-unwrapped-monolithic = (zenFor system).zen-browser-unwrapped;
          # Per-directory derivations on Linux, so a failed build keeps what
          # finished (see nix/dynamic). Darwin keeps the single derivation: its
          # app-bundle install has never been run through the dynamic stages.
          zen-browser-unwrapped =
            if pkgs.stdenv.hostPlatform.isLinux then
              pkgs.callPackage ./nix/dynamic {
                drowse = drowse.lib.${system};
                inherit nixpkgs nixpkgs-newer system;
                src = self;
                zen = zen-browser-unwrapped-monolithic;
              }
            else
              zen-browser-unwrapped-monolithic;
        in
        {
          inherit zen-browser-unwrapped zen-browser-unwrapped-monolithic;
          default = zen-browser-unwrapped;
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      # `npm run lint` (`cd engine && ./mach lint zen`), packaged as a garnix CI
      # action, so it runs on the self-hosted runner on every push.
      # x86_64-linux only: it's the only builder garnix actions run on here,
      # and lint has no platform-specific behaviour anyway.
      #
      # This carries the build toolchain, not just the linters, because `mach
      # lint` runs the full `configure` on a tree that has never been built —
      # which is every run, since the runner starts fresh. configure checks for
      # the compilers, llvm-objdump, nasm, cbindgen and the pkg-config
      # libraries Firefox links against, and dies on the first one it cannot
      # find. devenv.nix carries the same set for the same reason, and this
      # list mirrors it.
      apps.x86_64-linux.lint =
        let
          pkgs = pkgsFor "x86_64-linux";
          # Native libraries Zen links against, for configure's pkg-config
          # checks. jemalloc is filtered out for the same reason devenv.nix
          # filters it from LD_LIBRARY_PATH: Firefox's copy exports malloc
          # under an `_rjem_` prefix, and any dynamically linked tool that
          # picks it up ahead of glibc's own dies on the missing symbol — `uv`,
          # which mach shells out to for its virtualenvs, is the one that
          # bites.
          isJemalloc = p: pkgs.lib.hasPrefix "jemalloc" (p.pname or p.name or "");
          engineInputs = builtins.filter (p: !(isJemalloc p)) pkgs.firefox-unwrapped.buildInputs;
          # closePropagation, because .pc files chain: pango.pc requires
          # harfbuzz.pc, which belongs to a dependency Firefox itself never
          # names. A nix shell would propagate these; a bare search path has to
          # walk the closure itself.
          engineInputsClosed = pkgs.lib.closePropagation engineInputs;
          pkgConfigPath = pkgs.lib.concatStringsSep ":" [
            (pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" engineInputsClosed)
            (pkgs.lib.makeSearchPathOutput "dev" "share/pkgconfig" engineInputsClosed)
          ];
          # mach downloads Mozilla's prebuilt clang-format out of the
          # clang-tidy toolchain archive: a foreign, non-Nix-patched C++
          # binary, so it needs libstdc++, zlib and the libxml2 it links.
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
                # zstandard: mach needs it to unpack the .tar.zst toolchain
                # archives `mach lint` fetches (clang-format), and there is no
                # interactive devenv shell around to have installed it.
                (python311.withPackages (ps: [ ps.zstandard ]))
                cargo
                rustc
                pkg-config
                gnumake
                unzip
                zstd
                # mozconfig forces CC=clang/CXX=clang++ and links with lld.
                clang
                lld
                # LLVM binutils: configure refuses to proceed without
                # llvm-objdump.
                llvmPackages.llvm
                # nasm assembles the bundled media codecs; configure checks it.
                nasm
                # The overlayed 0.29.4; configure refuses anything older.
                rust-cbindgen
                # mach prefers `uv` over pip for building its virtualenvs
                # (mach/site.py: use_uv() just checks shutil.which("uv")). The
                # runner starts from a fresh, minimal environment, so it has to
                # be supplied explicitly or mach silently falls back to the
                # slower plain-pip path.
                uv
                # mozlint's ruff and ruff-format linters shell out to a bare
                # `ruff`, which mach normally supplies from the virtualenv it
                # builds out of python/sites/lint.txt. That virtualenv does not
                # get populated on a runner starting from an empty $HOME, so
                # without this both linters die on FileNotFoundError. nixpkgs
                # is a patch release behind the lint.txt pin (0.15.14 against
                # 0.15.15); check here first if lint ever disagrees between CI
                # and a devenv run.
                ruff
                cacert
              ];
              text = ''
                # TLS trust root for npm/cargo/git's HTTPS fetches. Nix doesn't
                # wire this up by default outside an interactive shell.
                export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
                export GIT_SSL_CAINFO="$SSL_CERT_FILE"
                export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
                export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}${lintLibPath}"
                # configure discovers Firefox's native dependencies through
                # pkg-config; a bare script gets none of the search-path wiring
                # a nix shell would provide, so it is spelled out.
                export PKG_CONFIG_PATH="${pkgConfigPath}"

                # configure locates libclang only through --with-libclang-path
                # or the clang binary's own -print-search-dirs, never an
                # environment variable (build/moz.configure/bindgen.configure),
                # and nix's clang wrapper does not carry libclang. The wasm
                # sysroot is opted out of the same way nixpkgs' Firefox build
                # opts out.
                MOZCONFIG="$(mktemp)"
                export MOZCONFIG
                {
                  echo "ac_add_options --with-libclang-path=${pkgs.llvmPackages.libclang.lib}/lib"
                  echo "ac_add_options --without-wasm-sandboxed-libraries"
                } > "$MOZCONFIG"

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

{ pkgs, inputs, ... }:
let
  # Firefox 153's build checks `cbindgen --version` and refuses anything below
  # 0.29.4, which the pinned nixpkgs predates. Take just this tool from a newer
  # nixpkgs (see devenv.yaml) rather than moving the whole toolchain.
  cbindgen = inputs.nixpkgs-cbindgen.legacyPackages.${pkgs.stdenv.system}.rust-cbindgen;
  # Loader path for the engine's libraries. firefox-unwrapped.buildInputs
  # carries -dev outputs whose /lib holds pkg-config data but not the runtime
  # .so files, so pull each input's `out` and `lib` outputs (the .so may live
  # in either), plus gcc's libstdc++ which Nix keeps off the default path.
  engineLibPath = pkgs.lib.makeLibraryPath (
    pkgs.lib.concatMap (p: [
      (p.out or p)
      (p.lib or p)
    ]) pkgs.firefox-unwrapped.buildInputs
    ++ (with pkgs; [
      # GTK/Cairo/X stack Firefox links directly but that reaches the build
      # only transitively (via gtk3), so it's absent from buildInputs; each
      # lib's sub-deps then resolve through its own RUNPATH.
      harfbuzz
      atk
      cairo
      gdk-pixbuf
      pango
      xorg.libXcomposite
      xorg.libXfixes
      xorg.libXrandr
      xorg.libxcb
      stdenv.cc.cc.lib
    ])
  );
in
{
  # Toolchain for bootstrapping the Zen/Firefox engine and running
  # `mach lint zen`. Versions follow the repo's pins:
  #   .nvmrc          -> node 22
  #   .python-version -> python 3.11
  #   .rust-toolchain -> rust 1.90 (ffprefs step of `npm run import`)
  packages = [
    pkgs.git
    pkgs.nodejs_22
    pkgs.python311
    pkgs.cargo
    pkgs.rustc
    pkgs.pkg-config
    pkgs.gnumake
    pkgs.unzip
    pkgs.zstd
    # C/C++ toolchain for building the engine. mozconfig forces
    # CC=clang/CXX=clang++, and the build links with lld.
    pkgs.clang
    pkgs.lld
    # LLVM binutils (llvm-objdump/-readelf/-objcopy/...) the build invokes.
    pkgs.llvmPackages.llvm
    # nasm assembles bundled media codecs (lives in Firefox's nativeBuildInputs).
    pkgs.nasm
    # cbindgen generates C/C++ headers from Rust (style system, webrender).
    cbindgen
    # patchelf embeds RUNPATH into mochitest helper binaries (see enterShell).
    pkgs.patchelf
  ]
  # Native libraries Zen/Firefox links against (gtk3, alsa, X11, nss, dbus,
  # ...). Reuse nixpkgs' Firefox dependency set instead of hand-maintaining it.
  ++ pkgs.firefox-unwrapped.buildInputs;

  # rust bindgen (style system) needs libclang at build time.
  env.LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

  # Put the engine's libraries on the loader path so the *built* binaries
  # (zen, xpcshell, ...) and host build scripts can run: gcc's libstdc++ for
  # build scripts, plus the dlopen'd runtime libs (libgtk-3, X11, nss, ...)
  # that `mach run`/`mach test` need.
  enterShell = ''
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}${engineLibPath}"

    # The mochitest runner launches helper binaries with a sanitized environment
    # that drops LD_LIBRARY_PATH. ssltunnel (the SSL proxy that routes
    # https://example.com etc. to the local test server) then can't load
    # libstdc++, the proxy "refuses connections", and every URL-loading test
    # hangs ("window unloaded while we were waiting for the browser to load").
    # about:blank-only tests are unaffected. Embed the engine lib path into the
    # binary's RUNPATH so it runs regardless of env. Idempotent; runs whenever
    # the engine is built. (A full `mach build` rebuilds ssltunnel — re-enter
    # the shell, or this re-applies on the next `devenv shell`.)
    for _bin in engine/obj-*/dist/bin/ssltunnel; do
      if [ -x "$_bin" ] \
         && ! patchelf --print-rpath "$_bin" 2>/dev/null \
              | grep -qF "${pkgs.stdenv.cc.cc.lib}/lib"; then
        patchelf --add-rpath '$ORIGIN:${engineLibPath}' "$_bin" 2>/dev/null \
          && echo "devenv: embedded RUNPATH into ssltunnel (mochitest proxy fix)"
      fi
    done

    # Zen's en-US Fluent strings live in locales/en-US/ but aren't copied into
    # the build by default; without them the browser/tests throw
    # "Couldn't find a message: ..." and "Missing resource in locale en-US:
    # browser/zen-*.ftl" — which fail window_sync/new-window tests via uncaught
    # rejections. Copy them into the build if the engine is imported but missing.
    if [ -d engine/browser/locales/en-US/browser ] \
       && [ ! -f engine/browser/locales/en-US/browser/zen-vertical-tabs.ftl ]; then
      python3 scripts/update_en_US_packs.py >/dev/null 2>&1 \
        && echo "devenv: copied en-US Zen locale strings into the build"
    fi
  '';
}

{ pkgs, ... }:
let
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
    pkgs.rust-cbindgen
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
  '';
}

# Zen built one derivation per group of compile-tier directories, instead of
# one derivation for the whole multi-hour build, so a failure keeps every
# group that finished. The compile tier's graph only exists once configure
# has run, so the per-group derivations are generated at build time through
# drowse (dynamic derivations): building this needs the ca-derivations,
# dynamic-derivations and recursive-nix features on the building machine.
#
# With PGO, the instrumented pass is its own dynamic build, ending in the
# profiling run; the profile it writes is an input to the second pass's
# configure and every one of its groups.
{
  lib,
  drowse,
  nixpkgs,
  nixpkgs-newer,
  system,
  src,
  zen,
  # Compile-tier targets per derivation, among targets that share their
  # dependencies. Smaller loses less to a failure; larger spends less
  # copying the objdir into each derivation.
  chunkSize ? 8,
}:
let
  stages = import ./stages.nix { inherit lib zen; };

  pass =
    {
      mode,
      profile ? null,
    }:
    let
      configured = stages.configured { inherit profile chunkSize; };
      quote = value: builtins.toJSON "${value}";
    in
    drowse.instantiate (finalAttrs: {
      pname = if mode == "final" then zen.pname else "${zen.pname}-${mode}";
      inherit (zen) version;
      dontUnpack = true;
      expr = ''
        import ${src}/nix/dynamic/nodes.nix {
          nixpkgs = ${quote nixpkgs};
          nixpkgs-newer = ${quote nixpkgs-newer};
          system = ${builtins.toJSON system};
          src = ${quote src};
          configured = ${quote configured};
          profile = ${if profile == null then "null" else quote profile};
          mode = ${builtins.toJSON mode};
          name = ${builtins.toJSON finalAttrs.passthru.outName};
        }
      '';
    });

  profileRun = if zen.preConfigurePhases != [ ] then pass { mode = "profile"; } else null;
  built = pass {
    mode = "final";
    profile = profileRun;
  };
in
# drowse's result is a symlink to the dynamically built output; give it the
# monolithic package's passthru, which wrapFirefox and the home-manager
# module read (binaryName, libName, gtk3, ...).
built.overrideAttrs (old: {
  passthru = zen.passthru // old.passthru // { inherit profileRun; };
  inherit (zen) meta;
})

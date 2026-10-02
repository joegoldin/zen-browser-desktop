# Evaluated at build time inside a drowse derivation (./default.nix), once the
# configured stage has written graph.json. Rebuilds the Zen derivation from
# the same store paths the flake uses, then emits one derivation per group of
# the compile tier, plus the stage that finishes the pass. Store paths arrive
# as plain strings; builtins.storePath turns them back into dependencies.
{
  nixpkgs,
  nixpkgs-newer,
  system,
  src,
  configured,
  profile,
  # "profile" for PGO's instrumented pass, "final" for the build installed.
  mode,
  name,
}:
let
  inherit (builtins) storePath;

  zen-nix = import ../default.nix {
    nixpkgs = storePath nixpkgs;
    nixpkgs-newer = storePath nixpkgs-newer;
    src = storePath src;
    inherit system;
  };
  inherit (zen-nix.pkgs) lib;

  stages = import ./stages.nix {
    inherit lib;
    zen = zen-nix.zen-browser-unwrapped;
  };

  configuredPath = storePath configured;
  profilePath = if profile == null then null else storePath profile;
  inherit (lib.importJSON "${configuredPath}/graph.json") groups order;

  # Every group a group builds on, directly or not, in dependency order.
  layersFor =
    deps:
    let
      closure = lib.genericClosure {
        startSet = map (key: { inherit key; }) deps;
        operator = { key }: map (dep: { key = dep; }) groups.${key}.deps;
      };
      needed = lib.genAttrs (map (item: item.key) closure) (_: true);
    in
    map (group: built.${group}) (lib.filter (group: needed ? ${group}) order);

  built = lib.mapAttrs (
    group: spec:
    stages.group {
      name = group;
      inherit (spec) targets;
      configured = configuredPath;
      layers = layersFor spec.deps;
      profile = profilePath;
    }
  ) groups;

  finish =
    if mode == "profile" then
      stages.profile {
        configured = configuredPath;
        layers = map (group: built.${group}) order;
      }
    else
      stages.final {
        configured = configuredPath;
        layers = map (group: built.${group}) order;
        profile = profilePath;
      };
in
assert finish.name == name;
finish

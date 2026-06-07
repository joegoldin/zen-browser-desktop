{
  description = "Zen Browser built from source — joegoldin fork (tree-style-tabs)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
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
          pkgs = nixpkgs.legacyPackages.${system};
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
    };
}

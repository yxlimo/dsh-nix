{
  description = "DeepSeek Harness (dsh) packaged for Nix from the published npm tarball";

  # Upstream npm version. CI rewrites the `version` line in packages/dsh.nix when
  # npm's `next`/`latest` dist-tag moves.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          dsh = pkgs.callPackage ./packages/dsh.nix { };
          default = self.packages.${system}.dsh;
        }
      );

      overlays.default = final: _prev: {
        dsh = final.callPackage ./packages/dsh.nix { };
      };

      # NixOS module: runs `dsh web` as a systemd service with a separate user.
      nixosModules.default = import ./modules/dsh.nix;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}

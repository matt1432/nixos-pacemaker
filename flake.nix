{
  inputs = {
    nixpkgs = {
      type = "github";
      owner = "NixOS";
      repo = "nixpkgs";
      ref = "nixos-unstable";
    };

    nixpkgs-pacemaker = {
      type = "github";
      owner = "mitchty";
      repo = "nixpkgs";
      ref = "corosync-pacemaker-ocf";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-pacemaker,
    ...
  }: let
    # As of right now, pacemaker only works on this arch
    # according to this: https://github.com/mitchty/nix/blob/e21cab315aa53782ca6a5995a8706fc1032a0681/flake.nix#L120
    supportedSystems = ["x86_64-linux"];

    perSystem = attrs:
      nixpkgs.lib.genAttrs supportedSystems (system: let
        pkgs = nixpkgs.legacyPackages.${system};
      in
        attrs system pkgs);
  in {
    packages = perSystem (system: pkgs: {
      pcs = pkgs.callPackage ./pkgs pkgs;
      default = self.packages.${system}.pcs;
    });

    nixosModules = {
      pacemaker = import ./modules nixpkgs-pacemaker self;
      default = self.nixosModules.pacemaker;
    };

    formatter = perSystem (_: pkgs: pkgs.alejandra);

    devShells = perSystem (_: pkgs: {
      default = let
        inherit
          (import ./pkgs/default.nix pkgs)
          buildInputs
          nativeBuildInputs
          propagatedBuildInputs
          ;
      in
        pkgs.mkShell {
          packages = with pkgs;
            [
              alejandra
              git
              nix
              bundix
            ]
            ++ buildInputs
            ++ nativeBuildInputs
            ++ propagatedBuildInputs;
        };
    });
  };
}

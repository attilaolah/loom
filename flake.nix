{
  description = "NixOS VM + OpenClaw";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    ...
  }: let
    mkPkgs = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

    mkNixosConfig = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [./configuration.nix];
      };
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = nixpkgs.lib.systems.flakeExposed;

      flake = {withSystem, ...}: {
        nixosConfigurations.vm = withSystem builtins.currentSystem ({system, ...}: mkNixosConfig system);
      };

      perSystem = {
        lib,
        system,
        ...
      }: let
        pkgs = mkPkgs system;
        nixosConfig = mkNixosConfig system;
        vm = nixosConfig.config.system.build.vm;
        vmRunner = lib.getExe' vm "run-${nixosConfig.config.networking.hostName}-vm";
        vmApp = pkgs.writeShellApplication {
          name = "vm";
          runtimeInputs = with pkgs; [coreutils];
          text = ''
            exec ${vmRunner} "$@"
          '';
        };
      in {
        packages = {
          inherit vm;
          default = vm;
        };

        apps = {
          vm = {
            type = "app";
            program = lib.getExe vmApp;
          };
        };
      };
    };
}

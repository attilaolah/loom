{
  description = "NixOS VM + NanoClaw";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = nixpkgs.lib.systems.flakeExposed;

      flake = {withSystem, ...}: {
        nixosConfigurations.vm = withSystem builtins.currentSystem ({system, ...}:
          nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [./configuration.nix];
          });
      };

      perSystem = {
        lib,
        system,
        ...
      }: let
        inherit (nixosConfig.config.system.build) vm;
        nixosConfig = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [./configuration.nix];
        };
      in {
        packages = {
          inherit vm;
          default = vm;
        };

        apps.vm = {
          type = "app";
          program = lib.getExe' vm "run-${nixosConfig.config.networking.hostName}-vm";
        };
      };
    };
}

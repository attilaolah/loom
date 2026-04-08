{
  description = "NixOS VM + OpenClaw";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    openclaw.url = "github:Scout-DJ/openclaw-nix";
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    openclaw,
    ...
  }: let
    mkNixosConfig = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          openclaw.nixosModules.default
          ./configuration.nix
        ];
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
        pkgs = import nixpkgs {inherit system;};
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

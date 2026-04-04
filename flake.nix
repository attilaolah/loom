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
      import nixpkgs (let
        openclaw = {
          version = "2026.4.2";
          hash = "sha256-wVS2OuBNrF1yWjmINxde0kC5mvY2QUUtwYpYrZcARkI=";
          pnpmDepsHash = "sha256-aHepSWiQ4+UyjPHBF+4+M9/nFrgfCw422q671saJM+U=";
        };
      in {
        inherit system;
        config = {
          allowUnfree = true;
          permittedInsecurePackages = [
            "openclaw-${openclaw.version}"
          ];
        };
        overlays = [
          (final: prev: {
            openclaw = prev.openclaw.overrideAttrs (_: {
              inherit (openclaw) version pnpmDepsHash;
              src = prev.fetchFromGitHub {
                inherit (openclaw) hash;
                owner = "openclaw";
                repo = "openclaw";
                tag = "v${openclaw.version}";
              };
            });
          })
        ];
      });

    mkNixosConfig = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        pkgs = mkPkgs system;
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

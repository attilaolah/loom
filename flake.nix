{
  description = "NixOS VM + NanoClaw";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nanoclaw = {
      url = "github:qwibitai/nanoclaw";
      flake = false;
    };
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    nanoclaw,
    ...
  }: let
    mkPkgs = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

    mkNanoclaw = pkgs: let
      packageJson = builtins.fromJSON (builtins.readFile "${nanoclaw}/package.json");
      upstreamVersion = packageJson.version or "unstable";
    in
      pkgs.buildNpmPackage {
        pname = "nanoclaw";
        version = "${upstreamVersion}-${nanoclaw.shortRev or "dirty"}";

        src = nanoclaw;
        nodejs = pkgs.nodejs_25;

        npmDepsHash = "sha256-0XZfU5sv0bAzZvawkhOiJNccL4ljFPVZT+2YXkkQFCc=";

        npmInstallFlags = ["--include=dev"];
        npmBuildScript = "build";
        dontNpmPrune = true;

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -R . $out/
          runHook postInstall
        '';
      };

    mkOnecli = pkgs: let
      version = "1.1.0";
    in
      pkgs.buildGoModule {
        pname = "onecli";
        inherit version;
        src = pkgs.fetchzip {
          url = "https://github.com/onecli/onecli-cli/archive/refs/tags/v${version}.tar.gz";
          hash = "sha256-YTeAJmEzGmXGadVqMZcryieZouioG+rW5pIldPlZqPc=";
        };
        subPackages = ["cmd/onecli"];
        ldflags = [
          "-s"
          "-w"
          "-X main.version=${version}"
        ];
        vendorHash = "sha256-i/PkexCtV2c5NwNXdKQV3G+MKf6YO0B9yU4KjWXxxBk=";
      };

    mkNixosConfig = system: let
      pkgs = mkPkgs system;
      nanoclawPkg = mkNanoclaw pkgs;
      onecliPkg = mkOnecli pkgs;
    in
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          nanoclaw = nanoclawPkg;
          onecli = onecliPkg;
        };
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
        nanoclawPkg = mkNanoclaw pkgs;
        onecliPkg = mkOnecli pkgs;
        nixosConfig = mkNixosConfig system;
        vm = nixosConfig.config.system.build.vm;
      in {
        packages = {
          inherit vm;
          nanoclaw = nanoclawPkg;
          onecli = onecliPkg;
          default = vm;
        };

        apps.vm = {
          type = "app";
          program = lib.getExe' vm "run-${nixosConfig.config.networking.hostName}-vm";
        };
      };
    };
}

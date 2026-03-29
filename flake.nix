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
  }: let
    mkPkgs = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
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
      onecliPkg = mkOnecli pkgs;
    in
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
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
        onecliPkg = mkOnecli pkgs;
        nixosConfig = mkNixosConfig system;
        vm = nixosConfig.config.system.build.vm;
      in {
        packages = {
          inherit vm;
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

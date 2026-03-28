{
  description = "NixOS VM + NanoClaw";

  inputs = {
    nixpkgs.url = "nixpkgs";
  };

  outputs = {nixpkgs, ...}: let
    inherit (nixosConfig.config.system.build) vm;
    system = "x86_64-linux";
    nixosConfig = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./configuration.nix
      ];
    };
  in {
    nixosConfigurations.vm = nixosConfig;

    packages.${system} = {
      inherit vm;
      default = vm;
    };

    apps.${system}.vm = {
      type = "app";
      program = nixpkgs.lib.getExe' vm "run-${nixosConfig.config.networking.hostName}-vm";
    };
  };
}

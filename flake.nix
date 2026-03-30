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
        vmRunner = lib.getExe' vm "run-${nixosConfig.config.networking.hostName}-vm";
        vmApp = pkgs.writeShellApplication {
          name = "vm";
          runtimeInputs = with pkgs; [coreutils];
          text = ''
            set -euo pipefail

            tls_dir="$(readlink -f "$PWD/tls")"
            if [ ! -d "$tls_dir" ]; then
              echo "error: tls directory not found at $tls_dir" >&2
              echo "hint: run 'nix run .#tls-setup' from the repo root first" >&2
              exit 1
            fi

            export TLS_DIR="$tls_dir"
            exec ${vmRunner} "$@"
          '';
        };
        tlsSetup = pkgs.writeShellApplication {
          name = "tls-setup";
          runtimeInputs = with pkgs; [coreutils step-cli];
          text = ''
            set -euo pipefail

            tls_dir="$PWD/tls"
            ca_crt="$tls_dir/ca.crt"
            ca_key="$tls_dir/ca.key"
            tls_crt="$tls_dir/tls.crt"
            tls_key="$tls_dir/tls.key"

            mkdir -p "$tls_dir"

            if [ -e "$ca_crt" ] && [ ! -e "$ca_key" ]; then
              echo "error: $ca_crt exists but $ca_key is missing" >&2
              exit 1
            fi
            if [ -e "$ca_key" ] && [ ! -e "$ca_crt" ]; then
              echo "error: $ca_key exists but $ca_crt is missing" >&2
              exit 1
            fi

            if [ ! -e "$ca_crt" ] && [ ! -e "$ca_key" ]; then
              step certificate create "VM CA" "$ca_crt" "$ca_key" \
                --profile root-ca \
                --not-after 87600h \
                --no-password \
                --insecure
              chmod 600 "$ca_key"
              chmod 644 "$ca_crt"
              echo "Created CA certificate and key in $tls_dir"
            else
              echo "CA files already exist, skipping generation"
            fi

            if [ -e "$tls_crt" ] && [ ! -e "$tls_key" ]; then
              echo "error: $tls_crt exists but $tls_key is missing" >&2
              exit 1
            fi
            if [ -e "$tls_key" ] && [ ! -e "$tls_crt" ]; then
              echo "error: $tls_key exists but $tls_crt is missing" >&2
              exit 1
            fi

            if [ ! -e "$tls_crt" ] && [ ! -e "$tls_key" ]; then
              step certificate create localhost "$tls_crt" "$tls_key" \
                --ca "$ca_crt" \
                --ca-key "$ca_key" \
                --profile leaf \
                --not-after 17520h \
                --san localhost \
                --san api.anthropic.com \
                --san www.onecli.sh \
                --no-password \
                --insecure
              chmod 600 "$tls_key"
              chmod 644 "$tls_crt"
              echo "Created TLS certificate and key in $tls_dir"
            else
              echo "TLS files already exist, skipping generation"
            fi
          '';
        };
      in {
        packages = {
          inherit vm;
          onecli = onecliPkg;
          default = vm;
        };

        apps = {
          vm = {
            type = "app";
            program = lib.getExe vmApp;
          };
          tls-setup = {
            type = "app";
            program = lib.getExe tlsSetup;
          };
        };
      };
    };
}

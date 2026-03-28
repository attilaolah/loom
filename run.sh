#!/usr/bin/env bash
set -euxo pipefail

nix-build '<nixpkgs/nixos>' \
  -A config.system.build.vm \
  -I nixos-config=configuration.nix
result/bin/run-loom-vm

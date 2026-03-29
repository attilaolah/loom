#!/usr/bin/env bash
set -e

if command -v onecli >/dev/null 2>&1; then
  echo "OneCLI is already installed:"
  command -v onecli
  onecli version
else
  echo "OneCLI is not installed."
  echo "Install it via the Nix flake: https://github.com/attilaolah/loom#onecli"
  exit 1
fi

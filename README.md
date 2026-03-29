# NanoClaw NixOS setup

E simple NixOS VM config that starts a QEMU VM pre-configured for running [NanoClaw].

[NanoClaw]: https://github.com/qwibitai/nanoclaw

- Firewall allows only Llama.cpp + DNS on the host.
- Firewall denies access to the local network, but allows unrestricted internet access via QEMU's NAT.
- System packages include Claude + common tools used by agents.
- The NanoClaw repo is pre-built as a Flake dependency and copied from the store path.
- Claude basic settings are pre-configured and tweaked for local models.
- No shared mounts: communication is done via git repo, pulled from the host, guest cannot push.

## Qucikstart

Run the VM directly as a Flake app:

```sh
nix run github:attilaolah/loom#vm
```

Or clone the repo, tweak the Nix configs, build & run locally via `nix build` and `nix run .#vm`.

In another terminal, start the `llama.cpp` server with the model of your choice. Bind it to port `12000` on the qemu
host (or all hosts):

```sh
llama-server \
  --model unsloth/Qwen3-Coder-Next-GGUF/Qwen3-Coder-Next-UD-Q4_K_XL.gguf \
  --alias unsloth/Qwen3-Coder-Next \
  --n-gpu-layers 999 \
  --override-kv .ffn_.*_exps.=CPU \
  --ctx-size 131072 \
  --seed 3407 \
  --temp 1.0 \
  --top-p 0.95 \
  --min-p 0.01 \
  --top-k 40 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --threads 10 \
  --batch-size 2048 \
  --ubatch-size 1024 \
  --host 0.0.0.0 \
  --port 12000
```

SSH into the the VM as admin (the only user allowed SSH access) and switch to the agent user. Note that the agent user
has no sudo rights, while the admin has passwordless sudo, so use the admin to fix things up as necessary.

With the agent user, go to the `~/nanoclaw` dir which is already set up the way the setup skill expects it. Run
`claude` which is already set up to use the `llama.cpp` server and trust the directory.

```sh
ssh admin@localhost -p 2222
sudo su agent
cd ~/nanoclaw
claude
```

Inside Claude, run the `/setup` skill and follow the instructions.

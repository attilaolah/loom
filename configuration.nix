{
  pkgs,
  lib,
  ...
}: let
  # Users
  admin = "admin";
  agent = "agent";
  admins = [admin];
  owner = "attilaolah";
  domain = "dorn.haus";

  # Networking
  llamaRemote = "12000";
  host = n: "10.0.2.${toString n}";
  gw = host 2;
  ns = host 3;
  vm = host 15;
  hostName = "vm";
  clawPort = 18789;

  # Directories & files
  home = "/home/${agent}";
  gitConfig = "git.agent.conf";
in {
  # Networking & Firewall
  networking = {
    inherit hostName;
    firewall = {
      enable = true;
      allowedTCPPorts = [22 clawPort];

      # Restrict outgoing traffic
      extraCommands = ''
        # Allow existing connections
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # Allow DNS to the QEMU virtual DNS server
        iptables -A OUTPUT -d ${ns} -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -d ${ns} -p tcp --dport 53 -j ACCEPT

        # Allow the llama.cpp server running on the host
        iptables -A OUTPUT -d ${gw} -p tcp --dport ${llamaRemote} -j ACCEPT
        # Allow local self-access via the VM IP (used by hostname overrides)
        iptables -A OUTPUT -d ${vm} -j ACCEPT

        # Block all other traffic to private/internal ranges
        iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
        iptables -A OUTPUT -d 10.0.0.0/8 -j DROP

        # Block the rest of the host gateway
        iptables -A OUTPUT -d ${gw} -j DROP
      '';
    };
  };

  # This block is specifically for settings that only apply when building the QEMU VM via config.system.build.vm
  virtualisation = {
    vmVariant = {
      virtualisation = {
        cores = 8;
        memorySize = 32 * 1024; # 32Gi
        diskSize = 120 * 1000; # 120GB
        graphics = false;
        forwardPorts = let
          h = port: {
            inherit port;
            address = "127.0.0.1";
          };
        in [
          {
            from = "host";
            host = h 2222;
            guest.port = 22;
          }
          {
            from = "host";
            host = h clawPort;
            guest.port = clawPort;
          }
        ];
      };
    };
    docker.enable = true;
  };

  # User Management
  users = {
    users = let
      openssh.authorizedKeys.keyFiles = [
        (pkgs.fetchurl {
          url = "https://github.com/${owner}.keys";
          sha256 = "sha256-Y63CD0ZqmOhnFhRXwsp2Xb5aaoIWr7nUwHAvov38buc=";
        })
      ];
    in {
      "${admin}" = {
        inherit openssh;
        isNormalUser = true;
        extraGroups = ["docker" "nixbld" "wheel"];
        shell = pkgs.bashInteractive;
      };
      "${agent}" = {
        inherit openssh;
        isNormalUser = true;
        extraGroups = ["docker" "nixbld"];
        shell = pkgs.bashInteractive;
        linger = true;
      };
    };
    mutableUsers = false;
  };

  # Security & SSH
  security = {
    sudo.extraRules = [
      {
        users = admins;
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = admins ++ [agent];
    };
  };

  systemd = {
    tmpfiles.rules = [
      "L+ ${home}/.gitconfig - - - - /etc/${gitConfig}"
    ];
  };

  environment = {
    systemPackages = with pkgs; [
      # The main attraction
      openclaw

      # NPM + Node runtime
      # Force Node 25 with high priority to shadow Node 24 which gets pulled in via dbus
      (lib.hiPrio nodejs_25)
      nodePackages.npm
      pnpm
      deno
      bun

      # Docker
      docker
      docker-compose

      # POSIX & other tools for agents
      # binutils -- skipped in favour of clang/llvm
      attr
      coreutils
      diffutils
      findutils
      gawk
      gnugrep
      gnumake
      gnused
      patch
      unzip
      xz

      # Tooling that most agents seem to be taking for granted
      fd
      jq
      man-pages
      man-pages-posix
      ripgrep

      # For conveninet network access
      bind.dnsutils # dig
      cacert
      curl
      gh-dash
      git
      github-cli
      iputils # ping
      rsync
      wget

      # LLVM
      clang_22
      llvm_22
      gcc

      # Python: bleeding edge + stable versions
      (lib.hiPrio python315)
      python314

      # Common tools for coding tasks
      go
      cmake
      pkg-config
      zig
      uv

      # The "Investigator" Kit
      strace
      hexyl
      which
      procps
      gdb
      lldb
    ];
    etc."${gitConfig}".text = ''
      [user]
        name = DH8 Agent
        email = ${agent}@${domain}
    '';
  };
  programs = {
    git = {
      enable = true;
      config = {
        init.defaultBranch = "main";
        pull.rebase = true;
        push.autoSetupRemote = true;
      };
    };
    neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
    };
  };

  nix = {
    nixPath = ["nixpkgs=${pkgs.path}"];
    settings.experimental-features = ["nix-command" "flakes"];
  };

  documentation = {
    enable = true;
    man.enable = true;
    dev.enable = true;
  };

  nixpkgs.config = {
    allowUnfree = true;
    permittedInsecurePackages = [
      "openclaw-2026.3.12"
    ];
  };

  system.stateVersion = "26.05";
}

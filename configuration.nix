{pkgs, lib, ...}: let
  # Users:
  admin = "admin";
  agent = "agent";
  admins = [admin];

  llamaPort = "12000";
  host = n: "10.0.2.${toString n}";
  gw = host 2;
  ns = host 3;
in {
  # Networking & Firewall
  networking = {
    hostName = "vm";
    firewall = {
      enable = true;
      allowedTCPPorts = [22];

      # Restrict outgoing traffic
      extraCommands = ''
        # Allow existing connections
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # Allow DNS to the QEMU virtual DNS server
        iptables -A OUTPUT -d ${ns} -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -d ${ns} -p tcp --dport 53 -j ACCEPT

        # Allow the llama.cpp server running on the host
        iptables -A OUTPUT -d ${gw} -p tcp --dport ${llamaPort} -j ACCEPT

        # Block all other traffic to private/internal ranges
        iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
        iptables -A OUTPUT -d 10.0.0.0/8 -j DROP

        # Block the rest of the host gateway
        iptables -A OUTPUT -d ${gw} -j DROP
      '';
    };
  };

  # This block is specifically for settings that only apply
  # when building the QEMU VM via config.system.build.vm
  virtualisation = {
    vmVariant = {
      virtualisation = {
        cores = 8;
        memorySize = 32 * 1024; # 32Gi
        diskSize = 120 * 1000; # 120GB
        graphics = false;

        forwardPorts = [
          {
            from = "host";
            host.port = 2222;
            guest.port = 22;
          }
        ];
      };
    };
    docker.enable = true;
  };

  # User Management
  users = {
    users = {
      "${admin}" = {
        isNormalUser = true;
        extraGroups = ["wheel"];
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keyFiles = [
          (pkgs.fetchurl {
            url = "https://github.com/attilaolah.keys";
            sha256 = "sha256-Y63CD0ZqmOhnFhRXwsp2Xb5aaoIWr7nUwHAvov38buc=";
          })
        ];
      };
      "${agent}" = {
        isNormalUser = true;
        extraGroups = ["docker" "nixbld"];
        shell = pkgs.bashInteractive;
      };
    };
    mutableUsers = false;
  };

  # Security & SSH
  security.sudo.extraRules = [
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

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = admins;
    };
  };

  systemd = let
    gitdir = "/srv/git";
    repo = "${gitdir}/work.git";
    work = "/home/${agent}/work";
    group = "users";
  in {
    tmpfiles.rules = [
      "d ${gitdir} 0775 ${admin} ${group} -"
      # 2xxx sets the setgid bit
      "d ${repo} 2775 ${admin} ${group} -"
      "d ${work} 2775 ${agent} ${group} -"
    ];
    services.init-work = {
      description = "Initialize Git bridge between ${admin} and ${agent}";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      path = with pkgs; [coreutils git util-linux];
      script = ''
        # Initialize bare repo if it doesn't exist
        if [ ! -d ${repo}/objects ]; then
          git init --bare ${repo}
          chown -R ${admin}:${group} ${repo}
          chmod -R 2775 /srv/git/work.git
        fi

        # Initialize agent's workspace if empty
        if [ ! -d ${work}/.git ]; then
          runuser -u ${agent} -- git init ${work}
          runuser -u ${agent} -- git -C ${work} remote add origin ${repo}
        fi
      '';
      serviceConfig.Type = "oneshot";
    };
  };

  environment = {
    systemPackages = with pkgs; [
      # NPM + Node runtime
      # Force Node 25 with high priority to shadow Node 24 which gets pulled in via dbus.
      (lib.hiPrio nodejs_25)
      nodePackages.npm

      # Claude Code, the engine driving nanoclaw.
      claude-code

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

      # Common tools for coding tasks
      go
      cmake
      pkg-config
      python315
      zig

      # The "Investigator" Kit
      strace
      hexyl
      which
      procps
      gdb
      lldb
    ];
    variables = {
      ANTHROPIC_BASE_URL = "http://${gw}:${llamaPort}";
      # API key is not required by the host, but the client wants one.
      ANTHROPIC_API_KEY = "sk-local";
    };
  };
  programs.git = {
    enable = true;
    config = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
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

  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
}

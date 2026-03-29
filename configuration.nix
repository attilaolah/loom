{
  pkgs,
  lib,
  onecli,
  ...
}: let
  # Users
  admin = "admin";
  agent = "agent";
  admins = [admin];
  group = "users";
  owner = "attilaolah";

  # Networking
  llamaPort = "12000";
  host = n: "10.0.2.${toString n}";
  gw = host 2;
  ns = host 3;
  hostName = "vm";

  # Directories & files
  home = "/home/${agent}";
  workDir = "${home}/work";
  ncDir = "${home}/nanoclaw";
  claudeDir = "${home}/.claude";
  claudeSettings = "${claudeDir}/settings.json";
  claudeState = "${home}/.claude.json";
  gitDir = "/srv/git";
  repoDir = "${gitDir}/work.git";
  gitConfig = "/etc/agent.gitconfig";
  tlsDir = "/etc/tls";
  tlsCrt = "${tlsDir}/tls.crt";
  tlsKey = "${tlsDir}/tls.key";
in {
  # Networking & Firewall
  networking = {
    inherit hostName;
    extraHosts = ''
      127.0.0.1 www.onecli.sh
      ::1 www.onecli.sh
    '';
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
        sharedDirectories = {
          tls = {
            source = "$TLS_DIR";
            target = tlsDir;
          };
        };
        fileSystems."${tlsDir}".options = lib.mkAfter ["ro"];

        forwardPorts = [
          {
            from = "host";
            host.port = 2222;
            guest.port = 22;
          }
          {
            from = "host";
            host.address = "127.0.0.1";
            host.port = 10254;
            guest.address = "127.0.0.1";
            guest.port = 10254;
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
        extraGroups = ["docker" "nixbld" "wheel"];
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keyFiles = [
          (pkgs.fetchurl {
            url = "https://github.com/${owner}.keys";
            sha256 = "sha256-Y63CD0ZqmOhnFhRXwsp2Xb5aaoIWr7nUwHAvov38buc=";
          })
        ];
      };
      "${agent}" = {
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
    pki.certificateFiles = [./tls/ca.crt];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = admins;
    };
  };

  systemd = {
    tmpfiles.rules = [
      "L+ ${home}/.gitconfig - - - - ${gitConfig}"
      "d ${gitDir} 0775 ${admin} ${group} -"
      # 2xxx sets the setgid bit
      "d ${repoDir} 2775 ${admin} ${group} -"
      "d ${workDir} 2775 ${agent} ${group} -"
      # Writable nanoclaw working tree copied from the store path
      "d ${ncDir} 0755 ${agent} ${group} -"
      "d ${claudeDir} 0755 ${agent} ${group} -"
    ];

    services = {
      init-shell-path = {
        description = "PATH ~/.local/bin injection for ${agent}";
        wantedBy = ["multi-user.target"];
        path = with pkgs; [coreutils gnugrep gnused];
        script = ''
          bashrc=${home}/.bashrc
          path_line='export PATH="$PATH:${home}/.local/bin"'

          touch "$bashrc"
          if ! grep -Fqx "$path_line" "$bashrc"; then
            echo "$path_line" >> "$bashrc"
            chown ${agent}:${group} "$bashrc"
          fi
        '';
        serviceConfig.Type = "oneshot";
      };
      init-work = {
        description = "Git bridge between ${admin} and ${agent}";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];
        path = with pkgs; [coreutils git util-linux];
        script = ''
          # Initialize bare repo if it doesn't exist
          if [ ! -d ${repoDir}/objects ]; then
            git init --bare ${repoDir}
            chown -R ${admin}:${group} ${repoDir}
            chmod -R 2775 ${repoDir}
          fi

          # Initialize agent's workspace if empty
          if [ ! -d ${workDir}/.git ]; then
            runuser -u ${agent} -- git init ${workDir}
            runuser -u ${agent} -- git -C ${workDir} remote add origin ${repoDir}
          fi
        '';
        serviceConfig.Type = "oneshot";
      };
      init-claude = {
        description = "Claude settings for ${agent}";
        wantedBy = ["multi-user.target"];
        path = with pkgs; [coreutils];
        script = ''
          if [ ! -f ${claudeState} ]; then
            install -m 0644 -o ${agent} -g ${group} ${./claude/state.json} ${claudeState}
          fi

          if [ ! -f ${claudeSettings} ]; then
            install -m 0644 -o ${agent} -g ${group} ${./claude/settings.json} ${claudeSettings}
          fi
        '';
        serviceConfig.Type = "oneshot";
      };
      init-nanoclaw = {
        description = "NanoClaw git setup for ${agent}";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];
        path = with pkgs; [coreutils git util-linux];
        script = ''
          if [ -d ${ncDir} ]; then
            echo "${ncDir} already exists, nothing to do"
            exit 0
          fi

          mkdir -p ${ncDir}
          runuser -u ${agent} -- git clone https://github.com/qwibitai/nanoclaw.git ${ncDir}
          runuser -u ${agent} -- git -C ${ncDir} remote rename origin upstream
          # Add a fork, even though it may not exist, to satisfy the setup script
          runuser -u ${agent} -- git -C ${ncDir} remote add origin https://github.com/${owner}/nanoclaw.git
        '';
        serviceConfig.Type = "oneshot";
      };
    };
  };

  services.caddy = {
    enable = true;
    virtualHosts."www.onecli.sh".extraConfig = ''
      bind 127.0.0.1
      tls ${tlsCrt} ${tlsKey}

      @install path /cli/install
      handle @install {
        header Content-Type text/plain
        root * /
        rewrite * ${./onecli/install.sh}
        file_server
      }

      handle {
        reverse_proxy https://www.onecli.sh {
          header_up Host www.onecli.sh
        }
      }
    '';
  };

  environment = {
    systemPackages = with pkgs; [
      # NPM + Node runtime
      # Force Node 25 with high priority to shadow Node 24 which gets pulled in via dbus
      (lib.hiPrio nodejs_25)
      nodePackages.npm

      # Claude Code
      # NanoClaw setup is implemented via a Claude Code skill so this is required, sadly
      claude-code
      onecli

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

      # Python: a few older versions for convenience
      python315
      python314
      python313

      # Common tools for coding tasks
      go
      cmake
      pkg-config
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
      # API key is not required by the host, but the client wants one
      ANTHROPIC_API_KEY = "sk-ant-local";
    };
    etc."agent.gitconfig".text = ''
      [user]
        name = NanoClaw Agent
        email = agent@${hostName}
    '';
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

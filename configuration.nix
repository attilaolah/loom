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
  llamaRemote = "12000";
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

  dnsAnthropic = "api.anthropic.com";
  dnsOneCli = "www.onecli.sh";

  setupNanoClaw = pkgs.writeShellApplication {
    name = "setup-nanoclaw";
    runtimeInputs = with pkgs; [git claude-code];
    text = ''
      set -euo pipefail

      mkdir -p ${ncDir}
      cd ${ncDir}

      if [ ! -d .git ]; then
        git clone https://github.com/qwibitai/nanoclaw.git .
      fi

      if git remote get-url origin >/dev/null 2>&1; then
        if ! git remote get-url upstream >/dev/null 2>&1; then
          git remote rename origin upstream
        fi
      fi

      if ! git remote get-url origin >/dev/null 2>&1; then
        # Add a fork, even though it may not exist, to satisfy the setup script.
        git remote add origin https://github.com/${owner}/nanoclaw.git
      fi

      exec claude
    '';
  };
in {
  # Networking & Firewall
  networking = {
    inherit hostName;
    nameservers = ["127.0.0.1" "::1"];
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
        iptables -A OUTPUT -d ${gw} -p tcp --dport ${llamaRemote} -j ACCEPT

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
    pki.certificateFiles = [./tls/ca.crt];
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
      "L+ ${home}/.gitconfig - - - - ${gitConfig}"
      "d ${gitDir} 0775 ${admin} ${group} -"
      # 2xxx sets the setgid bit
      "d ${repoDir} 2775 ${admin} ${group} -"
      "d ${workDir} 2775 ${agent} ${group} -"
      # Writable nanoclaw working tree copied from the store path
      "d ${claudeDir} 0755 ${agent} ${group} -"
    ];

    services = {
      tls-permissions = {
        description = "TLS permission fixup";
        wantedBy = ["multi-user.target"];
        before = ["caddy.service"];
        after = ["local-fs.target"];
        path = with pkgs; [coreutils];
        script = ''
          chown root:root ${tlsDir}/ca.crt ${tlsDir}/ca.key
          chown root:caddy ${tlsDir}/tls.crt ${tlsDir}/tls.key
          chmod 0644 ${tlsDir}/ca.crt
          chmod 0600 ${tlsDir}/ca.key
          chmod 0440 ${tlsDir}/tls.crt
          chmod 0440 ${tlsDir}/tls.key
        '';
        serviceConfig.Type = "oneshot";
      };
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
      coredns = {
        description = "CoreDNS rewrite proxy for .real names";
        wants = ["network-online.target"];
        after = ["network-online.target" "nss-lookup.target"];
        before = ["caddy.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = let
            corefile = pkgs.writeText "Corefile-real-proxy" ''
              ${dnsOneCli}.real:53 {
                bind 127.0.0.1 ::1
                rewrite name exact ${dnsOneCli}.real ${dnsOneCli}
                forward . ${ns}
                cache 30
              }

              .:53 {
                bind 127.0.0.1 ::1
                hosts {
                  127.0.0.1 ${dnsAnthropic} ${dnsOneCli}
                  ::1 ${dnsAnthropic} ${dnsOneCli}
                  fallthrough
                }
                forward . ${ns}
                cache 30
              }
            '';
          in "${pkgs.lib.getExe pkgs.coredns} -conf ${corefile}";
          Restart = "always";
          RestartSec = 2;
        };
      };
      caddy = {
        wants = ["coredns.service"];
        after = ["coredns.service"];
      };
    };
  };

  services.caddy = {
    enable = true;
    virtualHosts = let
      bind = ''
        bind 127.0.0.1 ::1
        tls ${tlsCrt} ${tlsKey}
      '';
      llama.extraConfig = ''
        ${bind}

        handle {
          reverse_proxy http://${gw}:${llamaRemote} {
            header_up Host localhost
          }
        }
      '';
    in {
      ${dnsAnthropic} = llama;
      ${dnsOneCli}.extraConfig = ''
        ${bind}

        @install path /cli/install
        handle @install {
          header Content-Type text/plain
          root * /
          rewrite * ${./onecli/install.sh}
          file_server
        }

        handle {
          # Resolved via the CoreDNS proxy to avoid an infinite recursion via this vhost.
          reverse_proxy https://${dnsOneCli}.real {
            header_up Host ${dnsOneCli}
            transport http {
              tls_server_name ${dnsOneCli}
            }
          }
        }
      '';
    };
  };

  environment = {
    systemPackages = with pkgs; [
      # NPM + Node runtime
      # Force Node 25 with high priority to shadow Node 24 which gets pulled in via dbus
      (lib.hiPrio nodejs_25)
      nodePackages.npm

      # Claude Code and manual NanoClaw bootstrap helper
      setupNanoClaw
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

      # Python: bleeding edge + stable versions
      (lib.hiPrio python315)
      python314

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

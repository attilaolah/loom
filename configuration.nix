{pkgs, ...}: let
  # Users:
  admin = "admin";
  agent = "agent";
  admins = [admin];
in {
  # Networking & Firewall
  networking = {
    hostName = "loom";
    firewall = {
      enable = true;
      allowedTCPPorts = [22];

      # Restrict outgoing traffic
      extraCommands = let
        host = n: "10.0.2.${toString n}";
        gw = host 2;
        ns = host 3;
      in ''
        # Allow existing connections
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # Allow DNS to the QEMU virtual DNS server
        iptables -A OUTPUT -d ${ns} -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -d ${ns} -p tcp --dport 53 -j ACCEPT

        # Allow the llama.cpp server running on the host
        iptables -A OUTPUT -d ${gw} -p tcp --dport 12000 -j ACCEPT

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
  virtualisation.vmVariant = {
    virtualisation = {
      cores = 8;
      memorySize = 32 * 1024; # MiB
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
        extraGroups = ["nixbld"];
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
  in {
    tmpfiles.rules = [
      "d ${gitdir} 0775 ${admin} users -"
      "d ${repo} 2775 ${admin} users -" # 2xxx sets the setgid bit
      "d ${work} 2775 ${agent} users -"
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
          chown -R ${admin}:users ${repo}
        fi

        # Create the post-receive hook to sync the agent's folder
        cat << 'EOF' > ${repo}/hooks/post-receive
        #!/usr/bin/env bash
        # When the admin receives a push, update the agent's working directory
        echo "Syncing agent workspace..."
        export GIT_WORK_TREE=${work}
        export GIT_DIR=${repo}
        git checkout -f
        # Ensure agent owns the checked-out files
        chown -R ${agent}:users ${work}
        EOF
        chmod +x ${repo}/hooks/post-receive

        # Initialize agent's workspace if empty
        if [ ! -d ${work}/.git ]; then
          runuser -u ${agent} -- git init ${work}
          # Point the agent to the local bare repo
          runuser -u ${agent} -- git -C ${work} remote add origin ${repo}
        fi
      '';
      serviceConfig.Type = "oneshot";
    };
  };

  environment = {
    systemPackages = with pkgs; [git];
    etc.gitconfig.text = ''
      [init]
        defaultBranch = main
    '';
  };

  system.stateVersion = "26.05";
}

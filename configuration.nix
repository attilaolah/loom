{pkgs, ...}: let
  admins = ["admin"];
in {
  # Networking & Firewall
  networking = {
    hostName = "loom";
    firewall = {
      enable = true;
      allowedTCPPorts = [22];

      # Restrict outgoing traffic
      extraCommands = ''
        # 1. Allow existing connections
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # 2. The llama.cpp server running on the host
        iptables -A OUTPUT -d 10.0.2.2 -p tcp --dport 12000 -j ACCEPT

        # 3. Block everything else to internal ranges
        iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
        iptables -A OUTPUT -d 10.0.0.0/8 -j DROP

        # 4. Block the rest of the host access
        iptables -A OUTPUT -d 10.0.2.2 -j DROP
      '';
    };
  };

  # This block is specifically for settings that only apply
  # when building the QEMU VM via config.system.build.vm
  virtualisation.vmVariant = {
    virtualisation = {
      forwardPorts = [
        {
          from = "host";
          host.port = 2222;
          guest.port = 22;
        }
      ];
      memorySize = 32 * 1024; # MiB
    };
  };

  # User Management
  users = {
    users = {
      admin = {
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
      agent = {
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

  system.stateVersion = "26.05";
}

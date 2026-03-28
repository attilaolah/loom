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
        # Block common private IP ranges
        iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
        iptables -A OUTPUT -d 10.0.0.0/8 -j DROP

        # Allow only port 12000 to the QEMU host gateway (typically 10.0.2.2)
        iptables -A OUTPUT -d 10.0.2.2 -p tcp --dport 12000 -j ACCEPT
        iptables -A OUTPUT -d 10.0.2.2 -j DROP
      '';
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

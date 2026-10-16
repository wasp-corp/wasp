{pkgs, ...}: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  documentation.nixos.enable = false;

  virtualisation.vmVariant = {
    virtualisation.memorySize = 2048;
  };

  nix = {
    settings = {
      trusted-users = [
        "root"
        "wasp"
      ];
    };
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  users.mutableUsers = false;

  users.groups.wasp = {};

  users.users.wasp = {
    isNormalUser = true;
    description = "Wasp";
    group = "wasp";
    extraGroups = ["wheel"];
    hashedPassword = "";
  };

  environment.systemPackages = [
    pkgs.kitty
    pkgs.fish
    pkgs.wasp
    pkgs.helix
    pkgs.neovim
    pkgs.xterm
    pkgs.zsh
  ];

  security.polkit = {
    enable = true;
  };

  services.dbus = {
    enable = true;
  };

  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "wasp";
    };
  };

  services.libinput = {
    enable = true;
  };

  services.qemuGuest = {
    enable = true;
  };

  services.spice-vdagentd = {
    enable = true;
  };

  services.xserver = {
    enable = true;
  };
}

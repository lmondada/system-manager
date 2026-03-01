{ lib, pkgs, wrapNixGl, ... }:
let
  # jellyfin-ffmpeg = wrapNixGl {
  #   name = "ffmpeg";
  #   pkg = pkgs.jellyfin-ffmpeg;
  #   libs = [ "libnvidia-encode" "libnvcuvid" ];
  # };
  jellyfin-ffmpeg = pkgs.jellyfin-ffmpeg;

  jellyfin = pkgs.jellyfin.override {
    inherit jellyfin-ffmpeg;
  };
in
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system-manager.allowAnyDistro = true;

    systemd.services.jellyfin = {
      description = "Jellyfin Media Server";
      enable = true;

      wantedBy = [ "system-manager.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";

        ExecStart = ''
          ${jellyfin}/bin/jellyfin \
            --datadir /var/lib/jellyfin/data \
            --configdir /var/lib/jellyfin/config \
            --cachedir /var/lib/jellyfin/cache
        '';

        Restart = "on-failure";
        RestartSec = 5;

        # Run Jellyfin as an unprivileged user
        User = "jellyfin";
        # StateDirectory = "jellyfin"; # this creates /var/lib/jellyfin
        # CacheDirectory = "jellyfin"; # this creates /var/cache/jellyfin
        # ConfigurationDirectory = "jellyfin"; # this creates /etc/jellyfin
        # SupplementaryGroups = "media"; # so it can access /home/media

        # Hardening
        # NoNewPrivileges = true;
        # PrivateTmp = true

        # Environment = ''
        #   HOME=/var/lib/jellyfin
        # '';

        # Set SELinux Context
        SELinuxContext = "system_u:system_r:unconfined_service_t:s0";

        # # NVIDIA GPU access
        DeviceAllow = [
          "/dev/nvidiactl"
          "/dev/nvidia0"
          "/dev/nvidia-modeset"
          "/dev/nvidia-uvm"
        ];

        # # FFmpeg hardware acceleration for NVIDIA
        # Environment = ''
        #   NVIDIA_DRIVER_CAPABILITIES=all
        #   NVIDIA_VISIBLE_DEVICES=all
        # '';
        # #   JELLYFIN_FFMPEG_OPTIONS="-hwaccel cuda -hwaccel_output_format cuda"

        # # Bind mount the libraries into the service sandbox
        # BindPaths = [
        #   "/usr/lib64"
        # ];
      };
    };
  };
}

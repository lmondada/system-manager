{ pkgs, lib, wrapNixGl, ... }:
let
  immichPkg = pkgs.immich;

  # Wrap the machine-learning binary with nixglhost so it can find the
  # host NVIDIA drivers (same pattern as jellyfin-ffmpeg in jellyfin.nix).
  immich-machine-learning = wrapNixGl {
    name = "machine-learning";
    pkg  = immichPkg.machine-learning;
    libs = [ ];
  };

  # Convenience paths
  pgSocketDir  = "/run/postgresql";
  redisSocket  = "/run/redis-immich/redis.sock";
  mediaDir     = "/var/lib/immich";
  cacheDir     = "/var/cache/immich";

  # Environment shared by both Immich services
  commonEnv = {
    # Database – connect via unix socket (no password needed with peer auth)
    DB_URL = "postgresql:///immich?host=${pgSocketDir}";

    # Redis – unix socket, no TCP
    REDIS_SOCKET = redisSocket;

    # Media
    IMMICH_MEDIA_LOCATION = mediaDir;
  };

  commonServiceConfig = {
    Type    = "simple";
    Restart = "on-failure";
    RestartSec = 5;

    User  = "immich";
    Group = "immich";

    # SELinux – same approach as jellyfin.nix
    SELinuxContext = "system_u:system_r:unconfined_service_t:s0";

    # NVIDIA GPU access (for both transcoding and ML inference)
    DeviceAllow = [
      "/dev/nvidiactl"
      "/dev/nvidia0"
      "/dev/nvidia-modeset"
      "/dev/nvidia-uvm"
    ];

    # Hardening (relaxed where NVIDIA device access or nix_store_t requires it)
    NoNewPrivileges = true;
    PrivateTmp      = true;
    ProtectHome     = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  };

  commonAfter = [
    "network.target"
    "immich-setup-users.service"
    "postgresql-immich.service"
    "redis-immich.service"
  ];
  commonRequires = [
    "immich-setup-users.service"
    "postgresql-immich.service"
    "redis-immich.service"
  ];
in
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system-manager.allowAnyDistro = true;

    systemd.services.immich-server = {
      description = "Immich photo/video backup – main server";
      wantedBy    = [ "system-manager.target" ];
      after       = commonAfter;
      requires    = commonRequires;

      environment = commonEnv // {
        IMMICH_HOST = "0.0.0.0";
        IMMICH_PORT = "2283";
        IMMICH_MACHINE_LEARNING_URL = "http://localhost:3003";
      };

      serviceConfig = commonServiceConfig // {
        ExecStart = "${immichPkg}/bin/server";
      };
    };

    systemd.services.immich-machine-learning = {
      description = "Immich machine-learning service (face recognition, CLIP, duplicate detection)";
      wantedBy    = [ "system-manager.target" ];
      after       = commonAfter;
      requires    = commonRequires;

      environment = commonEnv // {
        # The ML service listens on its own port, only reachable from localhost
        IMMICH_HOST = "localhost";
        IMMICH_PORT = "3003";

        # Worker tuning
        MACHINE_LEARNING_WORKERS         = "1";
        MACHINE_LEARNING_WORKER_TIMEOUT  = "120";

        # Cache for downloaded model weights
        MACHINE_LEARNING_CACHE_FOLDER = cacheDir;
        XDG_CACHE_HOME                = cacheDir;
      };

      serviceConfig = commonServiceConfig // {
        ExecStart = "${immich-machine-learning}/bin/machine-learning";
      };
    };
  };
}

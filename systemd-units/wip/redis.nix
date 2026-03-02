{ pkgs, lib, ... }:
let
  redisUser   = "redis-immich";
  redisGroup  = "redis-immich";
  stateDir    = "/var/lib/redis-immich";
  runtimeDir  = "redis-immich";            # relative: systemd creates /run/redis-immich
  socketPath  = "/run/redis-immich/redis.sock";

  # Generate a redis.conf in the nix store pointing at the unix socket.
  # The ExecStartPre script copies it to the mutable state dir so Redis can
  # write its RDB dump alongside it.
  redisConf = pkgs.writeText "redis-immich.conf" ''
    daemonize no
    supervised systemd

    # No TCP – unix socket only
    port 0
    unixsocket ${socketPath}
    unixsocketperm 660

    # Persistence (RDB)
    dir ${stateDir}
    dbfilename dump.rdb
    save 900 1
    save 300 10
    save 60 10000

    loglevel notice
    databases 16
    maxclients 10032
  '';

  # prep script: write the immutable nix-store conf path into the mutable
  # per-instance conf file (mirrors the nixpkgs redis module pattern).
  prepScript = pkgs.writeShellScript "redis-immich-prep" ''
    CONF="${stateDir}/redis.conf"
    touch "$CONF"
    chown '${redisUser}':'${redisGroup}' "$CONF"
    chmod 0600 "$CONF"
    # Only write the include directive if the file is empty (first boot)
    if [ ! -s "$CONF" ]; then
      echo 'include "${redisConf}"' > "$CONF"
    fi
  '';
in
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system-manager.allowAnyDistro = true;

    systemd.services.redis-immich = {
      description = "Redis server for Immich (unix socket, no TCP)";
      wantedBy = [ "system-manager.target" ];
      after    = [ "network.target" "immich-setup-users.service" ];
      requires = [ "immich-setup-users.service" ];

      serviceConfig = {
        Type    = "notify";
        Restart = "on-failure";

        ExecStartPre = "+${prepScript}";   # '+' runs as root
        ExecStart    = "${pkgs.redis}/bin/redis-server ${stateDir}/redis.conf";

        User  = redisUser;
        Group = redisGroup;

        RuntimeDirectory     = runtimeDir;
        RuntimeDirectoryMode = "0750";
        StateDirectory       = "redis-immich";
        StateDirectoryMode   = "0700";

        UMask = "0077";

        # SELinux
        SELinuxContext = "system_u:system_r:unconfined_service_t:s0";

        # Hardening (relaxed from nixpkgs defaults where needed by SELinux context)
        NoNewPrivileges = true;
        PrivateTmp      = true;
        ProtectHome     = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        MemoryDenyWriteExecute  = true;
      };
    };
  };
}

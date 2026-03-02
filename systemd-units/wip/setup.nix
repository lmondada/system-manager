{ pkgs, lib, ... }:
let
  # Script to idempotently create system users and groups needed by Immich stack.
  # Runs as a oneshot service before the rest of the services start.
  setup-script = pkgs.writeShellApplication {
    name = "immich-setup-users";
    runtimeInputs = [ pkgs.shadow pkgs.coreutils ];
    text = ''
      # Create a group if it doesn't exist
      ensure_group() {
        local group="$1"
        echo "Ensuring group exists: $group"
        groupadd --system --force "$group"
      }

      # Create a system user if it doesn't exist
      ensure_user() {
        local user="$1"
        local home="$2"
        local group="$3"
        if id "$user" >/dev/null 2>&1; then
          echo "User $user already exists, skipping creation."
        else
          echo "Creating user: $user"
          # We use || true just in case a race condition occurs 
          # between the 'id' check and the 'useradd' command.
          useradd \
            --system \
            --no-create-home \
            --home-dir "$home" \
            --gid "$group" \
            "$user" || true
        fi
      }

      # --- Groups ---
      ensure_group "postgres"
      ensure_group "redis-immich"
      ensure_group "immich"

      # --- Users ---
      ensure_user "postgres"      "/var/lib/postgresql"  "postgres"
      ensure_user "redis-immich"  "/var/lib/redis-immich" "redis-immich"
      ensure_user "immich"        "/var/lib/immich"       "immich"
      
      # Immich needs access to the Redis socket, which is owned by redis-immich
      usermod -aG redis-immich immich

      # --- Directories ---
      mkdir -p /var/lib/postgresql
      chown postgres:postgres /var/lib/postgresql
      chmod 0700 /var/lib/postgresql

      mkdir -p /var/lib/immich
      chown immich:immich /var/lib/immich
      chmod 0700 /var/lib/immich

      mkdir -p /var/cache/immich
      chown immich:immich /var/cache/immich
      chmod 0700 /var/cache/immich

      mkdir -p /var/lib/redis-immich
      chown redis-immich:redis-immich /var/lib/redis-immich
      chmod 0700 /var/lib/redis-immich
    '';
  };
in
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system-manager.allowAnyDistro = true;

    systemd.services.immich-setup-users = {
      description = "Create system users and directories for Immich stack";
      wantedBy = [ "system-manager.target" ];
      before = [
        "immich-postgresql.service"
        "redis-immich.service"
        "immich-server.service"
        "immich-machine-learning.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${setup-script}/bin/immich-setup-users";
        # This tells shadow-utils to skip SSSD interaction:
        Environment = "SSSD_SKIP_CLIENT_CHECK=1"; 
        # Needs root to create users/groups and set directory ownership
        User = "root";
        SELinuxContext = "system_u:system_r:unconfined_service_t:s0";
      };
    };
  };
}

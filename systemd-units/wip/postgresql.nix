{ pkgs, lib, ... }:
let
  pgUser    = "postgres";
  pgGroup   = "postgres";
  dataDir   = "/var/lib/postgresql";
  socketDir = "/run/postgresql";  # systemd will create this via RuntimeDirectory

  # PostgreSQL 16 with the extensions Immich needs.
  # Note: vectorchord requires postgres < 17; use postgresql_16.
  pg = pkgs.postgresql_16.withPackages (ps: [
    ps.pgvector      # provides the `vector` type used by VectorChord
    ps.vectorchord   # vchord.so – Immich's preferred vector index since 25.11
  ]);

  # postgresql.conf – written to the nix store, then symlinked from $PGDATA.
  # Uses a regular "..." string to avoid Nix ''...'' quoting conflicts with
  # PostgreSQL's single-quoted config values.
  pgConf = pkgs.writeText "postgresql.conf" (
    # listen_addresses = '' (empty) means: no TCP, unix socket only
    "listen_addresses = ''\n"
    + "unix_socket_directories = '${socketDir}'\n"
    + "port = 5432\n"
    + "\n"
    + "shared_preload_libraries = 'vchord.so'\n"
    + "\n"
    + "# Immich uses these for vector search path\n"
    + "search_path = '\"$user\", public, vectors'\n"
    + "\n"
    + "log_destination = 'stderr'\n"
    + "log_line_prefix = '[%p] '\n"
    + "logging_collector = off\n"
  );


  # pg_hba.conf – peer auth for local unix socket connections.
  pgHba = pkgs.writeText "pg_hba.conf" ''
    # TYPE  DATABASE   USER       ADDRESS   METHOD
    local   all        postgres             peer
    local   immich     immich               peer
    local   all        all                  reject
  '';

  # One-time SQL to set up the immich database, user, and required extensions.
  # Runs via ExecStartPost on postgresql-immich.service (idempotent).
  # Note: $$ (PL/pgSQL dollar-quoting) must be written as ''$${...}'' in Nix ''..''
  # strings to avoid interpolation; here we use a simple DO block without $$.
  setupSql = pkgs.writeText "immich-pg-setup.sql" ''
    -- Create the immich role if it does not exist
    DO $do$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'immich') THEN
        CREATE ROLE immich LOGIN;
      END IF;
    END
    $do$;

    -- Create immich database owned by immich if it does not exist
    SELECT 'CREATE DATABASE immich OWNER immich'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'immich')\gexec

    -- Extensions (must be run connected to the immich database)
    \connect immich
    CREATE EXTENSION IF NOT EXISTS "unaccent";
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "cube";
    CREATE EXTENSION IF NOT EXISTS "earthdistance";
    CREATE EXTENSION IF NOT EXISTS "pg_trgm";
    CREATE EXTENSION IF NOT EXISTS "vector";
    CREATE EXTENSION IF NOT EXISTS "vchord";
    ALTER EXTENSION "unaccent"      UPDATE;
    ALTER EXTENSION "uuid-ossp"     UPDATE;
    ALTER EXTENSION "cube"          UPDATE;
    ALTER EXTENSION "earthdistance" UPDATE;
    ALTER EXTENSION "pg_trgm"       UPDATE;
    ALTER EXTENSION "vector"        UPDATE;
    ALTER EXTENSION "vchord"        UPDATE;
    ALTER SCHEMA public OWNER TO immich;
  '';


  preStartScript = pkgs.writeShellApplication {
    name = "postgresql-pre-start";
    runtimeInputs = [ pg pkgs.coreutils ];
    text = ''
      PGDATA="${dataDir}"
      if [ ! -f "$PGDATA/PG_VERSION" ]; then
        echo "Initialising PostgreSQL data directory..."
        initdb \
          --auth=peer \
          --pgdata="$PGDATA" \
          --username="${pgUser}"
      fi
      # Always refresh the config symlinks so nix updates take effect.
      ln -sfn "${pgConf}" "$PGDATA/postgresql.conf"
      ln -sfn "${pgHba}"  "$PGDATA/pg_hba.conf"
    '';
  };

  postStartScript = pkgs.writeShellApplication {
    name = "postgresql-post-start";
    runtimeInputs = [ pg ];
    text = ''
      # Wait until postgres is accepting connections.
      until pg_isready --username="${pgUser}" --host="${socketDir}"; do
        sleep 0.5
      done
      psql --username="${pgUser}" --host="${socketDir}" \
           --dbname="postgres" \
           --file="${setupSql}"
    '';
  };
in
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system-manager.allowAnyDistro = true;

    systemd.services.postgresql-immich = {
      description = "PostgreSQL 16 database server for Immich";
      wantedBy    = [ "system-manager.target" ];
      after       = [ "network.target" "immich-setup-users.service" ];
      requires    = [ "immich-setup-users.service" ];

      environment = {
        PGDATA = dataDir;
      };

      path = [ pg ];

      serviceConfig = {
        Type    = "notify";
        Restart = "on-failure";

        ExecStart    = "${pg}/bin/postgres";
        ExecStartPre = "${preStartScript}/bin/postgresql-pre-start";
        ExecStartPost = "${postStartScript}/bin/postgresql-post-start";
        ExecReload   = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";

        User  = pgUser;
        Group = pgGroup;

        # systemd creates and owns /run/postgresql (the socket dir)
        RuntimeDirectory     = "postgresql";
        RuntimeDirectoryMode = "0755";

        KillSignal  = "SIGINT";   # PostgreSQL "Fast Shutdown"
        KillMode    = "mixed";
        TimeoutSec  = 120;

        # SELinux
        SELinuxContext = "system_u:system_r:unconfined_service_t:s0";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp      = true;
        ProtectHome     = true;
      };
    };
  };
}

{ pkgs, ... }:
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system-manager.allowAnyDistro = true;

    systemd.services.immich-docker = {
      description = "Immich photo/video backup (Docker Compose)";
      wantedBy = [ "system-manager.target" ];
      after = [ "network.target" "docker.service" ];
      requires = [ "docker.service" ];

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/home/oettam/system-manager/immich";
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
        Restart = "always";

        # Set SELinux Context
        SELinuxContext = "system_u:system_r:unconfined_service_t:s0";
      };
    };
  };
}

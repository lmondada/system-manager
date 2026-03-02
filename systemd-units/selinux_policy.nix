# Relax SELinux policy for system-manager
# Obtained from https://github.com/numtide/system-manager/issues/115
{
  pkgs,
  lib,
  config,
  ...
}: let
  # Policy file content
  policy-file = pkgs.writeText "allow-system-manager.te" ''
    module allow-system-manager 1.0;
    require {
            type default_t;
            type tmpfs_t;
            type ifconfig_t;
            type init_t;
            type systemd_unit_file_t;
            attribute domain;
            attribute file_type;
            class cap_userns net_admin;
            class lnk_file { read getattr };
            class dir { search getattr open read };
            class file { execute execute_no_trans map open read ioctl entrypoint getattr };
    }
    
    # Define generic type for the nix store
    type nix_store_t;
    typeattribute nix_store_t file_type;

    # Allow all domains to read/execute from the nix store
    allow domain nix_store_t:file { execute getattr open read map entrypoint };
    allow domain nix_store_t:dir { getattr search open read };
    allow domain nix_store_t:lnk_file { getattr read };

    #============= ifconfig_t ==============
    allow ifconfig_t self:cap_userns net_admin;
    allow ifconfig_t tmpfs_t:lnk_file read;
    #============= init_t ==============
    allow init_t default_t:file map;
    allow init_t default_t:file { execute execute_no_trans open read ioctl };
    allow init_t default_t:lnk_file read;
    # Allow systemd to read systemd unit files with default_t context
    allow init_t default_t:file read;
    
    # Allow init to execute nix_store_t (transition to other domains)
    allow init_t nix_store_t:file { execute execute_no_trans open read map };
  '';

  # File contexts
  fc-file = pkgs.writeText "allow-system-manager.fc" ''
    /nix/store(/.*)?  system_u:object_r:nix_store_t:s0
  '';

  # Pre-compiled SELinux policy package
  policy-package =
    pkgs.runCommand "allow-system-manager.pp" {
      buildInputs = [pkgs-old.policycoreutils pkgs-old.checkpolicy pkgs-old.semodule-utils];
    } ''
      checkmodule -M -m -o allow-system-manager.mod ${policy-file}
      semodule_package -o $out -m allow-system-manager.mod -f ${fc-file}
    '';
  
  # This is required because of a mismatch between fedora's versions and nix's. A better fix would be to expose
  # the fedora versions in nix...
  # pkgs-old = import (builtins.fetchGit {
  #     # Descriptive name to make the store path easier to identify
  #     name = "old-for-pcre2";
  #     url = "https://github.com/NixOS/nixpkgs/";
  #     ref = "refs/heads/nixpkgs-unstable";
  #     rev = "535b720589a07bd9d97c0e982ed94a4fed245d0f";
  # }) {};

  pkgs-old = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/535b720589a07bd9d97c0e982ed94a4fed245d0f.tar.gz";
    sha256 = "sha256:0pfrg7mpj18mmn9vc1va2xibq8bpyl0jqj491pw28ngpn6kxl65j";
  }) { 
    system = pkgs.stdenv.hostPlatform.system;
  };

  # Script to install the policy idempotently
  install-script = pkgs.writeShellApplication {
    name = "install-selinux-policy";
    runtimeInputs = [pkgs-old.libsemanage pkgs-old.policycoreutils];
    text = ''
      set -e
      STATE_FILE="/var/lib/system-manager/state/selinux-policy-installed"
      CURRENT_POLICY="${policy-package}"

      mkdir -p "$(dirname "$STATE_FILE")"

      if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$CURRENT_POLICY" ]; then
        echo "SELinux policy is up to date."
        exit 0
      fi

      echo "Installing SELinux policy..."
      
      # Remove old module if exists (optional cleanup, strictly not needed if we overwrite, but good for safety)
      semodule -r allow-system-manager 2>/dev/null || true
      
      # Install pre-built policy package
      semodule -i "$CURRENT_POLICY"

      # Fix contexts and reload
      # We only run this if the policy actually changed
      echo "Relabeling Nix Store (this may take a while)..."
      restorecon -R /nix/store
      
      restorecon -R /etc/systemd/system/
      systemctl daemon-reload
      
      echo "$CURRENT_POLICY" > "$STATE_FILE"
      echo "SELinux policy installed and state updated."
    '';
  };
in {
  config = {
    systemd.services.system-manager-selinux-policy = {
      description = "Install System Manager SELinux Policy";
      after = ["network.target"];
      wantedBy = ["system-manager.target"];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${install-script}/bin/install-selinux-policy";
      };
    };
  };
}

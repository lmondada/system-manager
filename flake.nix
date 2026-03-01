{
  description = "Standalone System Manager configuration";

  inputs = {
    # Specify the source of System Manager and Nixpkgs.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixglhost helps bridge host GL/Vulkan/NVIDIA drivers to Nix
    nixglhost.url = "github:lmondada/nix-gl-host";
  };

  outputs =
    {
      self,
      nixpkgs,
      system-manager,
      nixglhost,
      ...
    }:
    let
      system = "x86_64-linux";
      wrapNixGl = import ./utils/wrapNixGl.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        nixglhostPackage = nixglhost.packages.${system}.default;
      };
    in
    {
      systemConfigs.default = system-manager.lib.makeSystemConfig {
        # Specify your system configuration modules here, for example,
        # the path to your system.nix.
        modules = [ ./systemd-units/jellyfin.nix ./systemd-units/selinux_policy.nix ];
        extraSpecialArgs = {
          inherit wrapNixGl;
        };
      };
      packages.${system}.check-ffmpeg = wrapNixGl {
        name = "ffmpeg";
        pkg = nixpkgs.legacyPackages.${system}.jellyfin-ffmpeg;
        libs = [ "libnvidia-encode" "libnvcuvid" ];
      };
  };
}

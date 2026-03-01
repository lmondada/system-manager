{ pkgs, nixglhostPackage }:

{ name, pkg, libs ? [] }:

let
  libsFlags = map (lib: "-l${lib}") libs;
  libsArgs = builtins.concatStringsSep " " libsFlags;
in
pkgs.writeShellScriptBin name ''
  ${nixglhostPackage}/bin/nixglhost ${libsArgs} ${pkg}/bin/${name} "$@"
''

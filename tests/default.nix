# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  net = impurifier.makeNetRpm { pkg = pkgs.hello; };
  offline = impurifier.makeOfflineRpm { pkg = pkgs.hello; };
  closure = pkgs.closureInfo {
    rootPaths = [
      net
      offline
    ];
  };
in
{
  unit = impurifier.unit;
  emitter = pkgs.runCommand "rpm-impurifier-emitter" { nativeBuildInputs = [ pkgs.rpm ]; } ''
    test "$(rpm -qp --qf '%{NAME}' ${impurifier.makeNetRpm { pkg = pkgs.hello; }})" = hello-net
    rpm -qp --provides ${impurifier.makeOfflineRpm { pkg = pkgs.hello; }} | grep '^hello = '
    rpm -qp --requires ${
      impurifier.makeRuntimeRpm { nixDependency = "my-nix-runtime"; }
    } | grep '^my-nix-runtime$'
    test "$(wc -l < ${closure}/store-paths)" = 2
    touch $out
  '';
  vm = import ./vm.nix { inherit pkgs impurifier; };
}

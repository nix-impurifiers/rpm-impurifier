# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
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
  repository-zypper = import ./suse-vm.nix { inherit pkgs impurifier; };
  vm = import ./vm.nix {
    inherit pkgs impurifier;
    hardwareFixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  };
}
//
  pkgs.lib.genAttrs
    [ "repository-yum" "repository-dnf4" "repository-dnf5" "repository-microdnf" "repository-tdnf" ]
    (
      name:
      import ./repository-vm.nix {
        inherit pkgs impurifier;
        frontend = pkgs.lib.removePrefix "repository-" name;
      }
    )

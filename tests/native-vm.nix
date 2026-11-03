# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
let
  tool =
    name: version:
    pkgs.runCommand "${name}-${version}"
      {
        pname = name;
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${name}-${version}\n' > $out/bin/${name}
        chmod +x $out/bin/${name}
      '';
  command = "rpm --root /srv/target --dbpath /var/lib/rpm";
  sweep = ''
    while true; do
      removed=0
      for package in $(${command} -qa --qf '%{NAME}\n' | grep '^nix-store-' || true); do
        if ${command} -e "$package" 2>/dev/null; then removed=1; fi
      done
      test "$removed" = 1 || break
    done
  '';
in
import (coreSrc + "/tests/native-vm.nix") {
  inherit pkgs;
  name = "rpm";
  tools = [ pkgs.rpm ];
  first = impurifier.makeNativeRpms { pkg = tool "native-first" "1"; };
  second = impurifier.makeNativeRpms { pkg = tool "native-second" "1"; };
  upgraded = impurifier.makeNativeRpms { pkg = tool "native-first" "2"; };
  initialize = "${command} --initdb";
  install = "${command} -Uvh /tmp/packages/*.rpm";
  upgrade = "${command} -Uvh --replacepkgs /tmp/packages/*.rpm";
  removeFirst = "${command} -e native-first\n" + sweep;
  removeSecond = "${command} -e native-second\n" + sweep;
  verify = "${command} -Va";
}

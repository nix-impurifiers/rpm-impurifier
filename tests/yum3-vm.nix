# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  compatible = import ../nix {
    inherit pkgs;
    coreSrc = impurifier.coreSource;
    rpmCompatibility = "rpm4.14";
  };
  sdk = import ./yum3-sdk.nix { inherit pkgs; };
  runtime = compatible.makeRuntimeRpm { nixDependency = "nix"; };
  client = sdk.yum;
  tool =
    version:
    pkgs.runCommand "repo-tool-${version}"
      {
        pname = "repo-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/repo-tool
        chmod +x $out/bin/repo-tool
      '';
  app =
    offline: version:
    compatible.makeRpm {
      pkg = tool version;
      inherit offline;
      configFiles."/etc/repo-tool.conf" = pkgs.writeText "repo-tool.conf" "version=${version}\n";
    };
  provider = compatible.buildRpm {
    name = "fixture-native-runtime";
    version = "1";
    architecture = "noarch";
    payload = pkgs.runCommand "repo-native-runtime-payload" { } ''
      mkdir -p $out/usr/bin
      ln -s ${pkgs.nix}/bin/nix-store $out/usr/bin/nix-store
      ln -s ${pkgs.python3}/bin/python3 $out/usr/bin/python3
    '';
    extraSpec = "Provides: nix, python3, /bin/sh, systemd";
  };
in
pkgs.testers.runNixOSTest {
  name = "rpm-impurifier-yum3";
  globalTimeout = 180;
  requiredFeatures = {
    kvm = false;
    devnet = false;
  };
  nodes.machine = { lib, ... }: {
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    virtualisation.memorySize = 1024;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    documentation.enable = false;
    environment.systemPackages = [
      client
      sdk.rpm
      pkgs.nix
      pkgs.python3
      pkgs.gnupg
    ];
    environment.etc."yum.conf".text =
      "[main]\ncachedir=/var/cache/yum\nplugins=0\ngpgcheck=1\nlocalpkg_gpgcheck=1\nreposdir=/etc/yum.repos.d\n";
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/repo /srv/packages /usr/bin /usr/sbin /var/cache/poldek /root/.gnupg; chmod 700 /root/.gnupg; rpm --initdb")
    machine.succeed("cp ${provider} /srv/packages/provider.rpm; cp ${runtime} /srv/packages/runtime.rpm; cp ${app false "1"} /srv/packages/net1.rpm; cp ${app true "1"} /srv/packages/offline1.rpm; cp ${app true "2"} /srv/packages/offline2.rpm")
    machine.succeed("gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --quick-generate-key 'Impurifier VM <vm@invalid>' rsa2048 sign 0; gpg --armor --export vm@invalid > /srv/key.asc; rpm --import /srv/key.asc")
    machine.succeed("for package in /srv/packages/*.rpm; do ${pkgs.rpm}/bin/rpmsign --define '_gpg_name vm@invalid' --define '__gpg ${pkgs.gnupg}/bin/gpg' --addsign $package; done")
    machine.succeed("cp /srv/packages/provider.rpm /srv/packages/runtime.rpm /srv/packages/net1.rpm /srv/repo; systemctl stop dhcpcd; ip link set eth0 down")
    machine.succeed("mkdir -p /etc/yum.repos.d /var/cache/yum")
    bound = "systemd-run --pipe --wait --collect --setenv=HOME=/root --setenv=LC_ALL=C --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -p RuntimeMaxSec=45s -p TimeoutStopSec=2s ${pkgs.util-linux}/bin/setsid --wait "
    command = bound + "${client}/bin/yum3 -y --releasever=1 install "
    dependencies = "/srv/packages/provider.rpm /srv/packages/runtime.rpm "
    remove = bound + "${client}/bin/yum3 -y --releasever=1 remove "
    with subtest("unsigned packages fail the native RPM policy"):
        machine.succeed("cp /srv/packages/offline1.rpm /srv/repo/offline1.rpm; rpm --delsign /srv/repo/offline1.rpm")
        code, output = machine.execute(command + dependencies + "/srv/repo/offline1.rpm 2>&1")
        assert code != 0 and "timeout" not in output and any(word in output.lower() for word in ["signature", "digest", "invalid", "gpg", "signed"]), output
        machine.fail("rpm -q repo-tool-offline")
        machine.succeed("rm /srv/repo/offline1.rpm")
    with subtest("corrupted signed packages cannot install"):
        machine.succeed("cp /srv/packages/offline1.rpm /srv/repo/offline1.rpm; python3 -c \"from pathlib import Path; p=Path('/srv/repo/offline1.rpm'); b=bytearray(p.read_bytes()); b[-1]^=1; p.write_bytes(b)\"")
        code, output = machine.execute(command + dependencies + "/srv/repo/offline1.rpm 2>&1")
        assert code != 0 and "timeout" not in output and any(word in output.lower() for word in ["signature", "digest", "invalid", "gpg", "signed"]), output
        machine.fail("rpm -q repo-tool-offline")
        machine.succeed("rm /srv/repo/offline1.rpm")
    code, output = machine.execute(command + dependencies + "/srv/packages/net1.rpm 2>&1")
    assert "nix-profile-engine:" in output, output
    machine.succeed("rpm -q repo-tool-net")
    machine.fail("test -e /opt/nix/profile/bin/repo-tool")
    machine.succeed(remove + "repo-tool-net")
    machine.succeed("rm /srv/repo/net1.rpm; cp /srv/packages/offline1.rpm /srv/repo")
    machine.succeed(command + "/srv/packages/offline1.rpm")
    machine.succeed("test $(/opt/nix/profile/bin/repo-tool) = 1; rpm -V repo-tool-offline; echo administrator > /etc/repo-tool.conf")
    machine.succeed("rm /srv/repo/offline1.rpm; cp /srv/packages/offline2.rpm /srv/repo")
    machine.succeed(bound + "${client}/bin/yum3 -y --releasever=1 upgrade /srv/packages/offline2.rpm")
    machine.succeed("test $(/opt/nix/profile/bin/repo-tool) = 2; grep administrator /etc/repo-tool.conf")
    machine.succeed("su -s /bin/sh nobody -c /opt/nix/profile/bin/repo-tool | grep '^2$'; nix-store --gc; test $(/opt/nix/profile/bin/repo-tool) = 2")
    machine.succeed(remove + "repo-tool-offline")
    machine.succeed(remove + "rpm-impurifier")
    machine.fail("test -e /opt/nix/profile/bin/repo-tool")
    machine.succeed("nix-store --gc")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
  '';
}

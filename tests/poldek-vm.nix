# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  client = (import ./poldek-sdk.nix { inherit pkgs; }).poldek;
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
    impurifier.makeRpm {
      pkg = tool version;
      inherit offline;
      configFiles."/etc/repo-tool.conf" = pkgs.writeText "repo-tool.conf" "version=${version}\n";
    };
  provider = impurifier.buildRpm {
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
  name = "rpm-impurifier-poldek";
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
      pkgs.rpm
      pkgs.nix
      pkgs.python3
      pkgs.gnupg
    ];
    environment.etc."poldek.conf".text = ''
      [global]
      cachedir = /var/cache/poldek
      [source]
      name = impurifier
      type = dir
      path = /srv/repo
      signed = yes
    '';
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/repo /srv/packages /usr/bin /usr/sbin /var/cache/poldek /root/.gnupg; chmod 700 /root/.gnupg; rpm --initdb")
    machine.succeed("cp ${provider} /srv/packages/provider.rpm; cp ${impurifier.runtimeRpm} /srv/packages/runtime.rpm; cp ${app false "1"} /srv/packages/net1.rpm; cp ${app true "1"} /srv/packages/offline1.rpm; cp ${app true "2"} /srv/packages/offline2.rpm")
    machine.succeed("gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --quick-generate-key 'Impurifier VM <vm@invalid>' ed25519 sign 0; gpg --armor --export vm@invalid > /srv/key.asc; rpm --import /srv/key.asc")
    machine.succeed("for package in /srv/packages/*.rpm; do rpmsign --define '_gpg_name vm@invalid' --define '__gpg ${pkgs.gnupg}/bin/gpg' --addsign $package; done; printf '%%_pkgverify_level all\\n' > /root/.rpmmacros")
    machine.succeed("cp /srv/packages/provider.rpm /srv/packages/runtime.rpm /srv/packages/net1.rpm /srv/repo; systemctl stop dhcpcd; ip link set eth0 down")
    command = "poldek --conf=/etc/poldek.conf --noask --noprogress --pmcmd=${pkgs.rpm}/bin/rpm "
    with subtest("unsigned packages fail the native RPM policy"):
        machine.succeed("cp /srv/packages/offline1.rpm /srv/repo/offline1.rpm; rpm --delsign /srv/repo/offline1.rpm")
        code, output = machine.execute(command + "-i repo-tool-offline 2>&1")
        assert code != 0 and "signature" in output.lower(), output
        machine.fail("rpm -q repo-tool-offline")
        machine.succeed("rm /srv/repo/offline1.rpm")
    with subtest("corrupted signed packages cannot install"):
        machine.succeed("cp /srv/packages/offline1.rpm /srv/repo/offline1.rpm; python3 -c \"from pathlib import Path; p=Path('/srv/repo/offline1.rpm'); b=bytearray(p.read_bytes()); b[-1]^=1; p.write_bytes(b)\"")
        code, output = machine.execute(command + "-i repo-tool-offline 2>&1")
        assert code != 0 and "signature" in output.lower(), output
        machine.fail("rpm -q repo-tool-offline")
        machine.succeed("rm /srv/repo/offline1.rpm")
    code, output = machine.execute(command + "-i repo-tool-net 2>&1")
    assert "nix-profile-engine:" in output, output
    machine.succeed("rpm -q repo-tool-net")
    machine.fail("test -e /opt/nix/profile/bin/repo-tool")
    machine.succeed(command + "-e repo-tool-net")
    machine.succeed("rm /srv/repo/net1.rpm; cp /srv/packages/offline1.rpm /srv/repo")
    machine.succeed(command + "-i repo-tool-offline")
    machine.succeed("test $(/opt/nix/profile/bin/repo-tool) = 1; rpm -V repo-tool-offline; echo administrator > /etc/repo-tool.conf")
    machine.succeed("rm /srv/repo/offline1.rpm; cp /srv/packages/offline2.rpm /srv/repo")
    machine.succeed(command + "-u repo-tool-offline")
    machine.succeed("test $(/opt/nix/profile/bin/repo-tool) = 2; grep administrator /etc/repo-tool.conf")
    machine.succeed("su -s /bin/sh nobody -c /opt/nix/profile/bin/repo-tool | grep '^2$'; nix-store --gc; test $(/opt/nix/profile/bin/repo-tool) = 2")
    machine.succeed(command + "-e repo-tool-offline")
    machine.succeed(command + "-e rpm-impurifier")
    machine.fail("test -e /opt/nix/profile/bin/repo-tool")
    machine.succeed("nix-store --gc")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
  '';
}

# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  hardwareFixture,
}:
let
  tool =
    version:
    pkgs.runCommand "rpm-tool-${version}"
      {
        pname = "rpm-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/rpm-tool
        chmod +x $out/bin/rpm-tool
      '';
  app =
    offline: version:
    impurifier.makeRpm {
      pkg = tool version;
      inherit offline;
      configFiles."/etc/rpm-tool.conf" = pkgs.writeText "rpm-tool.conf" "version=${version}\n";
    };
  daemon =
    version:
    pkgs.runCommand "rpm-service-${version}"
      {
        pname = "rpm-service";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        cat > $out/bin/rpm-service <<'SCRIPT'
        #!${pkgs.busybox}/bin/sh
        echo ${version} > /var/lib/rpm-service/version
        exec ${pkgs.busybox}/bin/sleep infinity
        SCRIPT
        chmod +x $out/bin/rpm-service
      '';
  service =
    version:
    impurifier.makeOfflineRpm {
      pkg = daemon version;
      users.rpm-service = { };
      directories."/var/lib/rpm-service" = {
        owner = "rpm-service:rpm-service";
        mode = "0750";
      };
      lifecycle = {
        onInstall = ''
          /usr/bin/python3 -c "import pwd; pwd.getpwnam('rpm-service')"
          test -x /opt/nix/profile/bin/rpm-service
          echo initialized > /var/lib/rpm-service/initialized
        '';
        onUpgrade = ''
          echo ${version} > /var/lib/rpm-service/migrated
        '';
      };
      systemd.unit = pkgs.writeText "rpm-service.service" ''
        [Service]
        Type=exec
        User=rpm-service
        ExecStart=/opt/nix/profile/bin/rpm-service
        [Install]
        WantedBy=multi-user.target
      '';
    };
  hostDriver =
    version:
    impurifier.buildRpm {
      name = "impurifier-host-driver";
      architecture = "x86_64";
      inherit version;
      payload = hardwareFixture.driver version;
    };
  hardwareApp = impurifier.makeOfflineRpm {
    pkg = hardwareFixture.tool;
    inherit (hardwareFixture) hardware;
  };
  provider = impurifier.buildRpm {
    name = "vm-runtime";
    version = "1";
    release = "1";
    architecture = "noarch";
    description = "Actual runtime supplied by the VM";
    payload =
      pkgs.runCommand "vm-runtime-payload" { }
        "mkdir -p $out/usr/share/impurifier-vm; echo preinstalled > $out/usr/share/impurifier-vm/runtime";
    extraSpec = ''
      Provides: nix, python3, /bin/sh, systemd
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "rpm-impurifier";
  requiredFeatures = {
    kvm = false;
    devnet = false;
  };
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    environment.systemPackages = [
      pkgs.rpm
      pkgs.nix
      pkgs.python3
    ];
    systemd.tmpfiles.rules = [
      "d /usr/bin 0755 root root -"
      "d /usr/sbin 0755 root root -"
      "L+ /usr/bin/python3 - - - - ${pkgs.python3}/bin/python3"
      "L+ /usr/bin/systemctl - - - - ${pkgs.systemd}/bin/systemctl"
      "L+ /usr/bin/systemd-sysusers - - - - ${pkgs.systemd}/bin/systemd-sysusers"
      "L+ /usr/bin/systemd-tmpfiles - - - - ${pkgs.systemd}/bin/systemd-tmpfiles"
      "L+ /usr/bin/nix-store - - - - ${pkgs.nix}/bin/nix-store"
    ];
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("cp -rL /etc/systemd/system /tmp/systemd-system; chmod -R u+w /tmp/systemd-system; rm /etc/systemd/system; mv /tmp/systemd-system /etc/systemd/system; systemctl daemon-reload")
    machine.succeed("rpm --initdb; mkdir -p /tmp/packages")
    machine.succeed("cp ${app true "1"} /tmp/packages/offline1.rpm; cp ${app false "1"} /tmp/packages/net1.rpm; cp ${app true "2"} /tmp/packages/offline2.rpm; cp ${service "1"} /tmp/packages/service1.rpm; cp ${service "2"} /tmp/packages/service2.rpm")
    machine.succeed("cp ${hostDriver "1"} /tmp/packages/driver1.rpm; cp ${hostDriver "2"} /tmp/packages/driver2.rpm; cp ${hardwareApp} /tmp/packages/hardware.rpm")
    machine.succeed("systemctl stop dhcpcd; ip link set eth0 down")
    machine.succeed("rpm -Uvh ${provider} ${impurifier.runtimeRpm}")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    with subtest("failed net transaction preserves the old profile and reports trigger failure"):
        before = machine.succeed("readlink /opt/nix/profile").strip()
        output = machine.execute("rpm -Uvh /tmp/packages/net1.rpm 2>&1")[1]
        # RPM may report a trigger failure as a warning after committing its DB.
        assert "nix-profile-engine:" in output, output
        assert machine.succeed("readlink /opt/nix/profile").strip() == before
    with subtest("offline provider replacement recovers without networking"):
        machine.succeed("rpm -Uvh /tmp/packages/offline1.rpm")
        machine.succeed("test $(/opt/nix/profile/bin/rpm-tool) = 1; rpm -q rpm-tool-offline")
        machine.fail("rpm -q rpm-tool-net")
    with subtest("configuration edits survive provider switch and upgrade"):
        machine.succeed("echo local > /etc/rpm-tool.conf")
        machine.succeed("rpm -Uvh /tmp/packages/net1.rpm")
        machine.succeed("grep local /etc/rpm-tool.conf")
        machine.succeed("rpm -Uvh /tmp/packages/offline2.rpm")
        machine.succeed("test $(/opt/nix/profile/bin/rpm-tool) = 2; grep local /etc/rpm-tool.conf")
    with subtest("one activation for multiple descriptors in a native transaction"):
        output = machine.succeed("rpm -Uvh ${
          impurifier.makeOfflineRpm {
            pkg = pkgs.hello;
            name = "batch-a";
            version = "1";
          }
        } ${
          impurifier.makeOfflineRpm {
            pkg = pkgs.hello;
            name = "batch-b";
            version = "1";
          }
        }")
        assert output.count("activated ") == 1, output
        machine.succeed("/opt/nix/profile/bin/hello | grep Hello")
        machine.succeed("rpm -e batch-a-offline batch-b-offline")
    with subtest("RPM triggers provision service accounts, directories, and upgrade running units"):
        machine.succeed("rpm -Uvh /tmp/packages/service1.rpm")
        machine.wait_for_unit("rpm-service.service")
        machine.wait_until_succeeds("grep '^1$' /var/lib/rpm-service/version")
        machine.succeed("id rpm-service; test $(stat -c %U /var/lib/rpm-service) = rpm-service")
        machine.succeed("rpm -Uvh /tmp/packages/service2.rpm")
        machine.wait_until_succeeds("grep '^2$' /var/lib/rpm-service/version")
        machine.succeed("grep initialized /var/lib/rpm-service/initialized; grep '^2$' /var/lib/rpm-service/migrated")
        machine.succeed("systemctl disable --now rpm-service.service; rpm -Uvh --oldpackage /tmp/packages/service1.rpm")
        machine.fail("systemctl is-active --quiet rpm-service.service")
        machine.fail("systemctl is-enabled --quiet rpm-service.service")
        machine.succeed("systemctl enable --now rpm-service.service; rpm -e rpm-service-offline")
        machine.fail("systemctl is-active --quiet rpm-service.service")
        machine.fail("test -L /etc/systemd/system/multi-user.target.wants/rpm-service.service")
    with subtest("native library upgrades refresh the hardware snapshot"):
        machine.succeed("rpm -Uvh /tmp/packages/driver1.rpm /tmp/packages/hardware.rpm")
        machine.succeed("/opt/nix/profile/bin/hardware-tool | grep '^1$'")
        before = machine.succeed("readlink /opt/nix/profile").strip()
        machine.succeed("rpm -Uvh /tmp/packages/driver2.rpm")
        assert machine.succeed("readlink /opt/nix/profile").strip() != before
        machine.succeed("/opt/nix/profile/bin/hardware-tool | grep '^2$'")
        machine.succeed("rpm -e hardware-tool-offline impurifier-host-driver")
    with subtest("GC and removal honor rooted profile generations"):
        machine.succeed("nix-store --gc; test $(/opt/nix/profile/bin/rpm-tool) = 2")
        machine.succeed("rpm -e rpm-tool-offline")
        machine.fail("test -e /opt/nix/profile/bin/rpm-tool")
        machine.succeed("grep local /etc/rpm-tool.conf.rpmsave")
        machine.succeed("/usr/sbin/nix-profile-engine prune --keep 0; nix-store --gc; test -d /opt/nix/profile")
  '';
}

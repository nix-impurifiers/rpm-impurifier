# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  rootfs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/alt-cloud/docker-brew-alt/e58ed9ba13273b5e6ece45599b992df85dec1ed3/x86_64/alt-sisyphus-x86_64.tar.xz";
    hash = "sha256-caQsqBngs09CD6jAk6x54wXdDvQFN1zdbsJhyY8Qvqg=";
  };
  altImpurifier = import ../nix {
    inherit pkgs;
    coreSrc = impurifier.coreSource;
    rpmCompatibility = "alt";
  };
  runtime = altImpurifier.makeRuntimeRpm { nixDependency = "nix"; };
  tool =
    version:
    pkgs.runCommand "alt-tool-${version}"
      {
        pname = "alt-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/alt-tool
        chmod +x $out/bin/alt-tool
      '';
  app =
    version:
    altImpurifier.makeOfflineRpm {
      pkg = tool version;
      hostDependencies = [ ];
      configFiles."/etc/alt-tool.conf" = pkgs.writeText "alt-tool.conf" "version=${version}\n";
    };
  net = altImpurifier.makeNetRpm {
    pkg = tool "1";
    hostDependencies = [ ];
    configFiles."/etc/alt-tool.conf" = pkgs.writeText "alt-tool.conf" "version=1\n";
  };
  provider = altImpurifier.buildRpm {
    name = "fixture-native-runtime";
    version = "1";
    architecture = "noarch";
    payload = pkgs.runCommand "alt-native-runtime-payload" { } ''
      mkdir -p $out/usr/bin
      ln -s ${pkgs.nix}/bin/nix-store $out/usr/bin/nix-store
      ln -s ${pkgs.python3}/bin/python3 $out/usr/bin/python3
    '';
    extraSpec = "Provides: nix, python3";
  };

in
pkgs.testers.runNixOSTest {
  name = "rpm-impurifier-alt-apt";
  globalTimeout = 180;
  requiredFeatures = {
    kvm = false;
    devnet = false;
  };
  nodes.machine = { lib, ... }: {
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    virtualisation.memorySize = 1024;
    virtualisation.diskSize = 4096;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    documentation.enable = false;
    environment.systemPackages = [
      pkgs.nix
      pkgs.python3
      pkgs.gnutar
      pkgs.xz
      pkgs.rpm
      pkgs.gnupg
    ];
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /alt; tar -xJpf ${rootfs} -C /alt")
    machine.succeed("mount --bind /dev /alt/dev; mount --bind /proc /alt/proc; mkdir -p /alt/nix; mount --rbind /nix /alt/nix")
    machine.succeed("mkdir -p /alt/etc/nix /alt/packages /alt/opt/nix /alt/var/lib/rpm-impurifier /opt/nix /var/lib/rpm-impurifier; mount --bind /opt/nix /alt/opt/nix; mount --bind /var/lib/rpm-impurifier /alt/var/lib/rpm-impurifier")
    machine.succeed("printf 'substituters =\\nbuilders =\\nbuild-users-group =\\n' > /alt/etc/nix/nix.conf; rm -f /alt/etc/apt/sources.list.d/*.list; : > /alt/etc/apt/sources.list")
    machine.succeed("cp ${provider} /alt/packages/provider.rpm; cp ${runtime} /alt/packages/runtime.rpm; cp ${net} /alt/packages/net1.rpm; cp ${app "1"} /alt/packages/offline1.rpm; cp ${app "2"} /alt/packages/offline2.rpm")
    machine.succeed("mkdir -m700 /root/.gnupg; gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --quick-generate-key 'ALT VM <alt@invalid>' rsa2048 sign 0; gpg --armor --export alt@invalid > /alt/packages/key.asc")
    machine.succeed("install -m755 ${altImpurifier.altVerificationHook} /alt/usr/sbin/impurifier-verify-rpms")
    machine.succeed("printf 'RPM::Pre-Install-Pkgs { \"/usr/sbin/impurifier-verify-rpms\"; };\\n' > /alt/etc/apt/apt.conf.d/impurifier-verify.conf")
    machine.succeed("gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --armor --export-secret-keys alt@invalid > /alt/packages/signing-key.asc; chroot /alt /usr/bin/gpg --batch --import /packages/signing-key.asc; chroot /alt /bin/rpm --import /packages/key.asc")
    machine.succeed("for package in /alt/packages/*.rpm; do chroot /alt /usr/bin/rpmsign --define '_gpg_name alt@invalid' --addsign /packages/$(basename $package); done")
    machine.succeed("systemctl stop dhcpcd; ip link set eth0 down")
    command = "setsid --wait timeout --foreground -k 2s 60s chroot /alt /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C /usr/bin/apt-get -y "
    print(machine.succeed("chroot /alt /usr/bin/apt-get --version; chroot /alt /bin/rpm --version"))
    print(machine.execute("chroot /alt /bin/rpm -Kv /packages/offline1.rpm")[1])
    with subtest("native ALT RPM rejects corrupted signed data"):
        machine.succeed("chroot /alt /bin/rpm --checksig /packages/offline1.rpm; cp /alt/packages/offline1.rpm /alt/packages/damaged.rpm; python3 -c \"from pathlib import Path; p=Path('/alt/packages/damaged.rpm'); b=bytearray(p.read_bytes()); b[-1]^=1; p.write_bytes(b)\"")
        machine.fail("chroot /alt /bin/rpm --checksig /packages/damaged.rpm")
        code, output = machine.execute(command + "install /packages/provider.rpm /packages/runtime.rpm /packages/damaged.rpm 2>&1")
        assert code != 0 and any(word in output.lower() for word in ["digest", "signature", "corrupt", "payload"]), output
        machine.fail("chroot /alt /bin/rpm -q alt-tool-offline")
    with subtest("unsigned packages fail before activation"):
        machine.succeed("cp ${app "1"} /alt/packages/unsigned.rpm")
        code, output = machine.execute(command + "install /packages/provider.rpm /packages/runtime.rpm /packages/unsigned.rpm 2>&1")
        assert code != 0 and "signature required" in output.lower(), output
        machine.fail("test -e /opt/nix/profile/bin/alt-tool")
    code, output = machine.execute(command + "install /packages/provider.rpm /packages/runtime.rpm /packages/net1.rpm 2>&1")
    assert any(line.startswith("nix-profile-engine:") for line in output.splitlines()), output
    machine.succeed("chroot /alt /bin/rpm -q alt-tool-net")
    machine.fail("test -e /opt/nix/profile/bin/alt-tool")
    machine.succeed(command + "remove alt-tool-net")
    machine.succeed(command + "install /packages/offline1.rpm")
    machine.succeed("test $(/opt/nix/profile/bin/alt-tool) = 1; chroot /alt /bin/rpm -V alt-tool-offline; echo administrator > /alt/etc/alt-tool.conf")
    machine.succeed(command + "install /packages/offline2.rpm")
    machine.succeed("test $(/opt/nix/profile/bin/alt-tool) = 2; grep administrator /alt/etc/alt-tool.conf")
    machine.succeed("chroot --userspec=65534:65534 /alt /opt/nix/profile/bin/alt-tool | grep '^2$'; nix-store --gc; test $(/opt/nix/profile/bin/alt-tool) = 2")
    machine.succeed(command + "remove alt-tool-offline rpm-impurifier")
    machine.fail("test -e /opt/nix/profile/bin/alt-tool")
    machine.succeed("nix-store --gc")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
  '';
}

# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  rootfs = pkgs.fetchurl {
    # Single official OCI rootfs layer, from tumbleweed:20261031.37.278.
    url = "https://registry.opensuse.org/v2/opensuse/tumbleweed/blobs/sha256:802bdc6e774ef3f4252190476dabebfb4058f0956bf37b9b018dba0ccc78936e";
    hash = "sha256-gCvcbndO8/QlIZBHbavr+0BY8JVr83ubAY26DMx4k24=";
    name = "opensuse-tumbleweed-20261031-rootfs.tar.gz";
  };
  tool =
    version:
    pkgs.runCommand "suse-tool-${version}"
      {
        pname = "suse-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/suse-tool
        chmod +x $out/bin/suse-tool
      '';
  app =
    version:
    impurifier.makeOfflineRpm {
      pkg = tool version;
      hostDependencies = [ ];
      configFiles."/etc/suse-tool.conf" = pkgs.writeText "suse-tool.conf" "version=${version}\n";
    };
  net = impurifier.makeNetRpm {
    pkg = tool "1";
    hostDependencies = [ ];
    configFiles."/etc/suse-tool.conf" = pkgs.writeText "suse-tool.conf" "version=1\n";
  };
  provider = impurifier.buildRpm {
    name = "fixture-native-runtime";
    version = "1";
    architecture = "noarch";
    payload = pkgs.runCommand "suse-native-runtime-payload" { } ''
      mkdir -p $out/usr/bin
      ln -s ${pkgs.nix}/bin/nix-store $out/usr/bin/nix-store
      ln -s ${pkgs.python3}/bin/python3 $out/usr/bin/python3
    '';
    extraSpec = "Provides: nix, python3";
  };
  repo = pkgs.writeText "impurifier.repo" ''
    [impurifier]
    name=Native impurifier fixture
    baseurl=file:///packages/repo
    enabled=1
    autorefresh=0
    gpgcheck=1
    repo_gpgcheck=1
    pkg_gpgcheck=1
    gpgkey=file:///packages/key.asc
  '';
in
pkgs.testers.runNixOSTest {
  name = "rpm-impurifier-native-zypper";
  globalTimeout = 600;
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
    environment.systemPackages = with pkgs; [
      nix
      python3
      gnutar
      createrepo_c
      gnupg
      rpm
    ];
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/suse; tar xzf ${rootfs} -C /srv/suse")
    machine.succeed("mkdir -p /srv/suse/etc/nix; printf 'substituters =\\nbuilders =\\n' > /srv/suse/etc/nix/nix.conf")
    machine.succeed("mkdir -p /srv/suse/nix /srv/suse/proc /srv/suse/packages/repo /srv/suse/opt/nix /srv/suse/var/lib/rpm-impurifier /opt/nix /var/lib/rpm-impurifier")
    machine.succeed("mount --rbind /nix /srv/suse/nix; mount -t proc proc /srv/suse/proc; mount --rbind /dev /srv/suse/dev; mount --bind /opt/nix /srv/suse/opt/nix; mount --bind /var/lib/rpm-impurifier /srv/suse/var/lib/rpm-impurifier")
    machine.succeed("rm -f /srv/suse/etc/zypp/repos.d/*.repo; cp ${repo} /srv/suse/etc/zypp/repos.d/impurifier.repo")
    machine.succeed("cp ${provider} /srv/suse/packages/repo/provider.rpm; cp ${impurifier.runtimeRpm} /srv/suse/packages/repo/runtime.rpm; cp ${net} /srv/suse/packages/repo/net1.rpm; cp ${app "1"} /srv/suse/packages/offline1.rpm; cp ${app "2"} /srv/suse/packages/offline2.rpm")
    machine.succeed("mkdir -m700 /root/.gnupg; gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --quick-generate-key 'Zypper VM <suse@invalid>' rsa2048 sign 0; gpg --armor --export suse@invalid > /srv/suse/packages/key.asc")
    machine.succeed("for package in /srv/suse/packages/repo/*.rpm /srv/suse/packages/offline1.rpm /srv/suse/packages/offline2.rpm; do rpmsign --define '_gpg_name suse@invalid' --define '__gpg ${pkgs.gnupg}/bin/gpg' --addsign $package; done; chroot /srv/suse /usr/bin/rpm --import /packages/key.asc")
    machine.succeed("createrepo_c /srv/suse/packages/repo; gpg --batch --yes --armor --detach-sign /srv/suse/packages/repo/repodata/repomd.xml")
    command = "chroot /srv/suse /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin zypper --non-interactive "
    machine.succeed(command + "--gpg-auto-import-keys refresh")
    print(machine.succeed("chroot /srv/suse /usr/bin/zypper --version; chroot /srv/suse /usr/bin/rpm -q rpm libzypp"))
    machine.succeed("printf '\\n<!--tampered-->\\n' >> /srv/suse/packages/repo/repodata/repomd.xml")
    machine.fail(command + "refresh --force")
    machine.succeed("gpg --batch --yes --armor --detach-sign /srv/suse/packages/repo/repodata/repomd.xml")
    machine.succeed(command + "refresh --force")
    machine.succeed("nix-collect-garbage -d")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    machine.succeed("rpm --delsign /srv/suse/packages/repo/net1.rpm; rm -rf /srv/suse/packages/repo/repodata; createrepo_c /srv/suse/packages/repo; gpg --batch --yes --armor --detach-sign /srv/suse/packages/repo/repodata/repomd.xml")
    machine.succeed(command + "refresh --force")
    machine.fail(command + "install suse-tool-net")
    machine.fail("chroot /srv/suse /usr/bin/rpm -q suse-tool-net")
    machine.succeed("rpmsign --define '_gpg_name suse@invalid' --define '__gpg ${pkgs.gnupg}/bin/gpg' --addsign /srv/suse/packages/repo/net1.rpm; rm -rf /srv/suse/packages/repo/repodata; createrepo_c /srv/suse/packages/repo; gpg --batch --yes --armor --detach-sign /srv/suse/packages/repo/repodata/repomd.xml")
    machine.succeed(command + "refresh --force")
    _status, output = machine.execute(command + "install suse-tool-net 2>&1")
    assert "nix-profile-engine:" in output, output
    machine.succeed("chroot /srv/suse /usr/bin/rpm -q suse-tool-net")
    machine.fail("test -x /opt/nix/profile/bin/suse-tool")
    machine.succeed("cp /srv/suse/packages/offline1.rpm /srv/suse/packages/repo/; createrepo_c --update /srv/suse/packages/repo; gpg --batch --yes --armor --detach-sign /srv/suse/packages/repo/repodata/repomd.xml")
    machine.succeed(command + "refresh --force")
    machine.succeed(command + "install suse-tool-offline")
    machine.succeed("chroot --userspec=65534:65534 /srv/suse /opt/nix/profile/bin/suse-tool | grep '^1$'; chroot /srv/suse /usr/bin/rpm -V suse-tool-offline; sha256sum /srv/suse/usr/share/nix-profile.d/suse-tool.json > /srv/payload.sha; nix-collect-garbage -d; sha256sum -c /srv/payload.sha")
    machine.succeed("echo administrator > /srv/suse/etc/suse-tool.conf; rm /srv/suse/packages/repo/offline1.rpm; cp /srv/suse/packages/offline2.rpm /srv/suse/packages/repo/; createrepo_c --update /srv/suse/packages/repo; gpg --batch --yes --armor --detach-sign /srv/suse/packages/repo/repodata/repomd.xml")
    machine.succeed(command + "refresh --force")
    machine.succeed(command + "update suse-tool-offline")
    machine.succeed("chroot /srv/suse /opt/nix/profile/bin/suse-tool | grep '^2$'; grep administrator /srv/suse/etc/suse-tool.conf")
    machine.succeed("chroot /srv/suse /usr/sbin/nix-profile-engine prune --keep 0; nix-collect-garbage -d; test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    machine.succeed(command + "remove suse-tool-offline rpm-impurifier")
    machine.fail("test -x /opt/nix/profile/bin/suse-tool")
    machine.succeed("nix-collect-garbage -d")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
  '';
}

# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  frontend ? "dnf5",
}:
let
  clients = {
    dnf4 = pkgs.dnf4;
    dnf5 = pkgs.dnf5;
    microdnf = pkgs.microdnf.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--export-dynamic" ];
    });
    tdnf = pkgs.tdnf;
  };
  client = clients.${frontend};
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
  repoConfig = pkgs.writeText "impurifier.repo" ''
    [impurifier]
    name=Native impurifier fixture
    baseurl=file:///srv/repo
    enabled=1
    gpgcheck=1
    repo_gpgcheck=0
    gpgkey=file:///srv/repo-key.asc
  '';
in
pkgs.testers.runNixOSTest {
  name = "rpm-impurifier-repository-${frontend}";
  globalTimeout = 600;
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
    environment.systemPackages = with pkgs; [
      client
      rpm
      nix
      python3
      createrepo_c
      gnupg
    ];
    systemd.tmpfiles.rules = [
      "d /usr/bin 0755 root root -"
      "d /usr/sbin 0755 root root -"
    ];
    environment.etc."tdnf/tdnf.conf".source = "${pkgs.tdnf.src}/etc/tdnf/tdnf.conf";
    environment.etc."dnf/plugins/versionlock.conf".text =
      "[main]\nenabled=1\nlocklist=/etc/dnf/plugins/versionlock.list\n";
    environment.etc."dnf/plugins/versionlock.list".text = "";
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/repo /srv/packages /etc/yum.repos.d /etc/dnf /etc/tdnf; cp ${repoConfig} /etc/yum.repos.d/impurifier.repo; rpm --initdb")
    machine.succeed("cp ${provider} /srv/packages/provider.rpm; cp ${impurifier.runtimeRpm} /srv/packages/runtime.rpm; cp ${app false "1"} /srv/packages/net1.rpm; cp ${app true "1"} /srv/packages/offline1.rpm; cp ${app true "2"} /srv/packages/offline2.rpm")
    machine.succeed("mkdir -m700 /root/.gnupg; gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --quick-generate-key 'Impurifier VM <vm@invalid>' rsa2048 sign 0; gpg --armor --export vm@invalid > /srv/repo-key.asc")
    machine.succeed("for package in /srv/packages/*.rpm; do rpmsign --define '_gpg_name vm@invalid' --define '__gpg ${pkgs.gnupg}/bin/gpg' --addsign $package; done")
    machine.succeed("rpm --import /srv/repo-key.asc; cp /srv/packages/provider.rpm /srv/packages/runtime.rpm /srv/packages/offline1.rpm /srv/repo/; createrepo_c /srv/repo")
    command = "${client}/bin/${frontend} -y --releasever=1 ${
      pkgs.lib.optionalString (frontend == "dnf4") "--setopt=pluginconfpath=/etc/dnf/plugins "
    }"
    machine.succeed("python3 -c \"from pathlib import Path; p=Path('/srv/repo/offline1.rpm'); b=bytearray(p.read_bytes()); b[-1]^=1; p.write_bytes(b)\"; createrepo_c --update /srv/repo")
    machine.fail("rpm --checksig /srv/repo/offline1.rpm")
    machine.fail(command + "install repo-tool-offline")
    machine.fail("rpm -q repo-tool-offline")
    machine.succeed("cp /srv/packages/offline1.rpm /srv/repo/offline1.rpm; rpm --delsign /srv/repo/offline1.rpm; rm -rf /srv/repo/repodata; createrepo_c /srv/repo")
    machine.succeed(command + "clean all")
    if "${frontend}" == "tdnf":
        machine.succeed("printf '%%_pkgverify_level all\\n' > /root/.rpmmacros; test $(rpm --eval '%{_pkgverify_level}') = all")
    status, output = machine.execute(command + "install repo-tool-offline 2>&1")
    assert status != 0 and any(word in output.lower() for word in ("gpg", "signature", "unsigned")), output
    machine.fail("rpm -q repo-tool-offline")
    machine.succeed("rm /srv/repo/offline1.rpm; cp /srv/packages/net1.rpm /srv/repo/; createrepo_c --update /srv/repo")
    machine.succeed(command + "clean all")
    _status, output = machine.execute(command + "install repo-tool-net 2>&1")
    assert "nix-profile-engine:" in output, output
    machine.succeed("rpm -q repo-tool-net")
    machine.fail("test -x /opt/nix/profile/bin/repo-tool")
    machine.succeed("cp /srv/packages/offline1.rpm /srv/repo/; createrepo_c --update /srv/repo")
    machine.succeed(command + "clean all")
    if "${frontend}" == "tdnf":
        machine.succeed(command + "remove repo-tool-net")
        machine.succeed(command + "install repo-tool-offline")
    elif "${frontend}" == "dnf4":
        machine.succeed(command + "--setopt=obsoletes=0 swap repo-tool-net repo-tool-offline")
    else:
        machine.succeed(command + "swap repo-tool-net repo-tool-offline")
    machine.succeed("/opt/nix/profile/bin/repo-tool | grep '^1$'; rpm -V repo-tool-offline")
    machine.succeed("echo administrator > /etc/repo-tool.conf; rm /srv/repo/offline1.rpm; cp /srv/packages/offline2.rpm /srv/repo/; createrepo_c --update /srv/repo")
    machine.succeed(command + "clean all")
    machine.succeed(command + "upgrade repo-tool-offline")
    machine.succeed("/opt/nix/profile/bin/repo-tool | grep '^2$'; grep administrator /etc/repo-tool.conf")
    machine.succeed("/usr/sbin/nix-profile-engine prune --keep 0; nix-collect-garbage -d")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    machine.succeed(command + "remove repo-tool-offline")
    machine.fail("test -x /opt/nix/profile/bin/repo-tool")
    if machine.execute("rpm -q rpm-impurifier")[0] == 0:
        machine.succeed(command + "remove rpm-impurifier")
    machine.succeed("nix-collect-garbage -d")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
    machine.fail("test -x /opt/nix/profile/bin/repo-tool")
  '';
}

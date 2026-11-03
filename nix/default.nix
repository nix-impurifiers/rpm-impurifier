# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
  rpmCompatibility ? "modern",
}:
let
  inherit (pkgs) lib;
  compatibilityTool =
    pkgs.runCommandCC "rpm-alt-header"
      {
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.rpm ];
      }
      ''
        mkdir -p $out/bin
        $CC -Wall -Wextra -Werror ${./alt-header.c} $(pkg-config --cflags --libs rpm) -o $out/bin/rpm-alt-header
      '';
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "rpm-impurifier";
    sourceInfo = {
      # Native updates must include adapter-only releases, not just engine pins.
      lastModified = pkgs.lib.max (if builtins.isAttrs coreSrc then coreSrc.lastModified or 0 else 0) (
        if builtins.isAttrs sourceInfo then sourceInfo.lastModified or 0 else 0
      );
    };
  };
  architecture =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "x86_64"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "aarch64"
    else
      throw "rpm-impurifier: unsupported target architecture";
  buildRpm =
    {
      name,
      version,
      release ? "1",
      architecture ? "noarch",
      payload,
      description ? "Nix-projected package",
      license ? "LicenseRef-Unknown",
      configPaths ? [ ],
      extraSpec ? "",
      scriptlets ? "",
    }:
    assert lib.assertMsg (builtins.match "[a-z0-9][a-z0-9+.-]+" name != null) "invalid RPM name";
    assert lib.assertMsg (
      builtins.match "[0-9][A-Za-z0-9.+~^_]*" version != null
    ) "invalid RPM version; override version to remove native-incompatible characters";
    assert lib.assertMsg (builtins.match "[A-Za-z0-9._+]+" release != null) "invalid RPM release";
    assert lib.assertMsg (builtins.elem rpmCompatibility [
      "modern"
      "alt"
      "rpm4.14"
    ]) "invalid RPM compatibility target";
    pkgs.runCommand "${name}-${version}-${release}.${architecture}.rpm"
      {
        nativeBuildInputs = [ pkgs.rpm ];
        __structuredAttrs = true;
        # Native archives are self-contained. RPM headers expose cache filenames
        # containing store hashes; those are payload data, not Nix dependencies.
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} root
        cp -r ${payload}/. root/
        chmod -R u+w root
        find root \( -type f -o -type l \) -printf '/%P\n' | sort > filelist
        ${lib.concatMapStringsSep "\n" (path: ''
          sed -Ei 's|^${lib.escapeRegex path}$|%config(noreplace) ${path}|' filelist
        '') configPaths}
        cat > package.spec <<'SPEC'
        Name: ${name}
        Version: ${version}
        Release: ${release}
        Summary: ${description}
        License: ${license}
        BuildArch: ${architecture}
        AutoReqProv: no
        ${extraSpec}
        %description
        ${description}
        %install
        mkdir -p %{buildroot}
        cp -r ${payload}/. %{buildroot}/
        chmod -R u+w %{buildroot}
        %files -f %{_impurifier_filelist}
        ${scriptlets}
        SPEC
        export SOURCE_DATE_EPOCH=1
        mkdir -p "$TMPDIR/rpmdb"
        rpmbuild -bb --nodeps package.spec --buildroot "$PWD/root" \
          --define "_topdir $PWD/rpmbuild" \
          --define "_tmppath $TMPDIR" \
          --define "_dbpath $TMPDIR/rpmdb" \
          --define "_impurifier_filelist $PWD/filelist" \
          ${lib.optionalString (rpmCompatibility != "modern") "--define '_binary_payload w9.gzdio'"} \
          --define '_buildhost localhost' \
          --define '_buildshell ${pkgs.runtimeShell}' \
          --define '__os_install_post %{nil}' \
          --define '_build_id_links none' \
          --define 'use_source_date_epoch_as_buildtime 1' \
          --define 'clamp_mtime_to_source_date_epoch 1'
        ${
          if rpmCompatibility == "alt" then
            ''
              ${compatibilityTool}/bin/rpm-alt-header rpmbuild/RPMS/${architecture}/*.rpm "$out"
            ''
          else
            ''
              cp rpmbuild/RPMS/${architecture}/*.rpm "$out"
            ''
        }
      '';
  makeRpm =
    args@{
      pkg,
      release ? "1",
      hostDependencies ? [ "systemd" ],
      license ? null,
      ...
    }:
    let
      payload = core.makePayload (
        builtins.removeAttrs args [
          "release"
          "hostDependencies"
          "license"
        ]
      );
      licenses = lib.toList (pkg.meta.license or [ ]);
      packageLicense =
        if license != null then
          license
        else if licenses == [ ] then
          "LicenseRef-Unknown"
        else
          lib.concatMapStringsSep " AND " (
            item: item.spdxId or item.shortName or "LicenseRef-Unknown"
          ) licenses;
    in
    buildRpm {
      name = payload.packageName;
      inherit (payload) version description configPaths;
      inherit release payload architecture;
      license = packageLicense;
      extraSpec = ''
        Requires: rpm-impurifier >= ${core.runtimeVersion}
        ${lib.optionalString (
          (payload.hostEnabled || (args.hostDependencies or null) != null) && hostDependencies != [ ]
        ) "Requires: ${lib.concatStringsSep ", " hostDependencies}"}
        Provides: ${payload.name} = ${payload.version}-${release}
        Conflicts: ${payload.name}-${if payload.offline then "net" else "offline"}
        Obsoletes: ${payload.name}-${if payload.offline then "net" else "offline"}
      '';
    };
  makeRuntimeRpm =
    {
      nixDependency ? "(nix or nix-external-runtime)",
    }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9 .,+|():<>=~_-]+" nixDependency != null
    ) "invalid native Nix dependency expression";
    buildRpm {
      name = "rpm-impurifier";
      version = core.runtimeVersion;
      payload = core.makeRuntimeTree { };
      description = "Native package intent projected into a Nix profile";
      license = "MIT";
      extraSpec = ''
        Requires: python3, /bin/sh
        Requires: ${nixDependency}
      '';
      scriptlets = ''
        # Solvers may autoremove this runtime with its last dependent app.
        # Dependent payloads have been erased before this final preun runs,
        # while the engine and its Python/Nix dependencies are still present.
        %preun
        unset PYTHONHOME PYTHONPATH
        if [ "$1" -eq 0 ]; then
          /usr/sbin/nix-profile-engine reconcile || exit $?
          /usr/sbin/nix-profile-engine prune --keep 0 || exit $?
        fi
        %posttrans
        unset PYTHONHOME PYTHONPATH
        /usr/sbin/nix-profile-engine reconcile
        %transfiletriggerin -- /usr/share/nix-profile.d /usr/lib /usr/lib64 /lib /lib64
        unset PYTHONHOME PYTHONPATH
        /usr/sbin/nix-profile-engine reconcile
        %transfiletriggerpostun -- /usr/share/nix-profile.d /usr/lib /usr/lib64 /lib /lib64
        unset PYTHONHOME PYTHONPATH
        /usr/sbin/nix-profile-engine reconcile
      '';
    };
in
{
  inherit (core)
    engine
    offlineCache
    unit
    runtimeVersion
    ;
  inherit makeRpm makeRuntimeRpm buildRpm;
  coreSource = coreSrc;
  altVerificationHook = ./alt-verify.sh;
  runtimeRpm = makeRuntimeRpm { };
  makePackage = args: {
    net = makeRpm (args // { offline = false; });
    offline = makeRpm (args // { offline = true; });
  };
  makeNetRpm = args: makeRpm (args // { offline = false; });
  makeOfflineRpm = args: makeRpm (args // { offline = true; });
}

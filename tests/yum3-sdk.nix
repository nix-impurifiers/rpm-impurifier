# SPDX-License-Identifier: MIT
{ pkgs }:
let
  legacySource = pkgs.fetchzip {
    url = "https://github.com/NixOS/nixpkgs/archive/a7e559a5504572008567383c3dc8e142fa7a8633.tar.gz";
    hash = "sha256-5v6XuO9dOVpB3ZGNyDvLqOvCnzlyyvscTYbNiQouSZo=";
  };
  legacy = import legacySource { system = pkgs.stdenv.hostPlatform.system; };
  metadataParser = legacy.python27Packages.buildPythonPackage {
    pname = "yum-metadata-parser";
    version = "1.1.4";
    src = pkgs.fetchzip {
      url = "https://github.com/rpm-software-management/yum-metadata-parser/archive/b2565c134876542b44ae795553229912ccbb078e.tar.gz";
      hash = "sha256-g9Q0bXUCFhJnDVjlVtGuIRvEGMk5Cc1agSnf8AazzsM=";
    };
    nativeBuildInputs = [ legacy.pkgconfig ];
    buildInputs = [
      legacy.glib
      legacy.libxml2
      legacy.sqlite
    ];
    doCheck = false;
    postInstall = "mkdir -p $out/share/licenses/yum-metadata-parser; cp package.c $out/share/licenses/yum-metadata-parser/upstream-notice.c";
    meta.license = pkgs.lib.licenses.gpl2Only;
  };
  python = legacy.python27.withPackages (p: [
    metadataParser
    p.rpm
    p.urlgrabber
    p.iniparse
    p.pygpgme
  ]);
  rpm = legacy.python27Packages.rpm;
  yum = pkgs.stdenvNoCC.mkDerivation {
    pname = "yum3";
    version = "3.4.3";
    src = pkgs.fetchzip {
      url = "https://github.com/rpm-software-management/yum/archive/4ed25525ee4781907bd204018c27f44948ed83fe.tar.gz";
      hash = "sha256-+GjpQX9DEWWuE+cH167jtccYzOvz6dBpH/m2rbIF6x8=";
    };
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/bin $out/lib/python2.7/site-packages $out/share/yum-cli $out/share/licenses/yum3
      cp -r yum rpmUtils $out/lib/python2.7/site-packages/
      cp *.py $out/share/yum-cli/
      cp bin/yum $out/share/yum-cli/yum-entry.py
      cp COPYING $out/share/licenses/yum3/
      substituteInPlace $out/share/yum-cli/yum-entry.py --replace-fail /usr/share/yum-cli $out/share/yum-cli
      makeWrapper ${python}/bin/python $out/bin/yum3 --add-flags $out/share/yum-cli/yum-entry.py \
        --prefix PYTHONPATH : $out/lib/python2.7/site-packages \
        --prefix PATH : ${rpm}/bin
    '';
    meta.license = pkgs.lib.licenses.gpl2Plus;
  };
in
{
  inherit yum rpm python;
}

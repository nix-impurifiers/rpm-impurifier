# SPDX-License-Identifier: MIT
{ pkgs }:
let
  inherit (pkgs) perlPackages;
  packdrakeng = perlPackages.buildPerlPackage {
    pname = "MDV-Packdrakeng";
    version = "1.13";
    src = pkgs.fetchzip {
      url = "https://cpan.metacpan.org/authors/id/T/TV/TVIGNAUD/MDV-Packdrakeng-1.13.tar.gz";
      hash = "sha256-3Cr/+cDUpfQNVsE/GmG/Hn2cwww8qXw0qVNnyAsjV+o=";
    };
    doCheck = false;
    meta.license = pkgs.lib.licenses.gpl2Plus;
  };
  distribconf = perlPackages.buildPerlPackage {
    pname = "MDV-Distribconf";
    version = "4.101";
    src = pkgs.fetchzip {
      url = "https://cpan.metacpan.org/authors/id/T/TV/TVIGNAUD/MDV-Distribconf-4.101.tar.gz";
      hash = "sha256-08rcddjBgQT2BlbkdnNERgX0VXTefrRrpWwxBhrrHxs=";
    };
    propagatedBuildInputs = [
      packdrakeng
      perlPackages.ConfigIniFiles
    ];
    doCheck = false;
    meta.license = pkgs.lib.licenses.gpl2Plus;
  };
  zoneinfo = perlPackages.buildPerlPackage {
    pname = "Time-ZoneInfo";
    version = "0.3";
    src = pkgs.fetchzip {
      url = "https://cpan.metacpan.org/authors/id/S/SC/SCOTT/Time-ZoneInfo-0.3.tar.gz";
      hash = "sha256-+s3sN2skvJwxQ3CMR0Qm3wWZ5JDeR+1p59F0Z4JeqSk=";
    };
    doCheck = false;
    meta.license = pkgs.lib.licenses.artistic1;
  };
  fileSync = perlPackages.buildPerlPackage {
    pname = "File-Sync";
    version = "0.11";
    src = pkgs.fetchzip {
      url = "https://cpan.metacpan.org/authors/id/B/BR/BRIANSKI/File-Sync-0.11.tar.gz";
      hash = "sha256-wmGDD6S68+gniCgrTA0sn8pAHXKdaOOCF7nvByKXJqY=";
    };
    doCheck = false;
    meta.license = pkgs.lib.licenses.artistic1;
  };
  URPM = perlPackages.buildPerlPackage {
    pname = "URPM";
    version = "5.225";
    src = pkgs.fetchzip {
      url = "https://cpan.metacpan.org/authors/id/T/TV/TVIGNAUD/URPM-v5.225.tar.gz";
      hash = "sha256-9t2xtYcMorbo/d4G7lzn5pZg6IjFRXb0SV3NVapCHfI=";
    };
    nativeBuildInputs = [
      pkgs.pkg-config
      perlPackages.ExtUtilsDepends
      perlPackages.ExtUtilsPkgConfig
    ];
    buildInputs = [
      pkgs.rpm
      pkgs.file
    ];
    propagatedBuildInputs = [ packdrakeng ];
    doCheck = false;
    meta.license = with pkgs.lib.licenses; [
      artistic1
      gpl1Plus
    ];
  };
  urpmi = perlPackages.buildPerlPackage {
    pname = "urpmi";
    version = "8.133.1";
    src = pkgs.fetchzip {
      url = "https://cpan.metacpan.org/authors/id/T/TV/TVIGNAUD/urpmi-v8.133.1.tgz";
      hash = "sha256-uku9LTaNaJC7NKz46sFRK2FMgq5MEtLSMQxNUkAg2fM=";
    };
    nativeBuildInputs = [
      pkgs.makeWrapper
      pkgs.rpm
    ];
    propagatedBuildInputs = [
      URPM
      distribconf
      zoneinfo
      fileSync
      perlPackages.FilesysDf
      perlPackages.LocaleGettext
      perlPackages.NetLDAP
      perlPackages.XMLLibXML
      perlPackages.TermReadKey
    ];
    postPatch = ''
      substituteInPlace Makefile.PL --replace-fail /var/cache/urpmi ${placeholder "out"}/var/cache/urpmi
    '';
    makeMakerFlags = [ "--without-rpm" ];
    makeFlags = [
      "SYSCONFDIR=${placeholder "out"}/etc"
      "LOCALSTATEDIR=${placeholder "out"}/var/lib"
      "INSTALLLIBEXECDIR=${placeholder "out"}/libexec"
    ];
    doCheck = false;
    postFixup = ''
      for program in $out/bin/* $out/sbin/* $out/libexec/*; do
        test -f "$program" || continue
        wrapProgram "$program" --prefix PERL5LIB : "${
          perlPackages.makeFullPerlPath [
            URPM
            distribconf
            zoneinfo
            fileSync
            perlPackages.FilesysDf
            perlPackages.LocaleGettext
            perlPackages.NetLDAP
            perlPackages.XMLLibXML
            perlPackages.TermReadKey
          ]
        }" --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.rpm
            pkgs.gnupg
            pkgs.coreutils
            pkgs.gzip
            pkgs.xz
          ]
        }
      done
    '';
    meta.license = pkgs.lib.licenses.gpl2Plus;
  };
in
{
  inherit URPM urpmi;
}

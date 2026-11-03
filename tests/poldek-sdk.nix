# SPDX-License-Identifier: MIT
{ pkgs }:
let
  trurlib = pkgs.fetchzip {
    url = "https://github.com/poldek-pm/trurlib/archive/4c422ad18c9862939cb201b36b68a01d2c6b9567.tar.gz";
    hash = "sha256-6l9ZvUmPaxB2ZWr9MuM2ezIZdO0IHoncnH6krwZWSRs=";
  };
  tndb = pkgs.fetchzip {
    url = "https://github.com/poldek-pm/tndb/archive/44be14137606e2fcd9b1207158fb80cc019a5fbe.tar.gz";
    hash = "sha256-P634X5fB9lm8Kw0g0fE3sC+XhgAWn7yYMNJbGCMxjxM=";
  };
in
{
  poldek = pkgs.stdenv.mkDerivation {
    pname = "poldek";
    version = "0.45.0";
    src = pkgs.fetchzip {
      url = "https://github.com/poldek-pm/poldek/archive/refs/tags/v0.45.0.tar.gz";
      hash = "sha256-k90fHdxjl2juzjGvc0uZSIB1Dnz6e5JlFISeFVFWZ/I=";
    };
    patches = [
      (pkgs.fetchurl {
        url = "https://github.com/poldek-pm/poldek/commit/8df4ec24557164bdf54d545541934b7bfa577c60.patch";
        hash = "sha256-o6DPIhMoAtrgmIwZMiIyalCVIBbDJDp+6+Em5LLxmPQ=";
      })
    ];
    postUnpack = ''
      cp -r ${trurlib}/. source/trurlib/
      cp -r ${tndb}/. source/tndb/
      chmod -R u+w source/trurlib source/tndb
    '';
    postPatch = ''
      patchShebangs .
      substituteInPlace configure.ac \
        --replace-fail /usr/include/libxml2 ${pkgs.lib.getDev pkgs.libxml2}/include/libxml2 \
        --replace-fail /usr/include/rpm ${pkgs.lib.getDev pkgs.rpm}/include/rpm
    '';
    nativeBuildInputs = [
      pkgs.autoreconfHook
      pkgs.pkg-config
      pkgs.gettext
      pkgs.perl
      pkgs.perlPackages.XMLSimple
      pkgs.bison
      pkgs.flex
      pkgs.docbook2x
      pkgs.texinfo
      pkgs.libxslt
      pkgs.xmlto
      pkgs.docbook_xml_dtd_412
      pkgs.docbook_xml_dtd_45
      pkgs.docbook_xsl
    ];
    buildInputs = [
      pkgs.check
      pkgs.rpm
      pkgs.pcre
      pkgs.popt
      pkgs.openssl
      pkgs.zlib
      pkgs.bzip2
      pkgs.libxml2
      pkgs.readline
      pkgs.db
      pkgs.curl
      pkgs.xz
      pkgs.ncurses
    ];
    preAutoreconf = ''
      make -f Makefile.extra POTFILES_in
    '';
    preInstall = "make -C doc poldek.info";
    configureFlags = [
      "--without-python"
      "--with-xml-metadata"
    ];
    enableParallelBuilding = true;
    meta.license = pkgs.lib.licenses.gpl2Only;
  };
}

# SPDX-License-Identifier: MIT
{ ... }:
{ lib, inputs, ... }:
{
  flake.lib = lib.mkForce {
    rpm-impurifier =
      {
        pkgs,
        rpmCompatibility ? "modern",
      }:
      import ../../../nix {
        inherit pkgs rpmCompatibility;
        coreSrc = inputs.impurifier;
        sourceInfo = inputs.self;
      };
  };
  perSystem =
    { pkgs, ... }:
    let
      impurifier = import ../../../nix {
        inherit pkgs;
        coreSrc = inputs.impurifier;
        sourceInfo = inputs.self;
      };
    in
    {
      packages = {
        default = impurifier.engine;
        hello-native-packages = impurifier.makeNativeRpms { pkg = pkgs.hello; };
        engine = impurifier.engine;
        runtime-rpm = impurifier.runtimeRpm;
        hello-net-rpm = impurifier.makeNetRpm { pkg = pkgs.hello; };
        hello-offline-rpm = impurifier.makeOfflineRpm { pkg = pkgs.hello; };
      };
      formatter = pkgs.nixfmt-tree;
      checks = import ../../../tests {
        inherit pkgs impurifier;
        coreSrc = inputs.impurifier;
      };
    };
}

# Testing

`nix flake check -L` runs the shared core's unit suite, emitter contracts, and
real RPM transactions in QEMU. The VM's application closure must be absent at
boot. Tests cover trigger failures, offline recovery without a network, native
config preservation, upgrades/switching/batching, service lifecycle and GC.

RPM trigger failures do not imply native DB rollback; the tests explicitly
verify diagnostics and the still-active old profile. The PID 1 is NixOS systemd
with a mutable native-style unit directory. Full distro/front-end matrices and
the separate Nix installer are additional work, not claims of these tests.

Lifecycle migrations and native host-library upgrades are checked in backend VMs. Hardware fixtures use a real ELF loader and versioned native driver packages; dpkg additionally checks service restart, immutable old generations, missing-library failure and snapshot GC roots. Real GPU compatibility requires separate device testing.

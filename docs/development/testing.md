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

The repository matrix uses native DNF 4.24.0, DNF 5.4.6.0, microdnf 3.10.1 and
tdnf 3.5.9 against local real createrepo repositories and signed RPMs. Each VM
rejects corrupt and unsigned packages, observes the native committed DB after a
net trigger failure, recovers with offline content, upgrades/preserves conffiles,
and tests native runtime removal and GC. DNF 5 automatically removes dependencies;
other clients may require an explicit runtime removal. The regression checks
that the command disappears before any external cleanup is attempted.

The microdnf SDK adds the missing executable export linker flag so libpeas can
resolve its actual built-in command modules; its implementation is unchanged.
DNF 4 uses a real empty versionlock configuration and explicit FHS plugin config
path. Tdnf uses its upstream native configuration and RPM
`%_pkgverify_level all` for unsigned-package rejection. Without that native
verification policy, this tdnf/RPM combination accepted the unsigned test RPM
despite `gpgcheck=1`; the test does not claim its default policy rejects it. These are disclosed SDK/fixture
integration choices, not replacement clients. The VMs use 1 GiB each and CI limits
concurrent Nix builds to two.

The official openSUSE rootfs is pinned by the compressed OCI layer's SHA-256
(20261031.37.278, x86_64). Zypper/libzypp, RPM, their shared libraries and installed
package database all come from that image. Only actual preinstalled Nix/Python
FHS links are supplied by a fixture RPM; ordinary applications do not depend on
an invented systemd provider. The test mounts the real Nix store/state plus
profile/engine state into the userspace so the native GC root paths retain their
meaning outside the chroot. Native GPG signs both package and repository metadata;
Zypper's package and repository signature checks remain enabled.

# rpm-impurifier

Emit native RPM packages that project Nix applications into `/opt/nix/profile`.
RPM owns install intent, configuration files and host integration. The pinned
[`impurifier` core](https://github.com/nix-impurifiers/impurifier) supplies closure
caches, collision checks, GC roots, atomic publication and activation recovery.
This backend targets RPM, with consumer-controlled native dependencies; there
is no distribution-detection table.

```nix
let impurifier = inputs.rpm-impurifier.lib.rpm-impurifier { inherit pkgs; };
in impurifier.makePackage {
  pkg = pkgs.hello;
  # Optional: name, version, release (default "1"), priority, license.
}
```

`makePackage` returns `{ net; offline; }`. `makeRpm`, `makeNetRpm`, and
`makeOfflineRpm` emit individual artifacts. The native version and release must
be RPM-compatible; override `version` for upstream names containing hyphens.
Both flavors provide the versioned logical application name and replace/conflict
with their sibling. They do not compile the application on the target.

```nix
impurifier.makeRuntimeRpm {
  nixDependency = "(nix or nix-external-runtime)";
}
```

The Nix dependency is a native RPM dependency expression. Consumers can name
their own provider. Python 3 and a working Nix runtime must already exist; the
impure Nix provider/installer remains deferred, not out of scope. The runtime
searches native executable directories and `/nix/var/nix/profiles/default/bin`.

`configFiles`, `files`, `users`, `directories`, and `systemd` use the common
payload DSL. File values accept a source or `{ source; mode; }`. Configuration
files are `%config(noreplace)`, so RPM handles `.rpmnew`/`.rpmsave` behavior.
Users/directories compile to sysusers/tmpfiles declarations. Unit files should
execute `/opt/nix/profile/bin/<tool>`. Service policy fields are `enable`,
`startOnInstall`, `restartOnUpgrade`, and `stopOnRemove` (all default true).
Existing administrator stops/disables survive upgrades; service removal stops
and disables the unit while retaining accounts and persistent data.
`hostDependencies` defaults to `[ "systemd" ]` and is consumer-controlled.

Net packages substitute through administrator-configured Nix caches. Offline
packages contain the full application closure as a package-owned local cache;
those imports select only that cache and disable remote builders. They do not
change global cache trust. RPM artifact headers contain store hashes in cache
filenames, so these self-contained native archives explicitly discard Nix output
references. A contract check and an absent-at-boot VM assertion prevent the test
image from silently preinstalling the application closure.

## Native transaction semantics

The runtime uses RPM transaction file triggers for descriptor installation and
removal, plus initial post-transaction reconciliation. Multiple trigger waves
are harmless: an identical manifest set is a no-op. One application transaction
produces one effective profile activation in the batch VM test.

**RPM may commit its database and return success despite a failing transaction
trigger.** The engine reports the error and preserves the old profile on fetch
or composition failure, but it cannot make RPM roll back its transaction.
Check transaction diagnostics and reconcile after fixing cache availability or
installing the offline flavor. `nix-profile-engine status` shows the actual
profile's descriptors rather than claiming the native database is activation
proof. Service failures may occur after the profile advances; pending restart
intent is retried by reconciliation.

```sh
sudo /usr/sbin/nix-profile-engine reconcile
sudo /usr/sbin/nix-profile-engine status
sudo /usr/sbin/nix-profile-engine prune --keep 2
```

The state/cache namespace is `rpm-impurifier`. Pruning retains the active
generation; Nix GC is separate. Native package downgrades express rollback intent.

## Verification

```sh
nix flake check -L
nix build '.#runtime-rpm' '.#hello-net-rpm' '.#hello-offline-rpm'
nix fmt
```

Checks include the common engine's unit contracts, native RPM metadata/custom
Nix dependency expressions, reference-free artifact closures, and a QEMU VM
running actual RPM/Nix/systemd. The VM exercises missing-substitution failure,
network-disabled offline recovery, provider switching, edited config files,
upgrades, batching, service users/directories, administrator stop/disable
preservation, service removal, GC roots and generation pruning. It uses a NixOS
PID 1 with mutable native-style unit directories, not a complete Fedora/RHEL
installation. Repository VMs additionally exercise DNF 4, DNF 5, microdnf
and tdnf with real createrepo metadata, ephemeral native GPG signing, damaged
and unsigned package rejection, net failure/offline recovery, transport
replacement, upgrades/conffiles, runtime removal and GC. The DNF 4 SDK's actual `yum` entry point has its own
matrix test. Historical Yum 3 has a separate Python 2/RPM 4.14 SDK and VM.

A separate VM runs Zypper 1.14.102/libzypp 17.38.17 and its real RPM database
inside the pinned official openSUSE Tumbleweed 20261031 userspace. It checks
signed repository metadata and RPMs, metadata-tamper and unsigned-package
rejection, net failure/offline recovery, ordinary-user launch, unchanged native
checksums, upgrades/conffiles and runtime removal/GC. Nix and Python are supplied
by an explicitly owned native fixture provider. The fixture shares real Nix
state and roots with its NixOS host; it does not boot a full SUSE init system.
Additional VMs use genuine Poldek 0.45, urpmi 8.133.1/URPM 5.225, and the
complete official ALT Sisyphus userspace with APT-RPM and ALT RPM 4.13. These
exercise native local-package transactions, signature/corruption policy,
net failure/offline recovery, native ownership and verification, configuration
preservation, ordinary-user execution, upgrades and removal/GC. Poldek's local
directory source resolves actual native dependencies; urpmi and ALT use local
package files. Remote Poldek indexes, urpmi hdlist media and ALT repository
publication are separate coverage. The ALT fixture shares actual Nix state
with its NixOS host and does not claim a complete ALT boot.

For older frontends, pass `rpmCompatibility = "alt"` or `"rpm4.14"` to the
public flake library factory:

```nix
inputs.rpm-impurifier.lib.rpm-impurifier {
  inherit pkgs;
  rpmCompatibility = "alt";
}
```

Direct source imports also accept this option alongside `pkgs` and `coreSrc`.
Both compatibility settings select native gzip payloads.
The ALT setting additionally uses librpm to omit the optional SHA256 header
digest tag that ALT RPM 4.13 cannot verify. It leaves the main header and payload
unchanged, refuses signed inputs, and runs before the publisher signs the
artifact. Native ALT signing and verification must succeed; corrupt packages
must still fail verification. The default `"modern"` format remains unchanged.

ALT APT-RPM disables librpm transaction verification. For signed local packages,
install `altVerificationHook` as `/usr/sbin/impurifier-verify-rpms` (mode 0755)
and add this to `/etc/apt/apt.conf.d/impurifier-verify.conf`:

```text
RPM::Pre-Install-Pkgs { "/usr/sbin/impurifier-verify-rpms"; };
```

The hook requires successful native `rpm -Kv` verification and a valid signature
for every incoming package before APT starts the transaction. Import the
publisher's trusted key into the native RPM database first. The VM checks both
unsigned and damaged artifacts against this policy. This policy covers all
incoming RPMs in that transaction, so use signed provider/runtime RPMs too.
For urpmi and ALT, use `makeRuntimeRpm { nixDependency = "nix"; }` (or another
real provider name); urpmi's solver cannot resolve the default rich OR expression.

The SDKs preserve upstream licenses. Poldek uses the upstream RPM compatibility
fix from commit `8df4ec24557164bdf54d545541934b7bfa577c60`; it does not replace
its resolver or transaction implementation. Historical Yum uses genuine upstream
3.4.3 modules, Python 2 bindings and RPM 4.14.2 from pinned Nixpkgs 18.09.
RPM runtime scriptlets clear inherited `PYTHONHOME` and `PYTHONPATH` before
starting the Python 3 engine, including when invoked by a Python 2 frontend.
These isolated compatibility SDKs are test infrastructure, not application
runtime dependencies.

For an explicit same-version transport replacement, use native
`dnf5 swap APP-net APP-offline` or `microdnf swap APP-net APP-offline`.
DNF 4 needs `dnf4 --setopt=obsoletes=0 swap APP-net APP-offline` so its implicit
Obsoletes expansion does not select the already-installed reciprocal provider.
The tested tdnf flow removes the old transport and installs the new one.
For tdnf 3.5.9 with RPM 4.20, the signed-repository fixture also sets RPM's
`%_pkgverify_level all`: this native policy is needed to reject unsigned RPMs;
`gpgcheck=1` alone accepted them in the tested configuration.
Ordinary version upgrades use the frontend's native `upgrade` command.

When a solver removes the runtime along with its last dependent application,
the runtime's final `%preun` reconciles the now-empty intent and prunes retained
generations while its engine, Nix and Python dependencies are still available.
Runtime upgrades retain the normal generation policy.

`buildRpm` is a lower-level helper accepting an already-prepared filesystem
`payload`, `name`, `version`, optional `release`, `architecture`, `description`,
`license`, `configPaths`, and raw `extraSpec`/`scriptlets` escape hatches. Normal
application authors should use `makePackage` or `makeRpm`.

MIT.

Lifecycle hooks `lifecycle.onInstall` and `lifecycle.onUpgrade` accept shell bodies. They run as root after accounts/directories exist and the new profile is published, before service activation. Use `/opt/nix/profile/bin/<tool>` for projected commands and declare native dependencies for other commands. Install hooks run until the application's first successful activation; upgrade hooks run when its output, version or hook revision changes, including native downgrades. A failed hook leaves activation pending and may be retried, so hooks must be idempotent. They do not provide database rollback or exactly-once execution. Flavor-only changes to the same application do not rerun completed hooks.

Host-library bridging is opt-in:

```nix
hardware = {
  libraries."libdriver.so.1" = "/usr/lib/libdriver.so.1";
  programs = [ "my-tool" ];
  preload = []; # Optional subset of declared library names.
};
```

The engine captures explicitly selected ELF files into an immutable Nix-store directory, roots it with the generation, and wraps the selected application's `bin` commands with `LD_LIBRARY_PATH` and optional `LD_PRELOAD`. Native library-directory transaction hooks reconcile driver upgrades. Changed snapshots create a new generation and restart previously running managed services according to their upgrade policy. Older generations retain their original user-space snapshot. Missing or unreadable libraries abort before profile publication; the existing snapshot remains usable.

Consumers select compatible libraries, their non-Nix dependencies, paths and native package dependencies. This does not discover a GPU stack, validate its ABI, rebind already-running processes, or roll back kernel modules. GPU user/kernel compatibility and real-device behavior need hardware tests. Sources outside `/usr/lib`, `/usr/lib64`, `/lib` and `/lib64` need explicit reconciliation after updates. This is a bounded runtime bridge, not automatic GPU compatibility.

The exported `runtimeVersion` follows the later of the pinned core and adapter source timestamps. Application dependencies require that runtime version or newer, rather than accepting every engine as `0.1.0`. This supports ordinary native engine upgrades without project release tags. Consumer-provided Nix dependency expressions remain independent of the engine's own native version.


## Native-owned closures and optional bundled Nix

`makeNativeRpms { pkg = myApplication; programs = [ "my-command" ]; }` returns
a directory of native packages: one application package exporting commands, and
one package per immutable runtime store object. Exact native dependencies retain
shared objects. Native tools own the files and package database. The target needs
no Nix executable, daemon, SQLite database, realization hooks or shared profile.
Files remain at their original absolute paths; no relocation is performed.
Inputs may come from any compatible Nix producer. This API currently covers
payload files and command exports rather than the profile-mode host lifecycle DSL.

Install the collection with ordinary native tools, or publish its artifacts in
a native repository. Local-file installation may mark supplied dependency
packages explicit; native dependency marks and cleanup policy remain the caller's
choice. Upgrades can leave old immutable objects orphaned, so include native
orphan cleanup when desired. Do not register these same paths into a Nix-managed
store: Nix GC and native ownership must not overlap.

`makeRuntimeRpm` additionally accepts `bundledNixStore` (a supplied static ELF
`nix-store` executable) and nonempty `bundledNixNotices`. A bundle makes the
external native Nix dependency optional and marks the runtime package with its
actual target architecture. A compatible external client is preferred; otherwise
the private bundled client is used. Explicit `nixDependency` still requests a
native provider. Client selection never changes store ownership or trust, and a
failed mutation is not retried with another client. This is not daemon setup.

`native-vm` tests isolated target-root installation, execution, upgrades, shared
references, checksum verification and final cleanup without target-side Nix.
`bundled-vm` reruns native lifecycle and recovery tests without an external client
on the engine's discovery paths, using the actual static client. Those lifecycle
fixtures still supply an existing Nix store; database-free operation is established
by the separate native-owned test, not by the bundled client.

Native-owned RPM collections currently target modern RPM; legacy compatibility
SDKs retain their existing profile-mode coverage. RPM itself has no automatic
orphan sweep: cleanup must query dependencies or use an appropriate frontend.

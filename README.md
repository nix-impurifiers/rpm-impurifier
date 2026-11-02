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
installation. DNF/zypper frontend matrices remain additional compatibility tests.

`buildRpm` is a lower-level helper accepting an already-prepared filesystem
`payload`, `name`, `version`, optional `release`, `architecture`, `description`,
`license`, `configPaths`, and raw `extraSpec`/`scriptlets` escape hatches. Normal
application authors should use `makePackage` or `makeRpm`.

GPL-3.0-or-later.

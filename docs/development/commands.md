# Commands

`nix flake check -L`, `nix fmt`, and
`nix build '.#runtime-rpm' '.#hello-net-rpm' '.#hello-offline-rpm'`.
Use `--override-input impurifier path:../impurifier --no-write-lock-file` only
for transient local core development; published pins resolve through GitHub.

#!/bin/sh
# SPDX-License-Identifier: MIT
# Install as an RPM::Pre-Install-Pkgs hook for APT-RPM local-file transactions.
# APT-RPM disables librpm verification inside its transaction implementation.
set -eu
while IFS= read -r package; do
    if ! verification=$(/bin/rpm -Kv "$package" 2>&1); then
        printf '%s\n' "$verification" >&2
        echo "RPM signature verification failed: $package" >&2
        exit 1
    fi
    if ! printf '%s\n' "$verification" | grep -Eq 'Signature.*: OK$'; then
        echo "RPM signature required: $package" >&2
        exit 1
    fi
done

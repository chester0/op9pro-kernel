#!/bin/sh
# Starts sshd in the foreground: key auth only, one user, host key kept in /work so it survives rebuilds.
set -eu

PORT="${SSH_PORT:-2222}"
KEY=/work/ssh_host_ed25519_key

[ -s /work/authorized_keys ] || { echo "no /work/authorized_keys - put the Evo's public key there" >&2; exit 1; }
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"

# StrictModes off: /work is a bind mount whose owner is whoever pushed the file (adb shell uid).
exec /usr/sbin/sshd -D -e \
    -p "$PORT" \
    -h "$KEY" \
    -o PasswordAuthentication=no \
    -o PermitRootLogin=no \
    -o AllowUsers=worker \
    -o AuthorizedKeysFile=/work/authorized_keys \
    -o StrictModes=no

#!/system/bin/sh
# docker-runc-nomq.sh - runc, minus the /dev/mqueue mount. Registered as Docker runtime "nomq" (default) by
# docker-daemon.sh. Not meant to be run by hand.
#
# 2026-10-31 (9 Pro, Levion kernel): Docker puts a "mqueue" mount in every container's OCI config, and runc fails
# ("error mounting mqueue ... no such device") on a kernel without CONFIG_POSIX_MQUEUE. The Levion kernel has none,
# and turning it on changes ~1000 exported-symbol CRCs, so the phone's vendor modules would stop loading
# (thin/fragments/levion-docker.config). Containers then run without POSIX message queues, which almost
# nothing uses. When the kernel has them, the mount is simply not removed.
#
# Only `create` carries a --bundle; every other runc call is passed through untouched.

REAL_RUNC="${DOCKER_REAL_RUNC:-/data/docker/bin/runc}"
PROC_FILESYSTEMS="${DOCKER_PROC_FILESYSTEMS:-/proc/filesystems}" # overridable for the tests
MQUEUE_ENTRY='{"destination":"/dev/mqueue"[^}]*}'

if ! grep -q mqueue "$PROC_FILESYSTEMS" 2>/dev/null; then
    bundle=
    prev=
    for arg in "$@"; do
        case "$arg" in
            --bundle=*) bundle="${arg#--bundle=}" ;;
        esac
        case "$prev" in
            --bundle | -b) bundle="$arg" ;;
        esac
        prev="$arg"
    done
    if [ -n "$bundle" ] && [ -f "$bundle/config.json" ]; then
        # The entry is never the first mount (proc is), so the comma in front of it goes with it.
        sed -i "s#,$MQUEUE_ENTRY##" "$bundle/config.json"
    fi
fi

exec "$REAL_RUNC" "$@"

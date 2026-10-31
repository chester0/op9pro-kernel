#!/system/bin/sh
# docker-down.sh - stop dockerd (and with it containerd and the containers) on the phone.
#   adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-down.sh'"
# Idempotent: "not running" is success. Removes the container routing rule docker-up.sh added.
# The private mount namespace disappears with its last process, so nothing is left mounted; the
# empty mount-point dir and the overlay's upper dir on /data are removed here.

DIR=$(dirname "$0")
# shellcheck source=docker-common.sh
. "$DIR/docker-common.sh"
# shellcheck source=docker-namespace.sh
. "$DIR/docker-namespace.sh"

STOP_TIMEOUT=40

main() {
    require_root
    if pid=$(dockerd_pid); then
        say "stopping dockerd (pid $pid)"
        kill -TERM "$pid"
        n=0
        while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$STOP_TIMEOUT" ]; do
            n=$((n + 1))
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            say "dockerd ignored TERM for ${STOP_TIMEOUT}s - killing"
            kill -KILL "$pid"
        fi
    else
        say "dockerd not running"
    fi
    rm -f "$DOCKER_SOCK" "$DOCKER_PIDFILE"
    clean_root_view
    ip rule del pref "$ROUTE_PREF_OUT" 2>/dev/null
    ip rule del pref "$ROUTE_PREF_IN" 2>/dev/null
    say "dockerd down"
}

main "$@"

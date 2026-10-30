#!/system/bin/sh
# docker-up.sh - start dockerd on the OnePlus 9 Pro. Run ON the phone as root:
#   adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-up.sh'"
# Idempotent: refuses (exit 0, says so) if dockerd already runs. Options:
#   --selinux-permissive   setenforce 0 first (global, until reboot). Only if the log shows AVC denials.
# Android's own cgroups/etc are untouched: dockerd lives in a private mount namespace, see
# docker-daemon.sh. Data lives in /data/docker, never /system.

DIR=$(dirname "$0")
# shellcheck source=docker-common.sh
. "$DIR/docker-common.sh"

ROUTE_PREF=5999       # below Android's netd rules (10000+), so containers reach the default network
START_TIMEOUT=90
PIDFILE_GRACE=20

usage() { say "usage: sh docker-up.sh [--selinux-permissive]"; exit 2; }

# Android policy-routes by fwmark; a packet from docker0 has none and would hit "unreachable".
# Send container traffic to the table of the interface that holds the default route.
route_fix() {
    [ "$(cat "$DOCKER_MODE_FILE" 2>/dev/null)" = bridge ] || return 0
    tbl="${DOCKER_ROUTE_TABLE:-$(ip route show table all 2>/dev/null | awk '
        $1 == "default" {
            t = ""; d = ""
            for (i = 1; i < NF; i++) { if ($i == "table") t = $(i + 1); if ($i == "dev") d = $(i + 1) }
            if (t != "" && d !~ /^(tun|tailscale|lo)/) { print t; exit }
        }')}"
    if [ -z "$tbl" ]; then
        say "WARN: no default route found - containers have no internet until Wi-Fi is up; then run docker-down.sh and docker-up.sh again"
        return 0
    fi
    ip rule del pref "$ROUTE_PREF" 2>/dev/null
    ip rule add pref "$ROUTE_PREF" from "$DOCKER_BRIDGE_CIDR" lookup "$tbl" && say "route: containers -> table $tbl (ip rule pref $ROUTE_PREF)"
}

wait_ready() {
    n=0
    while [ "$n" -lt "$START_TIMEOUT" ]; do
        # dockerd writes its pidfile only after the daemon script has built the namespace, so a
        # missing pidfile is normal for the first PIDFILE_GRACE seconds.
        if [ "$n" -ge "$PIDFILE_GRACE" ] && ! dockerd_pid >/dev/null; then
            say "dockerd exited while starting. Last log lines:"
            tail -n 40 "$DOCKER_LOG"
            return 1
        fi
        if [ -e "$DOCKER_SOCK" ] && docker info >/dev/null 2>&1; then
            return 0
        fi
        n=$((n + 1))
        sleep 1
    done
    say "timeout after ${START_TIMEOUT}s waiting for dockerd. Last log lines:"
    tail -n 40 "$DOCKER_LOG"
    return 1
}

detach() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >>"$DOCKER_LOG" 2>&1 &
    else
        nohup "$@" </dev/null >>"$DOCKER_LOG" 2>&1 &
    fi
}

main() {
    permissive=0
    for arg in "$@"; do
        case "$arg" in
            --selinux-permissive) permissive=1 ;;
            *) usage ;;
        esac
    done

    require_root
    if pid=$(dockerd_pid); then
        say "dockerd already running (pid $pid) - nothing to do"
        exit 0
    fi
    [ -x "$DOCKER_BIN/dockerd" ] || die "$DOCKER_BIN/dockerd missing - run tools/push-docker.ps1 first"
    command -v unshare >/dev/null 2>&1 || { write_diag; die "no 'unshare' on this Android; send $DOCKER_DIAG"; }

    mkdir -p "$DOCKER_LOG_DIR" "$DOCKER_RUN" "$DOCKER_TMP"
    rm -f "$DOCKER_SOCK"
    write_diag
    [ "$permissive" = 1 ] && { setenforce 0 && say "SELinux set permissive until reboot"; }

    say "starting dockerd (log: $DOCKER_LOG)"
    detach unshare -m sh "$DIR/docker-daemon.sh"
    if ! wait_ready; then
        say "FAILED. Send back: $DOCKER_DIAG and $DOCKER_LOG"
        exit 1
    fi
    route_fix
    say "dockerd up, pid $(dockerd_pid), network mode $(cat "$DOCKER_MODE_FILE")"
    if grep -q " - tmpfs dockercg " "$DOCKER_INIT_MOUNTINFO" 2>/dev/null; then
        say "WARN: Docker's cgroup tmpfs is visible in the global namespace - run docker-down.sh and send diag.txt"
    else
        say "isolation check: Android's own mounts untouched"
    fi
}

main "$@"

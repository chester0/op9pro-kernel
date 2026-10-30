#!/system/bin/sh
# docker-common.sh - sourced by the other docker-*.sh scripts (runs ON the phone, as root).
# One place for paths, logging and the "is dockerd running" check.
# POSIX sh / mksh safe: no `local`, no arrays, no [[ ]].
# Every path can be overridden through the environment (the tests use that).

# shellcheck disable=SC2034  # the variables below are used by the scripts that source this file
DOCKER_BASE="${DOCKER_BASE:-/data/docker}"
DOCKER_BIN="${DOCKER_BIN:-$DOCKER_BASE/bin}"
DOCKER_TOOLS="${DOCKER_TOOLS:-$DOCKER_BASE/tools}"
DOCKER_ROOT="${DOCKER_ROOT:-$DOCKER_BASE/root}"   # data-root: images, layers, volumes
DOCKER_RUN="${DOCKER_RUN:-$DOCKER_BASE/run}"      # exec-root, socket, pidfile, mode file
DOCKER_LOG_DIR="${DOCKER_LOG_DIR:-$DOCKER_BASE/log}"
DOCKER_TMP="${DOCKER_TMP:-$DOCKER_BASE/tmp}"
DOCKER_NEWROOT="${DOCKER_NEWROOT:-$DOCKER_BASE/newroot}" # mount point of dockerd's private root view (empty dir globally)
DOCKER_OV="${DOCKER_OV:-$DOCKER_BASE/ov}"                 # upper+work dirs of that view (tmpfs, or this dir as fallback)
DOCKER_SOCK="$DOCKER_RUN/docker.sock"
DOCKER_PIDFILE="$DOCKER_RUN/docker.pid"
DOCKER_LOG="$DOCKER_LOG_DIR/dockerd.log"
DOCKER_MODE_FILE="$DOCKER_RUN/mode"               # "bridge" or "host-only"
DOCKER_DIAG="$DOCKER_LOG_DIR/diag.txt"
DOCKER_INIT_MOUNTINFO="${DOCKER_INIT_MOUNTINFO:-/proc/1/mountinfo}" # init's (Android's global) mount view
DOCKER_BRIDGE_CIDR="${DOCKER_BRIDGE_CIDR:-172.16.0.0/12}" # gitleaks:allow Docker's default bridge range, not a machine fact

# 2026-10-30: Android has no /etc/resolv.conf, and Go (dockerd) then talks to 127.0.0.1:53.
DOCKER_DNS="${DOCKER_DNS:-1.1.1.1 8.8.8.8}"

PATH="$DOCKER_BIN:/system/bin:/system/xbin:/vendor/bin:$PATH"
export PATH
export DOCKER_HOST="unix://$DOCKER_SOCK"
export TMPDIR="$DOCKER_TMP"
export HOME="${DOCKER_HOME:-$DOCKER_BASE/home}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" = "0" ] || die "must run as root (adb shell \"su -c 'sh $0'\")"
}

# Prints the dockerd pid and returns 0 when dockerd really runs; removes a stale pidfile.
dockerd_pid() {
    [ -r "$DOCKER_PIDFILE" ] || return 1
    _pid=$(cat "$DOCKER_PIDFILE" 2>/dev/null)
    case "$_pid" in
        '' | *[!0-9]*) rm -f "$DOCKER_PIDFILE"; return 1 ;;
    esac
    if kill -0 "$_pid" 2>/dev/null && tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null | grep -q dockerd; then
        printf '%s\n' "$_pid"
        return 0
    fi
    rm -f "$DOCKER_PIDFILE"
    return 1
}

# One-file snapshot of everything we would ask Kai for when something fails.
write_diag() {
    mkdir -p "$DOCKER_LOG_DIR"
    {
        echo "== date: $(date)"
        echo "== uname: $(uname -a)"
        echo "== id: $(id)"
        echo "== selinux: $(getenforce 2>&1)"
        echo "== data fs: $(grep ' /data ' /proc/mounts | head -1)"
        echo "== /proc/cgroups"; cat /proc/cgroups 2>&1
        echo "== cgroup mounts (this namespace)"; grep -E ' cgroup2? ' /proc/self/mountinfo 2>&1
        echo "== iptables: $(iptables --version 2>&1)"
        echo "== toybox applets: $(toybox 2>&1 | tr ' ' '\n' | grep -xE 'unshare|nsenter|setsid|sha256sum|tar|mount' | tr '\n' ' ')"
        echo "== ip rule"; ip rule 2>&1
        echo "== ip route (all tables, default only)"; ip route show table all 2>&1 | grep '^default'
        echo "== docker bin:"; echo "$DOCKER_BIN"/*
    } >"$DOCKER_DIAG" 2>&1
}

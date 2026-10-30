#!/system/bin/sh
# docker-probe-root.sh - ONE-TIME check, run ON the phone as root BEFORE docker-up.sh:
#   adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-probe-root.sh'"
# It builds dockerd's overlay root view (see docker-namespace.sh) inside a throwaway `unshare -m`
# namespace, proves /run/docker/plugins can be created in it, prints what worked, and leaves nothing
# behind: the namespace (and with it the overlay and every bind) vanishes when this script ends.
# It never starts dockerd, never touches cgroups or /system/etc, never remounts anything writable,
# never changes SELinux, and uses its own dirs (probe-root, probe-ov) so a running dockerd is unaffected.
# Paste the whole output back; "PROBE RESULT: PASS" means docker-up.sh can use the same view.

# Own dirs, set before docker-common.sh reads them.
PROBE_BASE="${DOCKER_BASE:-/data/docker}"
DOCKER_NEWROOT="$PROBE_BASE/probe-root"
DOCKER_OV="$PROBE_BASE/probe-ov"

DIR=$(dirname "$0")
# shellcheck source=docker-common.sh
. "$DIR/docker-common.sh"
# shellcheck disable=SC2034  # read by log() in docker-namespace.sh
LOG_TAG=probe
# shellcheck source=docker-namespace.sh
. "$DIR/docker-namespace.sh"

# Both overridable for the offline tests, where the stubbed chroot does not change the root.
PLUGIN_DIR="${DOCKER_PROBE_PLUGIN_DIR:-/run/docker/plugins}"
VIEW_PATHS="${DOCKER_PROBE_PATHS:-/proc/self/status /dev/null /sys/fs /data/docker /system/bin/sh /linkerconfig /apex}"

# check <label> <command...>: prints "<label>: OK|FAIL"; counts failures in the namespace's shell.
failures=0
check() {
    label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        say "  $label: OK"
    else
        say "  $label: FAIL"
        failures=$((failures + 1))
    fi
}

in_view() { chroot "$DOCKER_NEWROOT" "$@"; }

overlay_not_global() {
    ! grep -q " - overlay $ROOT_OVERLAY_SRC " "$DOCKER_INIT_MOUNTINFO"
}

inner() {
    require_root
    mkdir -p "$DOCKER_TMP"
    say "== root view probe (throwaway namespace, pid $$)"
    make_mounts_private
    say "  / made private in this namespace: OK"
    say "  / as mounted: $(grep -E '^[0-9]+ [0-9]+ [^ ]+ / / ' "$SELF_MOUNTINFO" | head -1)"
    mount_root_overlay
    prepare_run_dirs
    replicate_mounts
    say "== checks"
    check "overlay not visible in init's namespace" overlay_not_global
    check "mkdir /run/docker/plugins in the chroot (the path moby hardcodes)" in_view mkdir -p "$PLUGIN_DIR"
    check "/var/run resolves to a directory (link to /run)" test -d "$DOCKER_NEWROOT/var/run"
    check "/tmp writable" sh -c ": >'$DOCKER_NEWROOT/tmp/.probe' && rm -f '$DOCKER_NEWROOT/tmp/.probe'"
    # shellcheck disable=SC2016  # the $p is for the inner sh, not for this one
    check "needed paths exist in the chroot" in_view sh -c 'for p in $1; do [ -e "$p" ] || exit 1; done' sh "$VIEW_PATHS"
    if [ -x "$DOCKER_BIN/dockerd" ]; then
        check "dockerd --version runs in the chroot" in_view "$DOCKER_BIN/dockerd" --version
    else
        say "  dockerd --version: skipped ($DOCKER_BIN/dockerd not installed yet)"
    fi
    say "== mounts in the root view: $(grep -c . "$SELF_MOUNTINFO") lines in this namespace"
    [ "$failures" -eq 0 ]
}

main() {
    if [ "$1" = "--inner" ]; then
        inner
        exit $?
    fi
    require_root
    command -v unshare >/dev/null 2>&1 || die "no 'unshare' on this Android"
    say "docker-probe-root: building the overlay root view in a throwaway namespace"
    if unshare -m sh "$DIR/docker-probe-root.sh" --inner; then
        result=PASS
    else
        result=FAIL
        say "== kernel log (overlay):"
        dmesg 2>/dev/null | grep -i overlay | tail -n 5
    fi
    clean_root_view
    for d in "$DOCKER_NEWROOT" "$DOCKER_OV"; do
        [ -e "$d" ] && say "left behind: $d (empty dir; safe to rmdir)"
    done
    say "PROBE RESULT: $result"
    [ "$result" = PASS ]
}

main "$@"

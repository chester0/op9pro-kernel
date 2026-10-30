#!/system/bin/sh
# docker-daemon.sh - INTERNAL: started by docker-up.sh inside a private mount namespace
# (`unshare -m`). It builds dockerd's private view of the system and then `exec`s dockerd, so
# the pidfile pid IS the namespace's init-like process.
#
# Why a private mount namespace (2026-10-30 design decision): Docker wants a tmpfs on
# /sys/fs/cgroup with one v1 mount per controller, and Go wants /etc/resolv.conf. Android
# already uses /sys/fs/cgroup and has a read-only /system/etc. Mounting over them globally
# (what the gist/CGCL recipes do) would break libprocessgroup/netd. In a private namespace the
# mounts exist for dockerd and its containers only; the rest of Android never sees them.
# Sources: https://gist.github.com/hnmn/b110d3840af8653d077d42382454eccb (cgroup wrapper),
# https://github.com/CGCL-codes/Android-Container/blob/main/files/dockerd.sh.

DIR=$(dirname "$0")
# shellcheck source=docker-common.sh
. "$DIR/docker-common.sh"

CG="${DOCKER_CGROUP_DIR:-/sys/fs/cgroup}"   # overridable for the offline tests
ETC_DIR="${DOCKER_ETC_DIR:-/system/etc}"
CG_OPTS=rw,nosuid,nodev,noexec,relatime
REQUIRED_CONTROLLERS="cpuset cpu memory pids devices"

log() { printf '%s docker-daemon: %s\n' "$(date '+%F %T')" "$*"; }

# Android's toybox 0.8.12 (9 Pro, 2026-10-30): `--make-rprivate /` fails (it reads /etc/fstab) and
# `-o rprivate / /` returns 0 but leaves / shared; only `-o rprivate none /` takes. So the result is
# read back from mountinfo, never trusted from the exit code.
root_is_private() {
    ! grep -E '^[0-9]+ [0-9]+ [^ ]+ / / ' "${DOCKER_SELF_MOUNTINFO:-/proc/self/mountinfo}" 2>/dev/null | grep -q ' shared:'
}

make_mounts_private() {
    mount -o rprivate none / 2>/dev/null || mount --make-rprivate / 2>/dev/null
    root_is_private || die "could not make / private in dockerd's namespace; aborted before touching Android"
}

# The tmpfs must never be visible in init's namespace. Check, and abort if it leaked.
# Match OUR mount by its source name (`- tmpfs <source> `), never by the mount point: Android
# already mounts its own cgroup2 at /sys/fs/cgroup in init's namespace, so a mount-point match
# fired on the 9 Pro's first start (2026-10-30) although nothing had leaked.
assert_isolated() { # mount-point source-name
    if grep -q " - tmpfs $2 " "$DOCKER_INIT_MOUNTINFO" 2>/dev/null; then
        umount "$1" 2>/dev/null
        die "mount $1 leaked into the global namespace (could not make / private); aborted before touching Android"
    fi
}

setup_cgroups() {
    mkdir -p "$CG"
    mount -t tmpfs -o "$CG_OPTS,mode=755" dockercg "$CG" || die "tmpfs on $CG failed"
    assert_isolated "$CG" dockercg
    mounted=
    enabled=$(awk 'NR>1 && $4==1 {print $1}' /proc/cgroups)
    for ctl in $enabled; do
        mkdir -p "$CG/$ctl"
        # A controller Android already mounts as v1 hierarchy re-attaches to that same hierarchy.
        if mount -t cgroup -o "$CG_OPTS,$ctl" "$ctl" "$CG/$ctl" 2>/dev/null; then
            mounted="$mounted $ctl"
        else
            log "cgroup controller $ctl: v1 mount refused (in use elsewhere?)"
            rmdir "$CG/$ctl" 2>/dev/null
        fi
    done
    log "cgroup v1 controllers mounted:$mounted"
    missing=
    for ctl in $REQUIRED_CONTROLLERS; do
        case " $mounted " in *" $ctl "*) ;; *) missing="$missing $ctl" ;; esac
    done
    if [ -n "$missing" ]; then
        log "WARNING missing v1 controllers:$missing"
        case " $mounted " in
            *" memory "*) ;;
            *)
                # Android may keep memory/cpu on a cgroup v2 hierarchy; then Docker has to use v2.
                log "memory not on v1 - falling back to a cgroup2 mount (Docker will run in v2 mode)"
                umount -R "$CG" 2>/dev/null
                mount -t cgroup2 -o nsdelegate,rw,nosuid,nodev,noexec,relatime none "$CG" ||
                    mount -t cgroup2 none "$CG" || die "cgroup2 mount failed too; see diag.txt"
                ;;
        esac
    fi
}

# Go reads /etc/resolv.conf. Replace /system/etc (this namespace only) by a tmpfs that links back to
# the real entries (cacerts live there) plus a resolv.conf. /etc is a symlink to /system/etc.
setup_etc() {
    orig="$DOCKER_RUN/etc-orig"
    mkdir -p "$orig"
    mount --bind "$ETC_DIR" "$orig" || die "bind of $ETC_DIR failed"
    mount -t tmpfs -o mode=755 dockeretc "$ETC_DIR" || die "tmpfs on $ETC_DIR failed"
    assert_isolated "$ETC_DIR" dockeretc
    for entry in "$orig"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        [ "$name" = resolv.conf ] || ln -s "$entry" "$ETC_DIR/$name"
    done
    : >"$ETC_DIR/resolv.conf"
    for ns in $DOCKER_DNS; do printf 'nameserver %s\n' "$ns" >>"$ETC_DIR/resolv.conf"; done
}

# overlay2 if the kernel + /data filesystem accept it, else vfs (slow, big, but works).
pick_storage_driver() {
    t="$DOCKER_ROOT/.overlay-test"
    mkdir -p "$t/l" "$t/u" "$t/w" "$t/m"
    if mount -t overlay overlay -o "lowerdir=$t/l,upperdir=$t/u,workdir=$t/w" "$t/m" 2>/dev/null; then
        umount "$t/m"
        echo overlay2
    else
        echo vfs
    fi
    rm -rf "$t"
}

# Bridge networking needs a working iptables nat table.
pick_network_mode() {
    if [ "${DOCKER_IPTABLES:-auto}" != 0 ] && iptables -w -t nat -L -n >/dev/null 2>&1; then
        echo bridge
    else
        echo host-only
    fi
}

dns_json() {
    out=
    for ns in $DOCKER_DNS; do out="${out:+$out, }\"$ns\""; done
    printf '%s' "$out"
}

main() {
    require_root
    mkdir -p "$DOCKER_ROOT" "$DOCKER_RUN" "$DOCKER_LOG_DIR" "$DOCKER_TMP" "$HOME"
    make_mounts_private
    setup_cgroups
    setup_etc

    driver=$(pick_storage_driver)
    mode=$(pick_network_mode)
    printf '%s\n' "$mode" >"$DOCKER_MODE_FILE"
    log "storage driver: $driver, network mode: $mode"

    # Rewritten on every start so the file never drifts from what the scripts decided.
    cat >"$DOCKER_BASE/daemon.json" <<EOF
{
  "storage-driver": "$driver",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "dns": [$(dns_json)],
  "ipv6": false,
  "ip6tables": false,
  "features": {"containerd-snapshotter": false},
  "log-level": "info"
}
EOF

    if [ "$mode" = bridge ]; then
        net_flags="--iptables=true --ip-forward-no-drop"
    else
        net_flags="--iptables=false --bridge=none"
    fi

    # shellcheck disable=SC2086  # net_flags is a deliberate word list
    exec dockerd \
        --config-file "$DOCKER_BASE/daemon.json" \
        --data-root "$DOCKER_ROOT" \
        --exec-root "$DOCKER_RUN" \
        --pidfile "$DOCKER_PIDFILE" \
        --host "unix://$DOCKER_SOCK" \
        $net_flags
}

main "$@"

#!/system/bin/sh
# docker-namespace.sh - sourced by docker-daemon.sh, docker-probe-root.sh and docker-down.sh (after
# docker-common.sh). Everything about dockerd's private mount namespace lives here, once: the
# isolation guards and the writable "root view" dockerd is chrooted into.
# POSIX sh / mksh safe. Defines functions only; it changes nothing when sourced.
#
# Why a root view (2026-10-30 design decision): moby hardcodes /run/docker/plugins (and runc
# /run/docker/runtime-runc, libnetwork /var/run/docker/netns), but Android's / is a read-only ext4
# (dm-2) with no /run, and remounting / rw would write the system partition for the whole phone.
# So, inside the private namespace only, we mount an overlay with lowerdir=/ (the ro system, never
# written) and its upper+work on a tmpfs; /run, /tmp and /var/run live in that upper. The overlay does
# not follow submounts of its lower, so every mount of the namespace (/proc, /dev, /sys with the cgroup
# tmpfs, /data, /apex, /system/etc tmpfs, ...) is bound into it one by one, then dockerd is chrooted in.
# Prior art: CGCL Android-Container dockerd.sh does `mount -o rw,remount /` and binds /data/run over /run
# (global, rejected here); the hnmn gist and Termux recipes dodge /run by moving exec-root into /data
# (works for older moby, not for the hardcoded plugin root). Neither chroots into an overlay of /.
# Sources: https://github.com/CGCL-codes/Android-Container/blob/main/files/dockerd.sh,
# https://gist.github.com/hnmn/b110d3840af8653d077d42382454eccb,
# https://docs.kernel.org/filesystems/overlayfs.html (lower layers' submounts are not followed).

ROOT_OVERLAY_SRC=dockerroot   # source name of OUR overlay: guards match this, never the mount point
OV_TMPFS_SRC=dockerov
OV_TMPFS_OPTS=mode=755,size=128m
# Binds that must succeed when they are separate mounts on this ROM; any other failed bind is a warning.
REQUIRED_MOUNTS="${DOCKER_REQUIRED_MOUNTS:-/proc /dev /sys /data /apex /linkerconfig /system /vendor}"
SELF_MOUNTINFO="${DOCKER_SELF_MOUNTINFO:-/proc/self/mountinfo}"

log() { printf '%s %s: %s\n' "$(date '+%F %T')" "${LOG_TAG:-docker}" "$*"; }

# Android's toybox 0.8.12 (9 Pro, 2026-10-30): `--make-rprivate /` fails (it reads /etc/fstab) and
# `-o rprivate / /` returns 0 but leaves / shared; only `-o rprivate none /` takes. So the result is
# read back from mountinfo, never trusted from the exit code.
root_is_private() {
    ! grep -E '^[0-9]+ [0-9]+ [^ ]+ / / ' "$SELF_MOUNTINFO" 2>/dev/null | grep -q ' shared:'
}

make_mounts_private() {
    mount -o rprivate none / 2>/dev/null || mount --make-rprivate / 2>/dev/null
    root_is_private || die "could not make / private in dockerd's namespace; aborted before touching Android"
}

# Our mounts must never be visible in init's namespace. Check, and abort if one leaked.
# Match OUR mount by fstype + source name (`- tmpfs dockercg `), never by the mount point: Android
# already mounts its own cgroup2 at /sys/fs/cgroup in init's namespace, so a mount-point match
# fired on the 9 Pro's first start (2026-10-30) although nothing had leaked.
assert_isolated() { # mount-point fstype source-name
    if grep -q " - $2 $3 " "$DOCKER_INIT_MOUNTINFO" 2>/dev/null; then
        umount "$1" 2>/dev/null
        die "mount $1 leaked into the global namespace (could not make / private); aborted before touching Android"
    fi
}

clear_upper() {
    rm -rf "${DOCKER_OV:?}/upper" "${DOCKER_OV:?}/work"
}

try_overlay() {
    mkdir -p "$DOCKER_OV/upper" "$DOCKER_OV/work" &&
        mount -t overlay "$ROOT_OVERLAY_SRC" \
            -o "lowerdir=/,upperdir=$DOCKER_OV/upper,workdir=$DOCKER_OV/work" "$DOCKER_NEWROOT"
}

# Overlay of / on $DOCKER_NEWROOT. Upper on a tmpfs first (nothing persists, nothing on flash); if the
# kernel refuses that, the upper goes under $DOCKER_OV on /data (ext4/f2fs). Both refused: abort.
mount_root_overlay() {
    mkdir -p "$DOCKER_OV" "$DOCKER_NEWROOT" || die "cannot create $DOCKER_OV / $DOCKER_NEWROOT"
    clear_upper    # a crashed earlier start may have left a stale upper on /data; overlayfs rejects it
    if mount -t tmpfs -o "$OV_TMPFS_OPTS" "$OV_TMPFS_SRC" "$DOCKER_OV"; then
        assert_isolated "$DOCKER_OV" tmpfs "$OV_TMPFS_SRC"
        if try_overlay; then
            assert_isolated "$DOCKER_NEWROOT" overlay "$ROOT_OVERLAY_SRC"
            log "overlay of / mounted on $DOCKER_NEWROOT (upper on tmpfs)"
            return 0
        fi
        log "overlay refused with a tmpfs upper; retrying with the upper on $DOCKER_OV (data filesystem)"
        umount "$DOCKER_OV" 2>/dev/null
    else
        log "tmpfs for the overlay upper refused; using $DOCKER_OV on the data filesystem"
    fi
    clear_upper
    try_overlay || die "overlay root refused (lowerdir=/ with upper on tmpfs and on $DOCKER_OV); see: dmesg | grep -i overlay"
    assert_isolated "$DOCKER_NEWROOT" overlay "$ROOT_OVERLAY_SRC"
    log "overlay of / mounted on $DOCKER_NEWROOT (upper on $DOCKER_OV)"
}

# The paths dockerd, runc and libnetwork hardcode, created in the overlay's upper (never on /).
prepare_run_dirs() {
    mkdir -p "$DOCKER_NEWROOT/run" "$DOCKER_NEWROOT/tmp" "$DOCKER_NEWROOT/var" ||
        die "cannot create /run, /tmp, /var in the overlay root"
    chmod 755 "$DOCKER_NEWROOT/run"
    chmod 1777 "$DOCKER_NEWROOT/tmp"
    # Relative on purpose: the same link, and it also creates under the Git-bash test host.
    [ -e "$DOCKER_NEWROOT/var/run" ] || ln -s ../run "$DOCKER_NEWROOT/var/run" ||
        die "cannot link /var/run to /run in the overlay root"
}

# One visible mount point per line, parents before children, without "/" and without our own
# mounts (binding those into themselves would nest the view in itself). A mount point listed twice
# is stacked: only the top one is visible, so it is bound once. Escaped (\040) names are skipped.
mount_points() {
    awk -v nr="$DOCKER_NEWROOT" -v ov="$DOCKER_OV" '
        { mp[$5] = 1 }
        END {
            for (p in mp) {
                if (p == "/" || p ~ /\\/) continue
                if (p == nr || index(p, nr "/") == 1 || p == ov || index(p, ov "/") == 1) continue
                print p
            }
        }' "$SELF_MOUNTINFO" | LC_ALL=C sort
}

# Non-recursive bind of one mount point: the same mount (same filesystem, same ro/rw), nothing new
# is written; a missing target is created in the overlay's upper only.
bind_one() { # mount-point
    dst="$DOCKER_NEWROOT$1"
    if [ -d "$1" ]; then
        mkdir -p "$dst" || return 1
    else
        mkdir -p "$(dirname "$dst")" || return 1
        [ -e "$dst" ] || : >"$dst" || return 1
    fi
    mount --bind "$1" "$dst"
}

replicate_mounts() {
    list="$DOCKER_TMP/root-view-mounts.$$"
    mkdir -p "$DOCKER_TMP"
    mount_points >"$list"
    bound=0
    failed=
    while read -r mp; do
        if bind_one "$mp"; then
            bound=$((bound + 1))
        else
            log "WARNING bind of $mp failed"
            failed="$failed $mp"
        fi
    done <"$list"
    for req in $REQUIRED_MOUNTS; do
        grep -qxF "$req" "$list" || continue   # not a separate mount on this ROM
        case " $failed " in
            *" $req "*) rm -f "$list"; die "required mount $req could not be bound into the new root" ;;
        esac
    done
    rm -f "$list"
    log "bound $bound mounts into $DOCKER_NEWROOT"
}

build_root_view() {
    mount_root_overlay
    prepare_run_dirs
    replicate_mounts
}

# After the namespace is gone: the mount point and the upper dirs are plain, empty dirs in the global
# view; remove them. Never rm -rf the mount point itself - a live bind of /data in it would be followed.
clean_root_view() {
    rmdir "$DOCKER_NEWROOT" 2>/dev/null
    rm -rf "${DOCKER_OV:?}/upper" "${DOCKER_OV:?}/work"
    rmdir "$DOCKER_OV" 2>/dev/null
}

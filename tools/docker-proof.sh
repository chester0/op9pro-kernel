#!/system/bin/sh
# docker-proof.sh - one-screen proof that Docker works on the phone. Run ON the phone as root:
#   adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-proof.sh'"
# Needs dockerd up (docker-up.sh) and internet for the first image pull.
# Exit 0 = hello-world and an alpine container (with networking) both worked.

DIR=$(dirname "$0")
# shellcheck source=docker-common.sh
. "$DIR/docker-common.sh"

FAIL=0
PING_TARGET="${PROOF_PING_TARGET:-1.1.1.1}"

section() { say ""; say "== $*"; }

main() {
    require_root
    dockerd_pid >/dev/null || die "dockerd not running - run docker-up.sh first"

    section "host"
    say "uname: $(uname -srm)"
    say "network mode: $(cat "$DOCKER_MODE_FILE" 2>/dev/null)"

    section "docker info (summary)"
    docker info --format 'server {{.ServerVersion}} | driver {{.Driver}} | cgroup {{.CgroupDriver}} v{{.CgroupVersion}} | runc {{index .Runtimes "runc" "path"}} | cpus {{.NCPU}} | mem {{.MemTotal}}' ||
        { FAIL=1; say "docker info FAILED"; }

    section "hello-world"
    if docker run --rm hello-world 2>&1 | grep -m1 'Hello from Docker'; then
        say "hello-world: OK"
    else
        FAIL=1; say "hello-world: FAILED"
    fi

    section "alpine (uname + network)"
    net=bridge
    [ "$(cat "$DOCKER_MODE_FILE" 2>/dev/null)" = bridge ] || net=host
    if docker run --rm --network "$net" alpine sh -c "uname -srm; cat /etc/os-release | head -n1; ping -c 2 -W 3 $PING_TARGET"; then
        say "alpine ($net network): OK"
    else
        FAIL=1; say "alpine ($net network): FAILED"
    fi

    section "result"
    if [ "$FAIL" = 0 ]; then
        say "PROOF OK: Docker runs on $(uname -r)"
    else
        say "PROOF FAILED - send back: $DOCKER_DIAG and last 80 lines of $DOCKER_LOG"
        write_diag
        exit 1
    fi
}

main "$@"

#!/system/bin/sh
# testboot-lib.sh - sourced by testboot-baseline.sh and testboot-check.sh (runs ON the phone, as root).
# One place for "what do we measure about a running kernel", so the baseline (before) and the check
# (after the test boot) can never disagree about how a fact is collected.
# POSIX sh / mksh safe: no `local`, no arrays, no [[ ]]. Android has no awk, so none is used.
# Every path can be overridden through the environment (the tests use that).

# shellcheck disable=SC2034  # the variables below are used by the scripts that source this file
PROC_VERSION="${PROC_VERSION:-/proc/version}"
PROC_CONFIG="${PROC_CONFIG:-/proc/config.gz}"
KSUD_PATH="${KSUD_PATH:-/data/adb/ksud}"
WIFI_IF="${WIFI_IF:-wlan0}"
TESTBOOT_BASELINE_DIR="${TESTBOOT_BASELINE_DIR:-/data/local/tmp/testboot-baseline}"

# 2026-10-31: both thin builds (full and skip-ipvs) carry the same banner, "(thin@op9pro-thin)" and a
# "-dirty" suffix; the maintainer's build says "(runner@...)". The banner therefore proves "ours, not the
# maintainer's"; only CONFIG_IP_VS in /proc/config.gz tells the full build from the skip-ipvs one.
EXPECT_BANNER_MARK="${EXPECT_BANNER_MARK:-(thin@op9pro-thin)}"

# Docker's "Generally Necessary" kernel options, from moby contrib/check-config.sh (the copy pinned in
# thin/pins.env), without the IPVS match: that one is judged by EXPECT_IPVS because the skip-ipvs build
# leaves it out on purpose.
DOCKER_REQUIRED_OPTIONS="NAMESPACES NET_NS PID_NS IPC_NS UTS_NS CGROUPS CGROUP_CPUACCT CGROUP_DEVICE
CGROUP_FREEZER CGROUP_SCHED CPUSETS MEMCG KEYS VETH BRIDGE BRIDGE_NETFILTER IP_NF_FILTER IP_NF_MANGLE
IP_NF_TARGET_MASQUERADE IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_TARGET_MASQUERADE NETFILTER_XT_MATCH_ADDRTYPE
NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MARK IP_NF_RAW IP_NF_NAT NF_NAT IP6_NF_RAW IP6_NF_NAT POSIX_MQUEUE
CGROUP_BPF"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

require_root() {
    [ "$(id -u)" = "0" ] || die "must run as root (adb shell \"su -c 'sh $0'\")"
}

# wait_until SECONDS command... : polls every 3 s, returns 0 as soon as the command succeeds.
wait_until() {
    _limit=$1
    shift
    _waited=0
    while ! "$@"; do
        [ "$_waited" -ge "$_limit" ] && return 1
        sleep 3
        _waited=$((_waited + 3))
    done
    return 0
}

boot_completed() { [ "$(getprop sys.boot_completed)" = "1" ]; }

# Loaded module names, one per line, sorted (lsmod's header line dropped).
module_names() {
    lsmod 2>/dev/null | while read -r _name _rest; do
        [ "$_name" = "Module" ] || printf '%s\n' "$_name"
    done | sort
}

# The kernel log lines that mean "a module was refused": a CRC mismatch (MODVERSIONS) or a missing symbol.
modload_error_lines() {
    # -E with one pattern, not two -e: Git for Windows' grep 3.0 aborts on `-i -e A -e B`
    dmesg 2>/dev/null | grep -i -E 'disagrees about version|Unknown symbol'
}

# Counts the lines on stdin as a plain number (wc pads on some systems).
count_lines() {
    _n=$(wc -l)
    printf '%s\n' "$((_n + 0))"
}

# wlan0 has an IPv4 address and the framework or the supplicant says "connected".
wifi_associated() {
    ip -4 addr show "$WIFI_IF" 2>/dev/null | grep -q 'inet ' || return 1
    { cmd wifi status 2>/dev/null; dumpsys wifi 2>/dev/null; } |
        grep -q -e 'Wifi is connected to' -e 'Supplicant state: COMPLETED'
}

# Counts running processes whose name matches an extended regex. The [x] trick in the callers' patterns
# stops grep from matching its own command line in the process list.
proc_count() {
    # `ps -A -o NAME` lists names only: a full ps also prints the USER column, and the audio HAL runs as
    # user "audioserver". (pgrep is not used: Android's has no -c on every toybox.)
    # shellcheck disable=SC2009
    _n=$(ps -A -o NAME 2>/dev/null | grep -c -E "$1" || true)
    printf '%s\n' "$((_n + 0))"
}

# Prints the option names from DOCKER_REQUIRED_OPTIONS that the kernel config on stdin lacks.
config_missing() {
    _config=$(cat)
    for _opt in $DOCKER_REQUIRED_OPTIONS; do
        printf '%s\n' "$_config" | grep -q "^CONFIG_${_opt}=[ym]\$" || printf '%s ' "$_opt"
    done
}

read_config() { zcat "$PROC_CONFIG" 2>/dev/null; }

# Prints every fact as key=value, one per line.
collect_facts() {
    _modules=$(module_names | count_lines)
    _errors=$(modload_error_lines | count_lines)
    printf 'kernel_release=%s\n' "$(uname -r)"
    printf 'kernel_banner=%s\n' "$(cat "$PROC_VERSION")"
    printf 'lsmod_count=%s\n' "$_modules"
    printf 'modload_errors=%s\n' "$_errors"
    if wifi_associated; then printf 'wifi=associated\n'; else printf 'wifi=down\n'; fi
    printf 'audioserver_procs=%s\n' "$(proc_count '[a]udioserver')"
    printf 'audio_hal_procs=%s\n' "$(proc_count '[a]ndroid\.hardware\.audio|[v]endor\.qti\.hardware\.audio|[a]udio-hal')"
    printf 'root_uid=%s\n' "$(id -u)"
    if [ -x "$KSUD_PATH" ]; then printf 'ksud=present\n'; else printf 'ksud=missing\n'; fi
    _config=$(read_config)
    if [ -n "$_config" ]; then
        printf 'config_readable=1\n'
        printf 'docker_missing=%s\n' "$(printf '%s\n' "$_config" | config_missing)"
        if printf '%s\n' "$_config" | grep -q '^CONFIG_IP_VS=[ym]$'; then
            printf 'ip_vs=yes\n'
        else
            printf 'ip_vs=no\n'
        fi
        if printf '%s\n' "$_config" | grep -q '^CONFIG_NETFILTER_XT_MATCH_IPVS=[ym]$'; then
            printf 'ipvs_match=yes\n'
        else
            printf 'ipvs_match=no\n'
        fi
    else
        printf 'config_readable=0\n'
    fi
}

# get_fact FILE KEY [DEFAULT] : the value of KEY in a facts file.
get_fact() {
    _value=$(grep "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d= -f2-)
    if [ -n "$_value" ]; then printf '%s\n' "$_value"; else printf '%s\n' "${3:-}"; fi
}

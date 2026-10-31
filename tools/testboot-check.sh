#!/system/bin/sh
# testboot-check.sh - judges a test-booted kernel against the baseline (runs ON the phone, as root).
# Prints PASS / FAIL (and INFO) per line, then RESULT. Exit 0 only when nothing FAILed.
#
# Usage: adb -s <serial> shell "su -c 'sh /data/local/tmp/testboot-tools/testboot-check.sh [baseline_dir]'"
#   baseline_dir  default /data/local/tmp/testboot-baseline (written by testboot-baseline.sh)
# Environment:
#   EXPECT_IPVS=yes|no|any  yes for the full thin build (CONFIG_IP_VS=y), no for the skip-ipvs build,
#                           any (default) only reports it
#   BOOT_WAIT, WIFI_WAIT    seconds to wait for sys.boot_completed / Wi-Fi association (default 120 / 60)
#
# Read-only: it changes nothing on the phone.

# shellcheck source=/dev/null  # testboot-lib.sh is shellchecked on its own
. "$(dirname "$0")/testboot-lib.sh"

require_root
baseline_dir="${1:-$TESTBOOT_BASELINE_DIR}"
baseline="$baseline_dir/baseline.txt"
expect_ipvs="${EXPECT_IPVS:-any}"
passes=0
fails=0

pass() { passes=$((passes + 1)); say "PASS: $*"; }
fail() { fails=$((fails + 1)); say "FAIL: $*"; }
info() { say "INFO: $*"; }

# verdict NAME CONDITION-EXIT-CODE DETAIL
verdict() {
    if [ "$2" = "0" ]; then pass "$1: $3"; else fail "$1: $3"; fi
}

wait_until "${BOOT_WAIT:-120}" boot_completed || fail "boot: sys.boot_completed never became 1"
wait_until "${WIFI_WAIT:-60}" wifi_associated || true

now="${TMPDIR:-/data/local/tmp}/testboot-now.$$"
collect_facts >"$now" || die "could not collect facts"
trap 'rm -f "$now"' EXIT

if [ -r "$baseline" ]; then
    info "baseline: $baseline ($(get_fact "$baseline" kernel_release unknown))"
else
    fail "baseline: $baseline missing (run testboot-baseline.sh before the test boot); comparisons below are against zero"
fi

# 1. kernel version string is ours
banner=$(get_fact "$now" kernel_banner)
base_banner=$(get_fact "$baseline" kernel_banner)
info "kernel: $(get_fact "$now" kernel_release)"
case "$banner" in
    *"$EXPECT_BANNER_MARK"*) ours=0 ;;
    *) ours=1 ;;
esac
if [ -n "$base_banner" ] && [ "$banner" = "$base_banner" ]; then ours=1; fi
verdict "kernel banner is ours" "$ours" "needs $EXPECT_BANNER_MARK and must differ from the baseline's banner"

# 2. lsmod count against the baseline, and which modules are gone
now_count=$(get_fact "$now" lsmod_count 0)
base_count=$(get_fact "$baseline" lsmod_count 0)
if [ "$now_count" -ge "$base_count" ] && [ -r "$baseline" ]; then lsmod_ok=0; else lsmod_ok=1; fi
verdict "lsmod count" "$lsmod_ok" "$now_count loaded, baseline $base_count"
if [ -r "$baseline_dir/lsmod.txt" ]; then
    module_names >"$now.mods"
    gone=$(comm -23 "$baseline_dir/lsmod.txt" "$now.mods" | tr '\n' ' ')
    rm -f "$now.mods"
    [ -z "$gone" ] || info "modules in the baseline but not loaded now: $gone"
fi

# 3. module-load errors (MODVERSIONS refusals, missing symbols)
errors=$(get_fact "$now" modload_errors 0)
base_errors=$(get_fact "$baseline" modload_errors 0)
if [ "$errors" -le "$base_errors" ]; then errors_ok=0; else errors_ok=1; fi
verdict "module-load errors" "$errors_ok" "$errors in dmesg ('disagrees about version' / 'Unknown symbol'), baseline $base_errors"
if [ "$errors" -gt 0 ]; then
    modload_error_lines | sed -n '1,5p' | while read -r line; do info "dmesg: $line"; done
fi

# 4. Wi-Fi associated
if [ "$(get_fact "$now" wifi down)" = "associated" ]; then wifi_ok=0; else wifi_ok=1; fi
verdict "Wi-Fi associated" "$wifi_ok" "$(get_fact "$now" wifi down) (wlan0 needs an address and a connected supplicant)"

# 5. audio HAL running (not worse than the baseline; at least one audioserver process when there is no baseline)
audio_now=$(get_fact "$now" audio_hal_procs 0)
audio_base=$(get_fact "$baseline" audio_hal_procs 1)
server_now=$(get_fact "$now" audioserver_procs 0)
server_base=$(get_fact "$baseline" audioserver_procs 1)
if [ "$audio_now" -ge "$audio_base" ] && [ "$server_now" -ge "$server_base" ]; then audio_ok=0; else audio_ok=1; fi
verdict "audio HAL running" "$audio_ok" "HAL processes $audio_now (baseline $audio_base), audioserver $server_now (baseline $server_base)"

# 6. KernelSU root
root_ok=1
if [ "$(get_fact "$now" root_uid 1)" = "0" ] &&
    { [ "$(get_fact "$now" ksud missing)" = "present" ] || [ "$(get_fact "$baseline" ksud missing)" = "missing" ]; }; then
    root_ok=0
fi
verdict "KernelSU root" "$root_ok" "uid $(get_fact "$now" root_uid), ksud $(get_fact "$now" ksud missing) at $KSUD_PATH"

# 7. Docker kernel options
if [ "$(get_fact "$now" config_readable 0)" = "1" ]; then
    missing=$(get_fact "$now" docker_missing)
    if [ -z "$missing" ]; then docker_ok=0; else docker_ok=1; fi
    verdict "Docker check-config" "$docker_ok" "${missing:-every required option present}${missing:+ missing}"
else
    fail "Docker check-config: $PROC_CONFIG unreadable, so the options cannot be checked (use /proc/cgroups instead)"
fi

# 8. which build is this: IP_VS in the config
ip_vs=$(get_fact "$now" ip_vs unknown)
info "CONFIG_IP_VS=$ip_vs, IPVS match=$(get_fact "$now" ipvs_match unknown) (full thin build has both, skip-ipvs neither)"
case "$expect_ipvs" in
    yes) if [ "$ip_vs" = "yes" ]; then ipvs_ok=0; else ipvs_ok=1; fi; verdict "IP_VS matches the build under test" "$ipvs_ok" "expected yes, found $ip_vs" ;;
    no) if [ "$ip_vs" = "no" ]; then ipvs_ok=0; else ipvs_ok=1; fi; verdict "IP_VS matches the build under test" "$ipvs_ok" "expected no, found $ip_vs" ;;
    *) ;;
esac

total=$((passes + fails))
if [ "$fails" -eq 0 ]; then
    say "RESULT: PASS ($passes of $total)"
    exit 0
fi
say "RESULT: FAIL ($fails of $total failed)"
exit 1

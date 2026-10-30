#!/system/bin/sh
# testboot-baseline.sh - captures what the INSTALLED kernel looks like, before a test boot (runs ON the
# phone, as root). testboot-check.sh compares the test-booted kernel against these files.
#
# Usage: adb -s <serial> shell "su -c 'sh /data/local/tmp/testboot-tools/testboot-baseline.sh [dir]'"
#   dir  default /data/local/tmp/testboot-baseline (on /data, so it survives the test boot)
#
# Writes <dir>/baseline.txt (key=value facts), <dir>/lsmod.txt (module names) and
# <dir>/modload-errors.txt (the dmesg lines behind modload_errors). Read-only apart from those files.

# shellcheck source=/dev/null  # testboot-lib.sh is shellchecked on its own
. "$(dirname "$0")/testboot-lib.sh"

require_root
dir="${1:-$TESTBOOT_BASELINE_DIR}"
mkdir -p "$dir" || die "cannot create $dir"

collect_facts >"$dir/baseline.txt"
module_names >"$dir/lsmod.txt"
modload_error_lines >"$dir/modload-errors.txt"
# adb pull runs as the shell user
chmod -R a+rX "$dir"

say "baseline written to $dir:"
cat "$dir/baseline.txt"
if [ "$(get_fact "$dir/baseline.txt" audio_hal_procs 0)" = "0" ]; then
    say "WARNING: no audio HAL process matched; the audio check will pass vacuously. Look at: ps -A | grep -i audio"
fi
if [ "$(get_fact "$dir/baseline.txt" wifi down)" != "associated" ]; then
    say "WARNING: Wi-Fi is not associated now; the Wi-Fi check after the test boot expects it to be."
fi

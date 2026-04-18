#!/usr/bin/env python3
"""
Build a KSU/SukiSU module zip that applies SUSFS hiding rules at boot.

Drops files under /data/adb/modules/<id>/ via the standard Magisk/KSU module
installer. At post-fs-data (before zygote starts) the module calls
/data/adb/ksu/bin/ksu_susfs (installed by the manager on first SUSFS UI open)
to add sus paths, spoof uname, enable log spoofing, etc.

Flash it via SukiSU Manager -> Modules tab -> +.

Log written to /data/adb/susfs_config.log for debugging.
"""
import io
import zipfile
from pathlib import Path

MODULE_ID = "susfs_config_op9pro"

MODULE_PROP = f"""id={MODULE_ID}
name=SUSFS Config (OP9 Pro)
version=v3
versionCode=3
author=chester
description=Applies SUSFS sus_paths, uname spoof, log spoofing. Writes diag log to /data/local/tmp/susfs_config.log.
"""

# Use a minimal uname strip — just remove the "-dirty" suffix and the
# OEM-unique git hash. Matches the format /proc/version would have for a
# clean compile of the same source, so apps that correlate uname(release)
# with /proc/version see internal consistency.
SPOOF_RELEASE = "5.4.302-qgki"

# Body of the actual SUSFS config actions. Runs from both post-fs-data.sh
# (early) and service.sh (late) — the kernel dedupes; second call re-applies
# anything that didn't stick the first time.
COMMON_BODY = f"""SUSFS=/data/adb/ksu/bin/ksu_susfs
LOG=/data/local/tmp/susfs_config.log
STAGE="${{1:-unknown}}"

{{
echo ""
echo "=== {MODULE_ID} stage=$STAGE started $(date) ==="
echo "uname before: $(uname -r)"

if [ ! -f "$SUSFS" ]; then
    echo "FATAL: ksu_susfs binary not found at $SUSFS"
    echo "-> Open SukiSU Manager -> Settings -> SuSFS Configuration (just tap it once), then reboot."
    exit 0
fi

if [ ! -x "$SUSFS" ]; then
    echo "WARN: $SUSFS exists but not executable; chmod +x"
    chmod 755 "$SUSFS"
fi

echo "--- binary ls ---"
ls -la "$SUSFS"

# SHOW_VERSION command via ksud (not ksu_susfs). Just a sanity check that
# the kernel answers at all.
echo "--- ksud susfs version ---"
/data/adb/ksu/bin/ksud susfs version 2>&1 || echo "(ksud call failed)"

echo ""
echo "--- enable_log ---"
"$SUSFS" enable_log 1 2>&1
rc=$?; echo "rc=$rc"

echo ""
echo "--- hide_sus_mnts_for_non_su_procs ---"
"$SUSFS" hide_sus_mnts_for_non_su_procs 1 2>&1
rc=$?; echo "rc=$rc"

echo ""
echo "--- sus paths ---"
for P in /data/adb /data/adb/ksu /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d /sbin/.magisk /debug_ramdisk ; do
    out=$("$SUSFS" add_sus_path "$P" 2>&1)
    echo "  add_sus_path $P -> rc=$? out=$out"
done

echo ""
echo "--- set_uname ---"
# Two-arg form: release, then buildtime. "default" for buildtime keeps
# OEM value. Providing a literal release string with no "-dirty" suffix
# and no chester@op9build build-id.
out=$("$SUSFS" set_uname '{SPOOF_RELEASE}' 'default' 2>&1)
echo "  set_uname '{SPOOF_RELEASE}' 'default' -> rc=$? out=$out"

echo ""
echo "--- enable_avc_log_spoofing ---"
"$SUSFS" enable_avc_log_spoofing 1 2>&1
rc=$?; echo "rc=$rc"

echo ""
echo "uname after: $(uname -r)"
echo "=== {MODULE_ID} stage=$STAGE done $(date) ==="
}} >> "$LOG" 2>&1
chmod 644 "$LOG" 2>/dev/null
"""

POST_FS_DATA_SH = f"""#!/system/bin/sh
# SUSFS config — early stage (before zygote)
{COMMON_BODY.replace('"${1:-unknown}"', '"post-fs-data"')}
"""

SERVICE_SH = f"""#!/system/bin/sh
# SUSFS config — late stage (after system_server). Safety net in case
# post-fs-data stage runs before ksu_susfs binary is ready.
sleep 15
{COMMON_BODY.replace('"${1:-unknown}"', '"service"')}
"""

# Standard Magisk/KSU module installer. The shebang line with '#MAGISK' on
# the second line is the convention that tells the installer this is a
# module zip. The installer script extracts to MODPATH.
UPDATE_BINARY = """#!/sbin/sh

#################
# Initialization
#################

umask 022

# echo before loading util_functions
ui_print() { echo "$1"; }

require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk/KSU v20.4+ "
  ui_print "*******************************"
  exit 1
}

#########################
# Load util_functions.sh
#########################

OUTFD=$2
ZIPFILE=$3

mount /data 2>/dev/null

[ -f /data/adb/magisk/util_functions.sh ] || [ -f /data/adb/ksu/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh 2>/dev/null || . /data/adb/ksu/util_functions.sh 2>/dev/null

install_module
exit 0
"""

UPDATER_SCRIPT = "#MAGISK\n"


def make_zip(out_path: Path) -> None:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("module.prop", MODULE_PROP)
        z.writestr("post-fs-data.sh", POST_FS_DATA_SH)
        z.writestr("service.sh", SERVICE_SH)
        z.writestr("META-INF/com/google/android/update-binary", UPDATE_BINARY)
        z.writestr("META-INF/com/google/android/updater-script", UPDATER_SCRIPT)
    out_path.write_bytes(buf.getvalue())


if __name__ == "__main__":
    out = Path("C:/000CHESTA-CODE/op9pro-kernel/output/susfs_config_op9pro.zip")
    out.parent.mkdir(parents=True, exist_ok=True)
    make_zip(out)
    print(f"wrote {out} ({out.stat().st_size} bytes)")

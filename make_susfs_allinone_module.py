#!/usr/bin/env python3
"""
Build a single consolidated SUSFS module that:

1. Ships the ksu_susfs binary bundled in the zip (extracted from
   SukiSU APK's assets/ksu_susfs_2.0.0, which is actually a 2.1.0-capable
   binary — the APK mislabels the filename).
2. At post-fs-data, drops the binary to /data/adb/ksu/bin/ksu_susfs
   (chown root:root, chmod 755) and applies SUSFS config via direct
   invocation — we're already in init's root context, so no libsu shell
   redirection through /system/bin/su.
3. At service (post-boot), re-applies anything that didn't stick in
   post-fs-data (kernel dedupes; second pass is harmless).

Why one module instead of two:
- The previous `ksu_susfs_binary_drop` used `exit 1` in update-binary to
  avoid being a persistent module. SukiSU's installer sometimes treats
  that as install failure and discards module dir content. Result: the
  binary never lands at /data/adb/ksu/bin/ksu_susfs.
- The previous `susfs_config_op9pro` had a FATAL check for that binary,
  so it would bail with "ksu_susfs binary not found" if drop failed.
- Merging them means a single install, a single exit 0, and a
  self-contained payload: we no longer depend on the manager's
  ensureBinaryAvailable() path at all.

Why post-fs-data (not just service):
- post-fs-data runs BEFORE zygote spawns. Sus paths applied at
  service.sh would already be too late for the zygote-spawned processes'
  mount namespace snapshot, which is what app-layer path-visibility
  queries typically read from.

Log at /data/local/tmp/susfs_allinone.log (world-readable).
"""
import io
import zipfile
from pathlib import Path

APK = Path("C:/000CHESTA-CODE/op9pro-kernel/sukisu_apk_check/base.apk")
OUT = Path("C:/000CHESTA-CODE/op9pro-kernel/output/susfs_allinone.zip")

MODULE_ID = "susfs_allinone_op9pro"

MODULE_PROP = f"""id={MODULE_ID}
name=SUSFS AllInOne (OP9 Pro)
version=v2
versionCode=2
author=chester
description=Drops ksu_susfs binary + applies SUSFS hiding rules at boot. Self-contained (no manager Apply needed). Log: /data/local/tmp/susfs_allinone.log
"""

SPOOF_RELEASE = "5.4.302-qgki"

COMMON_BODY = f"""
MODDIR=${{0%/*}}
BIN_SRC="$MODDIR/ksu_susfs"
BIN_DST=/data/adb/ksu/bin/ksu_susfs
LOG=/data/local/tmp/susfs_allinone.log
STAGE="${{1:-unknown}}"

{{
echo ""
echo "=== {MODULE_ID} stage=$STAGE started $(date) ==="
echo "MODDIR=$MODDIR"
echo "uid=$(id -u) euid=$(id -g) caller=$(cat /proc/$$/status | grep Uid)"
echo "uname before: $(uname -r)"

# Drop binary to canonical location
if [ ! -f "$BIN_SRC" ]; then
    echo "FATAL: bundled ksu_susfs not found at $BIN_SRC (module unpack broken?)"
    exit 0
fi

mkdir -p /data/adb/ksu/bin
cp -f "$BIN_SRC" "$BIN_DST"
chown 0:0 "$BIN_DST" 2>/dev/null
chmod 755 "$BIN_DST"
echo "dropped binary: $(ls -la $BIN_DST)"

SUSFS="$BIN_DST"

# Also keep a world-readable copy for diagnostics.
cp -f "$BIN_SRC" /data/local/tmp/ksu_susfs 2>/dev/null
chmod 755 /data/local/tmp/ksu_susfs 2>/dev/null

echo "--- sanity: show version ---"
"$SUSFS" show version 2>&1
echo "rc=$?"

echo ""
echo "--- enable_log ---"
"$SUSFS" enable_log 1 2>&1
echo "rc=$?"

echo ""
echo "--- hide_sus_mnts_for_non_su_procs ---"
"$SUSFS" hide_sus_mnts_for_non_su_procs 1 2>&1
echo "rc=$?"

echo ""
echo "--- sus paths ---"
# Core KSU/Magisk roots
CORE_PATHS="/data/adb /data/adb/ksu /data/adb/ksud /data/adb/modules /data/adb/modules_update /data/adb/post-fs-data.d /data/adb/service.d /sbin/.magisk /debug_ramdisk /apex/com.android.runtime/bin/dex2oat"

# Module dirs (will skip w/ rc=2 if a module isn't installed — harmless)
MODULE_NAMES="susfs_allinone_op9pro tricky_store playintegrityfix playintegrityfork playintegritynext zygisksu rezygisk shamiko treat_wheel treatwheel bindhosts blindhosts zygisk-detach zygisk_detach detach busybox-ndk busybox yukinei_manager yuri_key_manager"
MODULE_PATHS=""
for m in $MODULE_NAMES ; do
    MODULE_PATHS="$MODULE_PATHS /data/adb/modules/$m /data/adb/modules_update/$m"
done

for P in $CORE_PATHS $MODULE_PATHS ; do
    out=$("$SUSFS" add_sus_path "$P" 2>&1)
    rc=$?
    # Only log successes and real errors; silence the rc=2 "not installed" noise
    if [ $rc -eq 0 ]; then
        echo "  [ok] $P"
    elif [ $rc -eq 2 ]; then
        :
    else
        echo "  [rc=$rc] $P -> $out"
    fi
done

echo ""
echo "--- set_uname ---"
out=$("$SUSFS" set_uname '{SPOOF_RELEASE}' 'default' 2>&1)
echo "  set_uname '{SPOOF_RELEASE}' 'default' -> rc=$? out=$out"

echo ""
echo "--- enable_avc_log_spoofing ---"
"$SUSFS" enable_avc_log_spoofing 1 2>&1
echo "rc=$?"

echo ""
echo "uname after: $(uname -r)"
echo "=== {MODULE_ID} stage=$STAGE done $(date) ==="
}} >> "$LOG" 2>&1
chmod 644 "$LOG" 2>/dev/null
"""

POST_FS_DATA_SH = f"""#!/system/bin/sh
# SUSFS AllInOne — early stage (before zygote)
set +e
STAGE=post-fs-data
{COMMON_BODY}
"""

SERVICE_SH = f"""#!/system/bin/sh
# SUSFS AllInOne — late stage, safety net
set +e
sleep 15
STAGE=service
{COMMON_BODY}
"""

UPDATE_BINARY = """#!/sbin/sh

#################
# Initialization
#################

umask 022

ui_print() { echo "$1"; }

require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk/KSU v20.4+ "
  ui_print "*******************************"
  exit 1
}

OUTFD=$2
ZIPFILE=$3

mount /data 2>/dev/null

[ -f /data/adb/magisk/util_functions.sh ] || [ -f /data/adb/ksu/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh 2>/dev/null || . /data/adb/ksu/util_functions.sh 2>/dev/null

install_module
exit 0
"""

UPDATER_SCRIPT = "#MAGISK\n"


def main() -> None:
    # Pull the ksu_susfs binary out of the SukiSU APK.
    with zipfile.ZipFile(APK) as apk:
        binary = apk.read("assets/ksu_susfs_2.0.0")
    print(f"extracted ksu_susfs: {len(binary)} bytes")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        # Store the binary uncompressed — it's already small.
        zi = zipfile.ZipInfo("ksu_susfs")
        zi.compress_type = zipfile.ZIP_STORED
        # 0755 + regular file
        zi.external_attr = (0o100755 << 16)
        z.writestr(zi, binary)
        z.writestr("module.prop", MODULE_PROP)
        z.writestr("post-fs-data.sh", POST_FS_DATA_SH)
        z.writestr("service.sh", SERVICE_SH)
        z.writestr("META-INF/com/google/android/update-binary", UPDATE_BINARY)
        z.writestr("META-INF/com/google/android/updater-script", UPDATER_SCRIPT)
    OUT.write_bytes(buf.getvalue())
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

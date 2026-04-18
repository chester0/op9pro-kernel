#!/usr/bin/env python3
"""
Build a one-shot KSU "module" zip whose real purpose is to drop the
`ksu_susfs` 2.1.0 binary into /data/adb/ksu/bin/ during flash.

Why this hack:
- SukiSU-Ultra manager v4.1.2's APK only ships assets/ksu_susfs_2.0.0.
- Our kernel advertises SUSFS_VERSION = v2.1.0.
- Manager code tries to open assets/ksu_susfs_2.1.0 on demand → FileNotFound
  → entire SuSFS config UI fails.
- But: the 2.0.0-named asset IS actually a 2.1.0-capable binary (verified
  by strings: add_sus_path_loop, add_sus_map, add_sus_kstat_statically,
  enable_avc_log_spoofing, add_open_redirect are all present).

Since the manager hardcodes allowed signature hashes, we can't re-sign the
APK. Instead: extract the binary, ship it in a module zip whose
`update-binary` runs as root during flash (ksud-independent path), and
drop it at the expected location. Manager's `File(...).exists()` check
then skips its broken asset-copy routine and just executes the binary.

Not a "real" module — leaves no persistent module entry (we exit 1 at the
end so the manager's install_module side-effect is suppressed). Just a
payload delivery vehicle.
"""
import io
import zipfile
from pathlib import Path

APK = Path("C:/000CHESTA-CODE/op9pro-kernel/sukisu_apk_check/base.apk")
OUT = Path("C:/000CHESTA-CODE/op9pro-kernel/output/ksu_susfs_binary_drop.zip")

UPDATE_BINARY = r"""#!/sbin/sh
umask 022
OUTFD=$2
ZIPFILE=$3

ui_print() { echo "$1" >&$OUTFD; }

ui_print "-----------------------------------"
ui_print " ksu_susfs 2.1.0 binary dropper"
ui_print "-----------------------------------"

mount /data 2>/dev/null

mkdir -p /data/adb/ksu/bin

ui_print "- Extracting ksu_susfs payload"
unzip -o "$ZIPFILE" ksu_susfs -d /data/adb/ksu/bin/ >/dev/null 2>&1 || {
    ui_print "!! unzip failed"; exit 1; }

chmod 755 /data/adb/ksu/bin/ksu_susfs
chown root:root /data/adb/ksu/bin/ksu_susfs 2>/dev/null

ui_print "- Verifying binary"
if [ -x /data/adb/ksu/bin/ksu_susfs ]; then
    SIZE=$(wc -c < /data/adb/ksu/bin/ksu_susfs)
    ui_print "  size=${SIZE} bytes"
    /data/adb/ksu/bin/ksu_susfs show_version >/data/local/tmp/ksu_susfs_dropcheck.log 2>&1 || true
    ui_print "  sanity call logged to /data/local/tmp/ksu_susfs_dropcheck.log"
else
    ui_print "!! binary not executable"
    exit 1
fi

ui_print ""
ui_print "- Done. Next steps:"
ui_print "  1. Close this dialog (do NOT reboot — no need)"
ui_print "  2. Open SukiSU Ultra Manager"
ui_print "  3. Settings -> SuSFS Configuration"
ui_print "  4. Apply your settings"
ui_print ""

# Exit 1 so the manager doesn't treat this as a persistent module install.
# (The binary is already in place; no /data/adb/modules/ entry needed.)
exit 1
"""

UPDATER_SCRIPT = "#MAGISK\n"

MODULE_PROP = """id=ksu_susfs_binary_drop
name=ksu_susfs 2.1.0 Binary Dropper
version=v1
versionCode=1
author=chester
description=One-shot installer: drops /data/adb/ksu/bin/ksu_susfs. Not a persistent module.
"""


def main() -> None:
    # Extract ksu_susfs_2.0.0 from SukiSU APK
    with zipfile.ZipFile(APK) as apk:
        binary = apk.read("assets/ksu_susfs_2.0.0")
    print(f"extracted ksu_susfs binary: {len(binary)} bytes")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        # The binary itself (named `ksu_susfs` at zip root for unzip -o in
        # update-binary to extract cleanly)
        zi = zipfile.ZipInfo("ksu_susfs")
        zi.compress_type = zipfile.ZIP_STORED
        z.writestr(zi, binary)
        # Installer scaffolding
        z.writestr("module.prop", MODULE_PROP)
        z.writestr("META-INF/com/google/android/update-binary", UPDATE_BINARY)
        z.writestr("META-INF/com/google/android/updater-script", UPDATER_SCRIPT)
    OUT.write_bytes(buf.getvalue())
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

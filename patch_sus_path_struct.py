#!/usr/bin/env python3
"""
Rewrite kernel3's `struct st_susfs_sus_path` to match the v2.0.0 binary's
on-the-wire layout.

Root cause (v13 diagnosis)
--------------------------
The `ksu_susfs` binary bundled in SukiSU Manager APK (assets/ksu_susfs_2.0.0)
uses a sentinel-value hack to detect kernel support:

    struct.err = 0x7e (126)        # sentinel
    syscall(reboot, MAGIC1, SUSFS_MAGIC, CMD, &struct)
    if struct.err == 0x7e:
        print "SUSFS operation not supported, please enable it in kernel"

For CMD_SUSFS_ADD_SUS_PATH (0x55550), the binary expects err at offset 268:

    Binary's struct layout (v2.0.0):
        0..7    unsigned long target_ino
        8..263  char target_pathname[256]
        264..267 unsigned int i_uid
        268..271 int err                    ← sentinel here

Our kernel3 (SUSFS 2.1.0 API-ported) has:

    struct st_susfs_sus_path {
        char target_pathname[256];
        int err;
    };
    // err at offset 256

So the kernel writes err to offset 256; binary reads sentinel from offset 268;
sentinel survives; binary prints "not supported".

Meanwhile set_uname, enable_log, hide_sus_mnts, enable_avc_log_spoofing all
work because their struct layouts happen to match between v2.0.0 binary and
v2.1.0 kernel (verified by disassembly).

Fix
---
Reorder `st_susfs_sus_path` to match v2.0.0 layout. `susfs_add_sus_path`
only reads `target_pathname` and writes `err` — the compiler re-resolves
member offsets automatically; no code change in susfs.c is needed.

`target_ino` and `i_uid` become unused padding (binary may or may not populate
them; kernel ignores them — they exist only to align err at offset 268).

Also fix `susfs_add_sus_path_loop` which shares this struct.

Idempotent.
"""
from pathlib import Path

SUSFS_H = Path("/work/kernel3/include/linux/susfs.h")

OLD = """struct st_susfs_sus_path {
\tchar                                    target_pathname[SUSFS_MAX_LEN_PATHNAME];
\tint                                     err;
};"""

NEW = """struct st_susfs_sus_path {
\tunsigned long                           target_ino;
\tchar                                    target_pathname[SUSFS_MAX_LEN_PATHNAME];
\tunsigned int                            i_uid;
\tint                                     err;
};"""

MARKER = "unsigned long                           target_ino;\n\tchar                                    target_pathname[SUSFS_MAX_LEN_PATHNAME];\n\tunsigned int                            i_uid;"


def main() -> None:
    text = SUSFS_H.read_text()
    if MARKER in text:
        print(f"SKIP: st_susfs_sus_path already has v2.0.0 layout in {SUSFS_H}")
        return
    if OLD not in text:
        raise SystemExit(
            f"ERROR: expected old st_susfs_sus_path definition in {SUSFS_H} "
            "(tree may have diverged; inspect include/linux/susfs.h manually)"
        )
    text = text.replace(OLD, NEW, 1)
    SUSFS_H.write_text(text)
    print(f"OK: rewrote st_susfs_sus_path to v2.0.0 layout in {SUSFS_H}")


if __name__ == "__main__":
    main()

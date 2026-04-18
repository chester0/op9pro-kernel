#!/usr/bin/env python3
"""
Patch the SUSFS version string from "v2.1.0" to "v2.0.0".

Rationale
---------
SukiSU-Ultra Manager v4.1.2 ships only `assets/ksu_susfs_2.0.0` in its APK
(no 2.1.0 asset). Its SuSFSManager class queries the kernel's
SUSFS_SHOW_VERSION supercall, strips the leading "v", and opens
`assets/ksu_susfs_${v}` to copy into /data/adb/ksu/bin/ksu_susfs before
every command.

Our kernel reports "v2.1.0" → manager tries assets/ksu_susfs_2.1.0 →
FileNotFoundException → every add_sus_path / set_uname / enable_log call
aborts before it starts. The SuSFS Configuration UI is visible but
nothing persists.

Reporting "v2.0.0" makes the manager pick the shipped asset. The binary
itself IS 2.1.0-capable — strings confirm it exposes add_sus_path_loop,
add_sus_map, add_sus_kstat_statically, enable_avc_log_spoofing, and
add_open_redirect. The filename in the APK is mislabeled; the binary
content is fine.

The kernel's actual feature set is unchanged — we only change what it
TELLS userspace. All 2.1.0 CMD codes keep dispatching correctly in
supercalls.c.

Idempotent.
"""
from pathlib import Path

SUSFS_H = Path("/work/kernel3/include/linux/susfs.h")


def main() -> None:
    text = SUSFS_H.read_text()

    old = '#define SUSFS_VERSION "v2.1.0"'
    new = '#define SUSFS_VERSION "v2.0.0"'

    if new in text:
        print(f"SKIP: {SUSFS_H} already reports v2.0.0")
        return
    if old not in text:
        raise SystemExit(
            f"ERROR: expected '{old}' in {SUSFS_H} — tree may have diverged"
        )

    text = text.replace(old, new, 1)
    SUSFS_H.write_text(text)
    print(f"OK: patched SUSFS_VERSION v2.1.0 -> v2.0.0 in {SUSFS_H}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Add lazy manager-appid discovery inside ksu_handle_setresuid().

Problem
-------
v5 boot confirmed that pkg_observer's fsnotify watch on /data/system fails
at device_initcall time:
  KernelSU: path not ready: /data/system (-2)   (-ENOENT)

/data is mounted by init in userspace AFTER all kernel initcalls run, so
the watch attachment never retries. This means `track_throne()` is never
called, `ksu_is_manager_appid_valid()` stays false, and the
manager-UID-match branch inside `ksu_handle_setresuid` never fires — so
the seccomp cache is never primed for __NR_reboot, so libksud.so keeps
dying with SIGSYS, so manager keeps saying "unsupported".

Fix
---
Inside `ksu_handle_setresuid` in drivers/kernelsu/setuid_hook.c, after the
zygote-SID check succeeds but BEFORE the manager-appid-match branch, add:

    if (unlikely(!ksu_is_manager_appid_valid())) {
        track_throne(false);
    }

track_throne() reads /data/system/packages.list synchronously and updates
the internal manager appid if a signature match is found. It's safe to
call from a zygote setresuid context (file I/O is fine to sleep there).
Once the appid is discovered, ksu_is_manager_appid_valid() returns true
and this branch becomes a cheap no-op on every subsequent fork.

There's a small bootstrap window where zygote forks apps BEFORE
PackageManagerService has written packages.list — track_throne() logs
and returns harmlessly in that case ("open failed: -2"). We keep calling
it on each fork until it succeeds.

Idempotent.
"""
import re
from pathlib import Path

SETUID = Path("/work/kernel3/drivers/kernelsu/setuid_hook.c")

MARKER = "track_throne(false); /* lazy manager-appid discovery */"

ANCHOR = """	// We only interest in process spwaned by zygote
	if (!susfs_is_sid_equal(current_cred(), susfs_zygote_sid)) {
		return 0;
	}
"""

REPLACEMENT = """	// We only interest in process spwaned by zygote
	if (!susfs_is_sid_equal(current_cred(), susfs_zygote_sid)) {
		return 0;
	}

	// pkg_observer's fsnotify watch on /data/system fails at
	// device_initcall (path not yet mounted). Without it, track_throne()
	// is never called, manager appid stays unknown, and the manager-match
	// branch below never fires. Lazy fallback: re-scan packages.list on
	// every zygote fork until the manager is discovered; cheap no-op after.
	if (unlikely(!ksu_is_manager_appid_valid())) {
		track_throne(false); /* lazy manager-appid discovery */
	}
"""


def main() -> None:
    text = SETUID.read_text()
    if MARKER in text:
        print(f"SKIP: lazy track_throne already present in {SETUID}")
        return
    if ANCHOR not in text:
        raise SystemExit(f"ERROR: anchor not found in {SETUID}")
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    SETUID.write_text(text)
    print(f"OK: inserted lazy track_throne fallback into {SETUID}")


if __name__ == "__main__":
    main()

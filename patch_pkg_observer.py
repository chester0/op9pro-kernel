#!/usr/bin/env python3
"""
Enable pkg_observer.c to provide manager-appid discovery under
CONFIG_KSU_SUSFS on Matrixx kernel3.

Problem
-------
Under CONFIG_KSU_SUSFS, SukiSU-Ultra 4.1.2 disables both the
`task_fix_setuid` and `inode_rename` LSM hooks (see
drivers/kernelsu/lsm_hook.c ~L111 — guarded by !defined(CONFIG_KSU_SUSFS)).

Without `inode_rename`, the driver has no fsnotify-free way to detect when
Android's PackageManager atomically replaces /data/system/packages.list.
That replacement is how `track_throne()` discovers the SukiSU Manager's
UID. Without it, `ksu_handle_setresuid()` fires on every zygote fork but
the manager-UID match never succeeds, so libksud.so's __NR_reboot stays
blocked by the app seccomp filter → SIGSYS → "driver unsupported".

`pkg_observer.c` ships in SukiSU-Ultra 4.1.2 and implements an
fsnotify-based watcher on /data/system that calls track_throne(false) on
packages.list events. In Matrixx kernel3, shim.c uses a "unity build"
pattern — it `#include`s pkg_observer.c directly when CONFIG_KSU_SUSFS is
set, so the `ksu_observer_init`/`ksu_observer_exit` symbols already exist
in shim.o. What's missing is the actual init call from kernelsu_init().

The exit side IS wired (ksuinit.c kernelsu_exit() calls ksu_observer_exit
under the same #if guard), but the init call was simply forgotten —
likely because in upstream, the call lives elsewhere and kernel3 dropped
it during merging.

What it does
------------
Adds `ksu_observer_init()` call into kernelsu_init() in ksuinit.c under
the same #if guard the existing exit uses.

Do NOT add pkg_observer.o to Kbuild — it would duplicate symbols already
compiled via shim.c's unity-build #include.

Idempotent — re-running is safe.
"""
import re
from pathlib import Path

KSUINIT = Path("/work/kernel3/drivers/kernelsu/ksuinit.c")

INIT_MARKER = "ksu_observer_init();"
INIT_ANCHOR = """	ksu_throne_tracker_init();
"""
INIT_REPLACEMENT = """	ksu_throne_tracker_init();

#if defined(CONFIG_KSU_SYSCALL_HOOK) || defined(CONFIG_KSU_SUSFS) ||           \\
	(LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0) &&                      \\
	 defined(CONFIG_KSU_MANUAL_HOOK))
	{
		extern int ksu_observer_init(void);
		ksu_observer_init();
	}
#endif
"""


def patch_ksuinit() -> None:
    text = KSUINIT.read_text()
    if INIT_MARKER in text:
        print(f"SKIP: ksu_observer_init() already in ksuinit.c")
        return
    if INIT_ANCHOR not in text:
        raise SystemExit(f"ERROR: anchor not found in {KSUINIT}")
    text = text.replace(INIT_ANCHOR, INIT_REPLACEMENT, 1)
    KSUINIT.write_text(text)
    print(f"OK: inserted ksu_observer_init() into {KSUINIT}")


if __name__ == "__main__":
    patch_ksuinit()

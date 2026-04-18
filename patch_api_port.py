#!/usr/bin/env python3
"""
Port kernel3 (Matrixx) SUSFS integration call sites from OLD API to NEW API (SUSFS 2.1.0).

OLD API:
  inode->i_state & INODE_STATE_SUS_PATH
  inode->i_state & INODE_STATE_SUS_KSTAT
  current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC

NEW API:
  inode->i_mapping->flags & BIT_SUS_PATH      (where BIT_SUS_PATH = BIT(33))
  inode->i_mapping->flags & BIT_SUS_KSTAT     (where BIT_SUS_KSTAT = BIT(35))
  susfs_is_current_proc_umounted_app()        (inline helper in susfs_def.h)

The OLD storage (inode->i_state bit flags + task_struct->susfs_task_state) was moved to
address_space->flags + thread_info->flags in SUSFS 2.1.0. This script patches all call
sites surgically while leaving oplus drivers, SUSFS implementation, etc. untouched.

Idempotent: safe to re-run.
"""
import sys
from pathlib import Path

KERNEL = Path("/work/kernel3")

# Files that use the old API (discovered via grep)
TARGET_FILES = [
    "fs/namei.c",
    "fs/stat.c",
    "fs/proc/fd.c",
    "fs/proc/task_mmu.c",
    "fs/notify/fdinfo.c",
    "fs/dcache.c",
    "fs/readdir.c",
    "fs/statfs.c",
    "fs/namespace.c",
    "fs/proc_namespace.c",
]

# Literal string replacements — order matters: longer keys must come before shorter prefixes.
REPLACEMENTS = [
    ("->i_state & INODE_STATE_SUS_PATH",
     "->i_mapping->flags & BIT_SUS_PATH"),
    ("->i_state & INODE_STATE_SUS_KSTAT",
     "->i_mapping->flags & BIT_SUS_KSTAT"),
    ("->i_state & INODE_STATE_SUS_MOUNT",
     "->i_mapping->flags & BIT_SUS_MOUNT"),
    ("->i_state & INODE_STATE_OPEN_REDIRECT",
     "->i_mapping->flags & BIT_OPEN_REDIRECT"),
    ("current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC",
     "susfs_is_current_proc_umounted_app()"),
    # Longer first — avoid corrupting prefix-sharing symbol below.
    ("DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE",
     "DEFAULT_KSU_MNT_ID_FOR_KSU_PROC_UNSHARE"),
    ("DEFAULT_SUS_MNT_ID",
     "DEFAULT_KSU_MNT_ID"),
]

# Add BIT_ convenience macros to susfs_def.h right after the AS_FLAGS_ block.
HEADER_PATH = KERNEL / "include/linux/susfs_def.h"
HEADER_ANCHOR = "#define AS_FLAGS_SUS_MAP 39"
HEADER_INSERT = """#define AS_FLAGS_SUS_MAP 39

/* Convenience bit masks for inode->i_mapping->flags tests (SUSFS 2.1.0 call-site port) */
#define BIT_SUS_PATH BIT(AS_FLAGS_SUS_PATH)
#define BIT_SUS_MOUNT BIT(AS_FLAGS_SUS_MOUNT)
#define BIT_SUS_KSTAT BIT(AS_FLAGS_SUS_KSTAT)
#define BIT_OPEN_REDIRECT BIT(AS_FLAGS_OPEN_REDIRECT)
#define BIT_SUS_MAP BIT(AS_FLAGS_SUS_MAP)

/* SUSFS 2.1.0 mount-id sentinels (renamed from DEFAULT_SUS_MNT_ID_*) */
#define DEFAULT_KSU_MNT_ID_FOR_KSU_PROC_UNSHARE 1000000"""


def patch_header():
    text = HEADER_PATH.read_text()
    if "BIT_SUS_PATH" in text:
        print(f"SKIP header: BIT_SUS_* already defined in {HEADER_PATH}")
        return
    if HEADER_ANCHOR not in text:
        print(f"ERROR: anchor '{HEADER_ANCHOR}' not in {HEADER_PATH}")
        sys.exit(1)
    text = text.replace(HEADER_ANCHOR, HEADER_INSERT, 1)
    HEADER_PATH.write_text(text)
    print(f"OK: added BIT_SUS_* macros to {HEADER_PATH}")


def patch_file(rel):
    path = KERNEL / rel
    text = path.read_text()
    total = 0
    for old, new in REPLACEMENTS:
        count = text.count(old)
        if count:
            text = text.replace(old, new)
            total += count
            print(f"  {rel}: {count} x '{old[:40]}...'")
    if total:
        path.write_text(text)
        print(f"OK: {rel} — {total} replacements")
    else:
        print(f"SKIP: {rel} — nothing to replace (already ported?)")


def main():
    patch_header()
    for f in TARGET_FILES:
        patch_file(f)
    print("\n=== DONE — verifying no OLD API symbols remain ===")
    import subprocess
    r = subprocess.run(
        ["grep", "-rnE",
         "INODE_STATE_(SUS_|OPEN_REDIRECT)|TASK_STRUCT_NON_ROOT_USER_APP_PROC|DEFAULT_SUS_MNT_ID|SUS_MNT_ID_FOR_KSU",
         str(KERNEL / "fs"), str(KERNEL / "include")],
        capture_output=True, text=True
    )
    hits = [l for l in r.stdout.splitlines() if l.strip()]
    if hits:
        print(f"WARN: {len(hits)} residual old-API references:")
        for h in hits[:10]:
            print(f"  {h}")
    else:
        print("CLEAN: no old-API symbols remain in fs/ or include/")


if __name__ == "__main__":
    main()

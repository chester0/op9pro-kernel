#!/usr/bin/env python3
"""
Append SUSFS 2.1.0 new-API helper function implementations to kernel3's fs/susfs.c.

The call-site port (patch_api_port.py) rewrote tests like
    inode->i_state & INODE_STATE_SUS_KSTAT
to
    inode->i_mapping->flags & BIT_SUS_KSTAT
but also replaced inline spoofing code with function calls that SUSFS 2.1.0
expects the core to provide:

  susfs_sus_ino_for_generic_fillattr(ino, kstat)   # spoof all stat fields
  susfs_sus_ino_for_show_map_vma(ino, *dev, *ino)  # spoof dev+ino only
  susfs_sus_ino_for_filldir64(ino) -> int          # 1 if ino should be hidden
  susfs_get_redirected_path(ino) -> filename*      # redirect target

kernel3 already has the backing hashtables (SUS_KSTAT_HLIST, OPEN_REDIRECT_HLIST)
and entry structs — we just wire the helpers on top.

Note: kernel3's struct st_susfs_open_redirect_hlist has redirected_pathname
nested inside .info (vs kernel4's flat layout), so we dereference entry->info.*.

Idempotent: skips if helpers already present.
"""
import sys
from pathlib import Path

SUSFS_C = Path("/work/kernel3/fs/susfs.c")

MARKER = "/* SUSFS 2.1.0 new-API call-site helpers (appended by patch_helpers.py) */"

HELPERS = f'''

{MARKER}
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
void susfs_sus_ino_for_generic_fillattr(unsigned long ino, struct kstat *stat) {{
    struct st_susfs_sus_kstat_hlist *entry;

    hash_for_each_possible(SUS_KSTAT_HLIST, entry, node, ino) {{
        if (entry->target_ino == ino) {{
            stat->dev = entry->info.spoofed_dev;
            stat->ino = entry->info.spoofed_ino;
            stat->nlink = entry->info.spoofed_nlink;
            stat->size = entry->info.spoofed_size;
            stat->atime.tv_sec = entry->info.spoofed_atime_tv_sec;
            stat->atime.tv_nsec = entry->info.spoofed_atime_tv_nsec;
            stat->mtime.tv_sec = entry->info.spoofed_mtime_tv_sec;
            stat->mtime.tv_nsec = entry->info.spoofed_mtime_tv_nsec;
            stat->ctime.tv_sec = entry->info.spoofed_ctime_tv_sec;
            stat->ctime.tv_nsec = entry->info.spoofed_ctime_tv_nsec;
            stat->blocks = entry->info.spoofed_blocks;
            stat->blksize = entry->info.spoofed_blksize;
            return;
        }}
    }}
}}

void susfs_sus_ino_for_show_map_vma(unsigned long ino, dev_t *out_dev, unsigned long *out_ino) {{
    struct st_susfs_sus_kstat_hlist *entry;

    hash_for_each_possible(SUS_KSTAT_HLIST, entry, node, ino) {{
        if (entry->target_ino == ino) {{
            *out_dev = entry->info.spoofed_dev;
            *out_ino = entry->info.spoofed_ino;
            return;
        }}
    }}
}}

int susfs_sus_ino_for_filldir64(unsigned long ino) {{
    struct st_susfs_sus_kstat_hlist *entry;

    hash_for_each_possible(SUS_KSTAT_HLIST, entry, node, ino) {{
        if (entry->target_ino == ino)
            return 1;
    }}
    return 0;
}}
#endif /* CONFIG_KSU_SUSFS_SUS_KSTAT */

#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
struct filename *susfs_get_redirected_path(unsigned long ino) {{
    struct st_susfs_open_redirect_hlist *entry;

    hash_for_each_possible(OPEN_REDIRECT_HLIST, entry, node, ino) {{
        if (entry->target_ino == ino) {{
            SUSFS_LOGI("Redirect for ino: %lu\\n", ino);
            return getname_kernel(entry->info.redirected_pathname);
        }}
    }}
    return ERR_PTR(-ENOENT);
}}
#endif /* CONFIG_KSU_SUSFS_OPEN_REDIRECT */
'''


def main():
    if not SUSFS_C.exists():
        print(f"ERROR: {SUSFS_C} does not exist", file=sys.stderr)
        sys.exit(1)

    text = SUSFS_C.read_text()

    if MARKER in text:
        print(f"SKIP: helpers already present in {SUSFS_C}")
        return

    # Defensive: don't clobber if any of the symbols already has a definition
    # (e.g. user/upstream already added them).
    for sym in [
        "susfs_sus_ino_for_generic_fillattr",
        "susfs_sus_ino_for_show_map_vma",
        "susfs_sus_ino_for_filldir64",
        "susfs_get_redirected_path",
    ]:
        # A definition has "<ret> sym(" at start-of-line; a declaration has ";" at end.
        # Simpler: look for "{sym}(" with a definition body open-brace within 200 chars.
        idx = text.find(sym + "(")
        while idx != -1:
            tail = text[idx:idx + 400]
            if "{" in tail and ";" not in tail.split("{", 1)[0]:
                print(f"ERROR: symbol {sym!r} already defined in {SUSFS_C}",
                      file=sys.stderr)
                sys.exit(1)
            idx = text.find(sym + "(", idx + 1)

    # Append at EOF (guarded by #ifdef so inert when features disabled).
    if not text.endswith("\n"):
        text += "\n"
    text += HELPERS

    SUSFS_C.write_text(text)
    print(f"OK: appended 4 helper defs to {SUSFS_C}")


if __name__ == "__main__":
    main()

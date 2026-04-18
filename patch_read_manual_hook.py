#!/usr/bin/env python3
"""
Wire ksu_handle_sys_read(fd) into SYSCALL_DEFINE3(read) in fs/read_write.c.

Root cause (v12 diagnosis)
--------------------------
SukiSU-Ultra injects its `on post-fs-data / exec -- /data/adb/ksud
post-fs-data` init.rc rules by intercepting init's read of init.rc.
The interception path is:

    sys_read -> vfs_read -> f_op->read
        ^
        kprobe on SYSCALL_DEFINE3(read) in kp_hook.c:
            sys_read_handler_pre -> ksu_handle_sys_read(fd)

`ksu_handle_sys_read` checks whether the fd is pointing at init.rc and,
on the first match, replaces file_operations with a proxy that appends
the KSU rules to the buffer returned to init.

Under CONFIG_KSU_MANUAL_HOOK (our config), kp_hook.c's kprobe setup in
`kp_handle_ksud_init()` is gated by CONFIG_KSU_SYSCALL_HOOK. So the
kprobe NEVER registers, `ksu_handle_sys_read` is never called, init.rc
is never modified, and the `on post-fs-data -> ksud` action never gets
added to init's runtime rules.

Symptom: ksud post-fs-data never runs, so NO Magisk-style module's
post-fs-data.sh / service.sh executes at boot. /data/local/tmp/
susfs_allinone.log stays empty. SuSFS config never gets applied.

This mirrors v11's patch_reboot_manual_hook.py — both are wiring up
kp_hook.c entry points directly in the real syscall paths.

Idempotent.
"""
from pathlib import Path

READ_WRITE_C = Path("/work/kernel3/fs/read_write.c")

ANCHOR = """SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
\treturn ksys_read(fd, buf, count);
}
"""

REPLACEMENT = """SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU
\t{
\t\textern void ksu_handle_sys_read(unsigned int fd);
\t\tksu_handle_sys_read(fd);
\t}
#endif
\treturn ksys_read(fd, buf, count);
}
"""

MARKER = "extern void ksu_handle_sys_read(unsigned int fd);"


def main() -> None:
    text = READ_WRITE_C.read_text()
    if MARKER in text:
        print(f"SKIP: ksu_handle_sys_read manual hook already in {READ_WRITE_C}")
        return
    if ANCHOR not in text:
        raise SystemExit(
            f"ERROR: SYSCALL_DEFINE3(read) anchor not found in {READ_WRITE_C} "
            "(tree may have diverged; inspect fs/read_write.c manually)"
        )
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    READ_WRITE_C.write_text(text)
    print(f"OK: inserted manual ksu_handle_sys_read hook into {READ_WRITE_C}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Insert a manual ksu_handle_sys_reboot() call into kernel/reboot.c
SYSCALL_DEFINE4(reboot, ...).

Root cause (v9 diagnosis)
-------------------------
SukiSU-Ultra wires its supercall kprobe via kp_handle_supercalls_init() in
drivers/kernelsu/supercalls.c, but the call is gated by:

    #ifdef CONFIG_KSU_SYSCALL_HOOK
        kp_handle_supercalls_init();
    #endif

Our config uses CONFIG_KSU_MANUAL_HOOK with CONFIG_KSU_SYSCALL_HOOK=n, so
the kprobe on __arm64_sys_reboot NEVER registers. That means:

  * ksud's `susfs status` issues
      syscall(SYS_reboot, KSU_INSTALL_MAGIC1, SUSFS_MAGIC,
              CMD_SUSFS_SHOW_VERSION, &buf)
  * No hook catches it
  * Kernel's real sys_reboot sees magic1 != LINUX_REBOOT_MAGIC1 → -EINVAL
  * ksud reads `buf` which is still zeroed → prints "unsupport"
  * Manager's getSuSFSStatus() != "true" → SuSFS button hidden in Settings
  * No way to configure sus_paths / uname spoof / cmdline spoof
  * Banking apps (Revolut) trip tamper detection

v8's patch_reboot_cmd.py fixed kp_hook.c's NULL-cmd, but kp_hook.c is
compiled dead code under MANUAL_HOOK. This patch places the call directly
in kernel/reboot.c, matching how fs/exec.c do_execveat_common and
kernel/sys.c __sys_setresuid are hooked.

Placement: BEFORE the LINUX_REBOOT_MAGIC1/2 checks, because KSU uses its
own magic (KSU_INSTALL_MAGIC1 = 0xDEADBEEF) which the kernel would otherwise
reject with -EINVAL before we ever see it.

We call ksu_handle_sys_reboot with `&arg` so the handler can dereference the
user pointer parameter. This matches the existing #else/#endif signature in
drivers/kernelsu/supercalls.c (void __user **arg) where the handler pulls
the actual user buffer from the second dereference.

The handler returns 0 on successful SUSFS command handling, non-zero (e.g.
-EINVAL) when magic1 != KSU_INSTALL_MAGIC1. On 0, we short-circuit the
syscall by returning 0 so the real reboot path doesn't run (ksud expects
return; it has already read back the output via `arg`).

Idempotent.
"""
import re
from pathlib import Path

REBOOT_C = Path("/work/kernel3/kernel/reboot.c")

MARKER = "ksu_handle_sys_reboot(&magic1, &magic2, cmd, &arg);"

ANCHOR = """SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
\t\tvoid __user *, arg)
{
\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);
\tchar buffer[256];
\tint ret = 0;

\t/* We only trust the superuser with rebooting the system. */
\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))
\t\treturn -EPERM;
"""

REPLACEMENT = """SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
\t\tvoid __user *, arg)
{
\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);
\tchar buffer[256];
\tint ret = 0;

#ifdef CONFIG_KSU
\t{
\t\textern int ksu_handle_sys_reboot(int magic1, int magic2,
\t\t\t\t\t\t unsigned int cmd,
\t\t\t\t\t\t void __user **arg);
\t\tif (ksu_handle_sys_reboot(magic1, magic2, cmd, &arg) == 0)
\t\t\treturn 0;
\t}
#endif

\t/* We only trust the superuser with rebooting the system. */
\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))
\t\treturn -EPERM;
"""


def main() -> None:
    text = REBOOT_C.read_text()
    if MARKER in text or "ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)" in text:
        print(f"SKIP: ksu_handle_sys_reboot manual hook already in {REBOOT_C}")
        return
    if ANCHOR not in text:
        raise SystemExit(
            f"ERROR: SYSCALL_DEFINE4(reboot) anchor not found in {REBOOT_C} "
            "(tree may have diverged; inspect kernel/reboot.c manually)"
        )
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    REBOOT_C.write_text(text)
    print(f"OK: inserted manual ksu_handle_sys_reboot hook into {REBOOT_C}")


if __name__ == "__main__":
    main()

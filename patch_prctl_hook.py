#!/usr/bin/env python3
"""
Insert ksu_handle_prctl() call into kernel3's kernel/sys.c prctl syscall.

SukiSU-Ultra's KSU_MANUAL_HOOK mode relies on the kernel's prctl() to dispatch
the manager's handshake (KERNEL_SU_OPTION magic) into the KSU driver. Matrixx's
kernel3 tree ships fs/ hooks (stat, open, exec, devpts) but forgot to patch the
prctl syscall in kernel/sys.c — that's why SukiSU Manager reports
"No KernelSU driver detected, wrong kernel?" even though CONFIG_KSU=y.

Fix: inject a one-liner call + extern decl right after the local variables,
before security_task_prctl() so SELinux doesn't EPERM the magic option first.

Idempotent.
"""
from pathlib import Path

SYS_C = Path("/work/kernel3/kernel/sys.c")
MARKER = "ksu_handle_prctl(option, arg2, arg3, arg4, arg5)"

ANCHOR = """SYSCALL_DEFINE5(prctl, int, option, unsigned long, arg2, unsigned long, arg3,
		unsigned long, arg4, unsigned long, arg5)
{
	struct task_struct *me = current;
	unsigned char comm[sizeof(me->comm)];
	long error;
"""

REPLACEMENT = """SYSCALL_DEFINE5(prctl, int, option, unsigned long, arg2, unsigned long, arg3,
		unsigned long, arg4, unsigned long, arg5)
{
	struct task_struct *me = current;
	unsigned char comm[sizeof(me->comm)];
	long error;

#ifdef CONFIG_KSU
	extern int ksu_handle_prctl(int option, unsigned long arg2,
				    unsigned long arg3, unsigned long arg4,
				    unsigned long arg5);
	ksu_handle_prctl(option, arg2, arg3, arg4, arg5);
#endif
"""


def main():
    text = SYS_C.read_text()
    if MARKER in text:
        print(f"SKIP: ksu_handle_prctl already wired in {SYS_C}")
        return
    if ANCHOR not in text:
        raise SystemExit(f"ERROR: prctl anchor not found in {SYS_C}")
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    SYS_C.write_text(text)
    print(f"OK: inserted ksu_handle_prctl into {SYS_C}")


if __name__ == "__main__":
    main()

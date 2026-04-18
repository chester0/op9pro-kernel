#!/usr/bin/env python3
"""
Insert ksu_handle_setresuid() call into kernel3's __sys_setresuid() body.

Under CONFIG_KSU_SUSFS=y, SukiSU-Ultra skips the LSM task_fix_setuid
registration (see drivers/kernelsu/lsm_hook.c ~L111) and instead expects
the kernel tree to carry a manual call to ksu_handle_setresuid(ruid, euid,
suid) inside __sys_setresuid(). Matrixx's kernel3 tree doesn't carry that
patch, so zygote's app-fork setresuid() never triggers the manager-detect
path that (a) writes __NR_reboot into the seccomp cache and (b) installs
the manager fd.

Without this call, the SukiSU Manager's libksud.so dies with SIGSYS
(SYS_SECCOMP) on syscall 142 before the reboot kprobe can intercept, and
the manager reports "No KernelSU driver detected".

The hook is wrapped in a nested block so the extern declaration sits at
the start of its own scope — required to satisfy the kernel's
-Werror=declaration-after-statement (C89 rule).

Idempotent: if the correct marker is already present, skip. If a prior
BROKEN patch (extern at function entry, violates C89) is present, remove
it before applying the correct patch.
"""
import re
from pathlib import Path

SYS_C = Path("/work/kernel3/kernel/sys.c")

GOOD_MARKER = "ksu_handle_setresuid(ruid, euid, suid);\n\t}\n#endif"

BROKEN_PATTERN = re.compile(
    r"long __sys_setresuid\(uid_t ruid, uid_t euid, uid_t suid\)\n"
    r"\{\n"
    r"#ifdef CONFIG_KSU\n"
    r"\textern int ksu_handle_setresuid\(uid_t ruid, uid_t euid, uid_t suid\);\n"
    r"\tksu_handle_setresuid\(ruid, euid, suid\);\n"
    r"#endif\n"
)

BROKEN_REPLACEMENT = "long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)\n{\n"

ANCHOR = """	kuid_t kruid, keuid, ksuid;

	kruid = make_kuid(ns, ruid);"""

REPLACEMENT = """	kuid_t kruid, keuid, ksuid;

#ifdef CONFIG_KSU
	{
		extern int ksu_handle_setresuid(uid_t, uid_t, uid_t);
		ksu_handle_setresuid(ruid, euid, suid);
	}
#endif

	kruid = make_kuid(ns, ruid);"""


def main() -> None:
    text = SYS_C.read_text()

    if GOOD_MARKER in text:
        print(f"SKIP: correct ksu_handle_setresuid hook already in {SYS_C}")
        return

    new_text, removed = BROKEN_PATTERN.subn(BROKEN_REPLACEMENT, text, count=1)
    if removed:
        print("INFO: removed prior broken patch at function entry")
        text = new_text

    if ANCHOR not in text:
        raise SystemExit(f"ERROR: post-decl anchor not found in {SYS_C}")

    text = text.replace(ANCHOR, REPLACEMENT, 1)
    SYS_C.write_text(text)
    print(f"OK: inserted ksu_handle_setresuid (nested block) into {SYS_C}")


if __name__ == "__main__":
    main()

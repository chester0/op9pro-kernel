#!/usr/bin/env python3
"""
Insert ksu_handle_execveat_ksud() call into fs/exec.c do_execveat_common().

Root cause (v6 diagnosis)
-------------------------
Under CONFIG_KSU_SUSFS, SukiSU-Ultra 4.1.2 skips ksu_ksud_init() in
ksuinit.c (the init call is wrapped in `#ifndef CONFIG_KSU_SUSFS`), on the
assumption that some replacement hook is installed elsewhere — but kernel3
has no replacement. The upshot:

  * The execve hook is never active.
  * `handle_second_stage()` never fires when /system/bin/init runs with
    argv "second_stage".
  * `apply_kernelsu_rules()` is never called.
  * `susfs_zygote_sid` stays 0 forever.
  * Every `ksu_handle_setresuid` call returns at the first check
    (`!susfs_is_sid_equal(current_cred(), susfs_zygote_sid)` — false vs 0).
  * Manager is never discovered, seccomp cache is never primed,
    libksud.so SIGSYS's on reboot, manager says "unsupported".

The existing fs/exec.c has a call to `ksu_handle_execveat_sucompat` but
only under CONFIG_KSU_SUSFS_SUS_SU AND gated by the userspace-toggled
`susfs_is_sus_su_hooks_enabled` flag — neither of which fires during our
boot.

Fix
---
Add an unconditional call to `ksu_handle_execveat_ksud()` at the top of
`do_execveat_common()`. This is what triggers the second_stage detection
and the rules application. It runs on EVERY execve but returns immediately
after `stop_execve_hook()` is called once the zygote is detected.

Idempotent.
"""
import re
from pathlib import Path

EXEC_C = Path("/work/kernel3/fs/exec.c")

MARKER = "ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);"

KSUD_ONLY_PATTERN = re.compile(
    r"#ifdef CONFIG_KSU\n"
    r"\t\{\n"
    r"\t\textern int ksu_handle_execveat_ksud\(int \*fd,\n"
    r"\t\t\t\t\t\t    struct filename \*\*filename_ptr,\n"
    r"\t\t\t\t\t\t    void \*argv, void \*envp,\n"
    r"\t\t\t\t\t\t    int \*flags\);\n"
    r"\t\tksu_handle_execveat_ksud\(&fd, &filename, &argv, &envp, &flags\);\n"
    r"\t\}\n"
    r"#endif\n"
)

ANCHOR = """static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{
#ifdef CONFIG_KSU_SUSFS_SUS_SU
	if (susfs_is_sus_su_hooks_enabled)
		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif
"""

REPLACEMENT = """static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_execveat(int *fd,
					       struct filename **filename_ptr,
					       void *argv, void *envp,
					       int *flags);
		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_SU
	if (susfs_is_sus_su_hooks_enabled)
		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif
"""


def main() -> None:
    text = EXEC_C.read_text()
    if MARKER in text:
        print(f"SKIP: ksu_handle_execveat call already in {EXEC_C}")
        return

    text, removed = KSUD_ONLY_PATTERN.subn("", text, count=1)
    if removed:
        print("INFO: removed prior ksud-only patch (will re-apply combined form)")

    if ANCHOR not in text:
        raise SystemExit(f"ERROR: do_execveat_common anchor not found in {EXEC_C}")
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    EXEC_C.write_text(text)
    print(f"OK: inserted ksu_handle_execveat (init+ksud+sucompat) into {EXEC_C}")


if __name__ == "__main__":
    main()

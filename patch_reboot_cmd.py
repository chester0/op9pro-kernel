#!/usr/bin/env python3
"""
Fix the kp_hook reboot_handler_pre NULL-cmd bug.

Root cause (v8 diagnosis)
-------------------------
drivers/kernelsu/kp_hook.c reboot_handler_pre() hooks __arm64_sys_reboot via
kprobe and calls `ksu_handle_sys_reboot(magic1, magic2, NULL, arg)`. The
author's comment reads:

    // cmd is not really used here, so we NULL!

That was true for the **non-SUSFS** variant of ksu_handle_sys_reboot (which
only checks magic + uid). Under CONFIG_KSU_SUSFS the same symbol is
overloaded as a command multiplexer — every `CMD_SUSFS_*` dispatch
(SHOW_VERSION=0x555e1, ADD_SUS_PATH=0x555e3, etc.) is gated on cmd.

Because kp_hook passed NULL, cmd == 0 in the handler, so no SUSFS command
ever matches. Userspace effect:

  * `ksud susfs status` → syscall returns nothing → "unsupport"
  * Manager's SettingsMaterial.kt: `getSuSFSStatus() == "true"` → false
  * SuSFS Configuration button hidden from Settings
  * Can't configure sus_path/sus_mount/uname spoofing → Revolut root-detects

Fix
---
Read the third syscall argument register (x2 on arm64 → PT_REGS_PARM3) and
pass it as cmd. One-token change.

Idempotent.
"""
import re
from pathlib import Path

KP_HOOK = Path("/work/kernel3/drivers/kernelsu/kp_hook.c")

MARKER = "unsigned int cmd = (unsigned int)PT_REGS_PARM3(real_regs);"

ANCHOR = """\tint magic1 = (int)PT_REGS_PARM1(real_regs);
\tint magic2 = (int)PT_REGS_PARM2(real_regs);
\tvoid __user **arg = (void __user **)&PT_REGS_SYSCALL_PARM4(real_regs);

\t// cmd is not really used here, so we NULL!
\tif (ksu_handle_sys_reboot(magic1, magic2, NULL, arg)) {"""

REPLACEMENT = """\tint magic1 = (int)PT_REGS_PARM1(real_regs);
\tint magic2 = (int)PT_REGS_PARM2(real_regs);
\tunsigned int cmd = (unsigned int)PT_REGS_PARM3(real_regs);
\tvoid __user **arg = (void __user **)&PT_REGS_SYSCALL_PARM4(real_regs);

\t// SUSFS uses cmd to dispatch CMD_SUSFS_* (SHOW_VERSION=0x555e1 etc).
\tif (ksu_handle_sys_reboot(magic1, magic2, cmd, arg)) {"""


def main() -> None:
    text = KP_HOOK.read_text()
    if MARKER in text:
        print(f"SKIP: reboot cmd fix already present in {KP_HOOK}")
        return
    if ANCHOR not in text:
        raise SystemExit(
            f"ERROR: reboot_handler_pre anchor not found in {KP_HOOK} "
            "(upstream may have already renamed/fixed this)"
        )
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    KP_HOOK.write_text(text)
    print(f"OK: patched reboot_handler_pre to pass cmd (PARM3) in {KP_HOOK}")


if __name__ == "__main__":
    main()

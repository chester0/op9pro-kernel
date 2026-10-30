# op9pro-sukisu-susfs

Port of **SukiSU-Ultra 4.1.2 + SUSFS 2.1.0** onto the Matrixx kernel3 tree
(LineageOS `android_kernel_oneplus_sm8350`, `lineage-23.0` branch) for
**OnePlus 9 Pro** (`lemonadep`, SM8350/lahaina, kernel 5.4) running
Evolution-X A16 QPR2.

The kernel3 tree already ships SukiSU-Ultra 4.1.2 sources, but **the driver
assumes someone else wires its hooks** — and kernel3 doesn't. Under
`CONFIG_KSU_SUSFS + CONFIG_KSU_MANUAL_HOOK`, several critical call sites
are gated away. This repo fixes those gaps with four idempotent Python
patch scripts, plus an AVB vbmeta patch for persistent flashing on an
unlocked bootloader.

Result (`boot_sukisu_ported_kpm_v10.img`): SukiSU Manager connects, crowns
itself, grants root to apps, SUSFS UI is reachable from Settings, and
basic Play Integrity checks pass (verified: Revolut opens without
tamper-detection block).

**Docker on the phone (2026-10-30):** `tools/docker-*.sh`, `tools/push-docker.ps1` and `compose/` bring
Docker up on the 9 Pro and run its planned jobs; see [docs/DOCKER-9PRO.md](docs/DOCKER-9PRO.md).

---

## The five hand-ported hook call sites

These are gaps in Matrixx kernel3 + SukiSU-Ultra 4.1.2 under
`CONFIG_KSU_SUSFS`. Each patch is idempotent and has an `ANCHOR/REPLACEMENT`
pair guarded by a `MARKER` check.

| # | File | What's missing | Why | Patch script |
|---|------|----------------|-----|--------------|
| 1 | `kernel/sys.c` `__sys_setresuid` | `ksu_handle_setresuid(ruid,euid,suid)` call after uid transition | Primes the seccomp `allow_native` cache for `__NR_reboot` on every manager fork — without it, `libksud.so` SIGSYS's on reboot and the app reports "driver unsupported". Injected as a nested block to satisfy `-Werror=declaration-after-statement`. | `patch_setresuid_hook.py` |
| 2 | `drivers/kernelsu/ksuinit.c` `kernelsu_init` | `ksu_observer_init()` call | The exit side calls `ksu_observer_exit()` under the same `#if` guard but the init was simply forgotten. `pkg_observer.c` is already compiled via `shim.c`'s unity-build `#include` — do NOT add it to `Kbuild` (duplicate symbols). | `patch_pkg_observer.py` |
| 3 | `drivers/kernelsu/setuid_hook.c` `ksu_handle_setresuid` | Lazy `track_throne(false)` when `!ksu_is_manager_appid_valid()` | `pkg_observer` attaches fsnotify to `/data/system` at `device_initcall`, but `/data` isn't mounted yet — the watch fails `-ENOENT` and never retries. Lazy fallback re-scans `packages.list` on each zygote fork until the manager is discovered. Cheap no-op once found. | `patch_lazy_throne.py` |
| 4 | `fs/exec.c` `do_execveat_common` | Combined `ksu_handle_execveat()` call (chains `_init → _ksud → _sucompat`) | **The v7→v8 blocker.** The existing `ksu_handle_execveat_sucompat` call is gated by `CONFIG_KSU_SUSFS_SUS_SU` AND the userspace-toggled `susfs_is_sus_su_hooks_enabled` flag — neither fires during boot. The combined entry (a) detects `/system/bin/init second_stage` → populates `susfs_zygote_sid` (was 0), and (b) intercepts `su` exec → rewrites to ksud path + calls `escape_with_root_profile()`. v7 only wired `_ksud` (manager crowned but "failed to grant root"); v8's combined form fixed it. | `patch_execve_ksud_hook.py` |
| 5 | `kernel/reboot.c` `SYSCALL_DEFINE4(reboot,...)` | Direct call to `ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)` before the `CAP_SYS_BOOT` / `LINUX_REBOOT_MAGIC1` checks | **The v8→v10 blocker.** SukiSU's supercall dispatch wires a kprobe on `__arm64_sys_reboot` via `kp_handle_supercalls_init()`, but that call is gated `#ifdef CONFIG_KSU_SYSCALL_HOOK` — under `MANUAL_HOOK` the kprobe never registers. `ksud susfs status` issues `reboot(KSU_INSTALL_MAGIC1=0xDEADBEEF, SUSFS_MAGIC, CMD_SUSFS_SHOW_VERSION, &buf)`; without a hook the kernel's real `sys_reboot` sees `magic1 != LINUX_REBOOT_MAGIC1` (0xfee1dead) → `-EINVAL` → `buf` stays zeroed → `"unsupport"` → manager's `SettingsMaterial.kt` gate `getSuSFSStatus() == "true"` fails → SuSFS UI hidden, banking apps tamper-detect. Injecting the call directly in the SYSCALL_DEFINE body, BEFORE the magic check (because KSU uses its own magic number), and short-circuiting `return 0` on successful handle, is the MANUAL_HOOK-native equivalent of what kp_hook.c does for SYSCALL_HOOK. | `patch_reboot_manual_hook.py` |

Supporting patches (SUSFS 2.1.0 API port):

| File | Purpose | Patch script |
|------|---------|--------------|
| `fs/*.c` | SUSFS 1.x → 2.1 API (`inode->i_state` bitflags → `inode->i_mapping->flags`; `task_struct->susfs_task_state` → `thread_info->flags` bit 33) | `patch_api_port.py` |
| `fs/susfs.c` | Four helper function definitions (`susfs_is_inode_sus_mount`, etc.) | `patch_helpers.py` |
| `include/linux/susfs.h` | Report `SUSFS_VERSION` as `"v2.0.0"` instead of `"v2.1.0"` — **manager compat**, see below | `patch_susfs_version.py` |
| `drivers/kernelsu/kp_hook.c` | Pass `cmd` (PARM3) instead of NULL to `ksu_handle_sys_reboot` — fixes dead-code path for if `CONFIG_KSU_SYSCALL_HOOK` is ever enabled on this tree | `patch_reboot_cmd.py` |

**Manager version-string hack** (`patch_susfs_version.py`): SukiSU-Ultra
v4.1.2's APK ships only `assets/ksu_susfs_2.0.0` — no 2.1.0 asset. The
manager queries the kernel via SHOW_VERSION, strips the `v`, and opens
`assets/ksu_susfs_${v}` before every command. Reporting `v2.1.0`
triggers `FileNotFoundException` on every `add_sus_path` / `set_uname`
call and the SuSFS Configuration UI silently fails to save any setting.
Reporting `v2.0.0` makes the manager pick the shipped asset — the binary
itself is 2.1.0-capable (strings confirm `add_sus_path_loop`,
`add_sus_map`, `enable_avc_log_spoofing`, `add_open_redirect`,
`add_sus_kstat_statically`). Only the filename in the APK is mislabeled.
No features lost.

The kernel's manager signature check (`apk_sign.c` with
`EXPECTED_HASH_SHIRKNEKO`) rejects any APK we re-sign ourselves, so
patching the APK to add a correctly-named asset isn't viable without
also rebuilding the kernel with a new expected-hash — and at that point
the one-line version-string patch is the far less invasive fix.

AVB bypass for persistent flash:

| File | Purpose | Script |
|------|---------|--------|
| `vbmeta_b` partition | 256-byte minimal AVB header with `flags=0x03` (HASHTREE_DISABLED \| VERIFICATION_DISABLED) — tells an unlocked bootloader to skip chain-of-trust checks on `boot_b` | `make_vbmeta_disabled.py` |

---

## Why kernel3 + hand-ported API (not kernel2 or kernel4)

| Tree | Verdict | Reason |
|------|---------|--------|
| kernel2 (origin/builtin) | Works but not enough | Lacks SUSFS 2.1.0 (non-negotiable requirement) |
| kernel4 (leahs) | SUSFS 2.1.0 pre-integrated | **Missing OnePlus oplus driver stack** — won't boot on real hardware |
| **kernel3 (this)** | Ships oplus drivers | SUSFS integration is the old API (`inode->i_state`, `task_struct->susfs_task_state`); ported UP to 2.1.0 |

---

## Build & flash (OnePlus 9 Pro, unlocked bootloader)

Prerequisites:
- Docker, with a build container named `op9build` that has the Matrixx
  kernel3 tree at `/work/kernel3`, KernelPatch `kptools-linux`, AnyKernel3
  tools, and magiskboot in `/work/ak3-sukisu/tools/`
- `fastboot`, `adb` (tested with Android platform-tools)
- Superkey: `op9ported2026` (used for the KPM patch)

```bash
# 1) Apply patches (all idempotent — safe to re-run)
docker exec op9build bash -c 'cd /work/kernel3 && \
  python3 /work/patch_api_port.py && \
  python3 /work/patch_helpers.py && \
  python3 /work/patch_setresuid_hook.py && \
  python3 /work/patch_pkg_observer.py && \
  python3 /work/patch_lazy_throne.py && \
  python3 /work/patch_execve_ksud_hook.py && \
  python3 /work/patch_reboot_manual_hook.py && \
  python3 /work/patch_reboot_cmd.py && \
  python3 /work/patch_susfs_version.py'

# 2) Build + KPM re-arm + repack boot.img
docker exec op9build /work/build-sukisu-minimal.sh
# -> /output/boot_sukisu_ported_kpm_v10.img

# 3) Prepare AVB bypass (one-time)
python make_vbmeta_disabled.py
# -> output/vbmeta_disabled.img  (256 bytes, flags=0x03)

# 4) Flash (assumes unlocked bootloader; slot b shown)
adb reboot bootloader
fastboot --disable-verity --disable-verification flash vbmeta_b output/vbmeta_disabled.img
fastboot flash boot_b output/boot_sukisu_ported_kpm_v8.img
fastboot reboot
```

Recovery if anything panics:
```bash
fastboot flash boot_b output/boot_stock.img   # flash stock back
```
(Stock is whatever was in your ROM's `boot.img` before this experiment.)

---

## Success indicators (kernel log)

```
KernelSU: /system/bin/init second_stage executed
KernelSU: Cached zygote SID: 78           # was 0 before v7
KernelSU: on_post_fs_data!
KernelSU: watching /data/system
KernelSU: packages.list detected: 128
KernelSU: Crowning manager: com.sukisu.ultra(uid=10004)
```

---

## Why RAM-boot works but persistent flash doesn't (without vbmeta bypass)

`fastboot boot` bypasses the chain of trust — the bootloader trusts the
USB-delivered image because fastboot itself is an authenticated mode.
`fastboot flash boot` writes to the partition, but **next power-up the
bootloader recomputes the hash and compares against `vbmeta_b`'s signed
descriptor** → mismatch → panic → ramdump.

The minimal 256-byte vbmeta we generate sets `flags=0x03`
(`HASHTREE_DISABLED | VERIFICATION_DISABLED`). Per the AVB spec, a
bootloader that sees `VERIFICATION_DISABLED` stops at vbmeta and never
processes chained partitions — effectively disabling all verified-boot
checks. This is **spec-compliant behavior**, not a hack, and only works on
an unlocked bootloader (a locked one rejects unsigned vbmeta images).

---

## Files

```
patch_api_port.py            # SUSFS 1.x → 2.1 API port, fs/*.c
patch_helpers.py             # 4 helper defs added to fs/susfs.c
patch_setresuid_hook.py      # kernel/sys.c __sys_setresuid
patch_pkg_observer.py        # drivers/kernelsu/ksuinit.c kernelsu_init
patch_lazy_throne.py         # drivers/kernelsu/setuid_hook.c ksu_handle_setresuid
patch_execve_ksud_hook.py    # fs/exec.c do_execveat_common
make_vbmeta_disabled.py      # generates 256-byte vbmeta with flags=0x03
build-sukisu-minimal.sh      # reference build script (runs inside op9build container)
```

Prebuilt `boot_sukisu_ported_kpm_v8.img` is attached to the GitHub Release
for this commit (GitHub blocks files >100 MB in git; the boot image is
192 MB).

---

## Credits & upstream

- Matrixx-Devices / LineageOS `android_kernel_oneplus_sm8350` — base tree
- ShirkNeko `SukiSU-Ultra` — driver
- `simonpunk/susfs4ksu` — SUSFS 2.1.0 source
- `bmax121/KernelPatch` — `kptools` + KPM runtime

This repo is the set of patches that make them all work together on
kernel3 under `CONFIG_KSU_SUSFS + CONFIG_KSU_MANUAL_HOOK`.

## License

Patches: MIT. The kernel they patch is GPLv2 (upstream).

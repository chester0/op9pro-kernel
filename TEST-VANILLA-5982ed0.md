# Test runbook: VanillaKernel 5982ed0 on the OnePlus 9 Pro (Phone9Pro)

Written 2026-10-26. Goal: check that the maintainer's branch
`feat/bridge_netfilter_parameter` (commit `5982ed0`) boots on Phone9Pro and
has the 8 Docker options, by RAM boot only. Nothing is flashed.

## What the commit does (read from the diff)

- Repo: `vanilla-kernel/VanillaKernel`, one commit on top of `lineage-24.0` (`10d97e0`).
- Changes one file, `arch/arm64/configs/vanillaKernel-defconfig`, adds
  `CONFIG_CGROUP_PIDS=y`, `CONFIG_CGROUP_DEVICE=y`, `CONFIG_BRIDGE_NETFILTER=y`.
- That file is a fragment, not a full defconfig. CI merges it over
  `vendor/lahaina-qgki_defconfig` (SM8350 / lemonadep). Already in the fragment:
  SYSVIPC, POSIX_MQUEUE, IPC_NS, PID_NS, NETFILTER_XT_MATCH_ADDRTYPE.
- CI runs `tools/check-fragment.sh` after the merge, so a fragment option
  that a dependency silently drops fails the build. The proof is still
  `/proc/config.gz` on the phone (step 4).
- Base is LineageOS source. Phone9Pro runs a different ROM (check with
  `getprop ro.build.display.id` first). The project README warns that kernels
  older than 2.1.1 bootloop; this branch is newer, so that is not the risk.
  The risk is a ROM/kernel mismatch, which a RAM boot absorbs.

## Build artifact: NONE YET (state on 2026-10-26, about 09:10Z)

There is no build of 5982ed0 to test, so the steps below are the plan for
when one exists.

- CI run 40293317820 (push to the branch) FAILED in "Build kernel". The config
  steps passed: "Checked 86 option(s) ... All fragment options applied
  cleanly", so the 8 Docker options do reach the final `.config`.
- The compile error is in the `KernelSU` submodule (VanillaSU, branch
  `sync-upstream-31.09`), not in the Docker change:
  `drivers/kernelsu/hook/hook_manager.c:294` implicit declaration of
  `escape_to_root_for_init`, and `:363` too many arguments to a function
  (expected 2, have 3).
- The submodule pointer moved in `9b47bd2` ("sync ksun with upstream") from
  `a12e2d4` (last green CI, `9ad2bc8`, 13 Oct) to `669be3f`, and `10d97e0`
  ("fix KernelSU execveat conflicting types") did not finish the job. The
  branch is based on `10d97e0`, so it inherits the break. Other runs on
  `lineage-24.0` after that point also failed.
- What is needed: a green CI run on a tree that has the 3 options. Either
  the maintainer fixes the submodule mismatch (then re-run the workflow,
  or `workflow_dispatch` on the branch), or a local build of 5982ed0 with
  the `KernelSU` submodule pinned to `a12e2d4` (the 13 Oct green state),
  using the README recipe (`tools/build.sh config vendor/lahaina-qgki_defconfig
  arch/arm64/configs/vanillaKernel-defconfig`, then `tools/build.sh kernel`,
  clang r416183b). Pinning the submodule is our change to their tree, so say
  so when reporting.
- When a run is green: `gh run download <run id> -R vanilla-kernel/VanillaKernel
  -n VanillaKernel -D C:\000CHESTA-CODE\op9pro-kernel\output\vanilla-5982ed0`
  and record the SHA-256 of the zip here. The CI artifact is
  `VanillaKernel-<sha>-<vanillasu>.zip`, an AnyKernel3 zip (14 days
  retention). It holds a bare `Image`, not a boot image.

## Why a boot image has to be made

`fastboot boot` needs a boot image. The zip only has the kernel `Image`
plus AnyKernel3 scripts. Take the boot image of the ROM that is installed
now, swap its kernel, repack:

1. Get the ROM's own `boot.img` for the same build as installed (from the
   ROM zip's `payload.bin`, or the ROM's release page). Keep it as
   `boot-stock.img`. Do not read it from the phone unless Chester decides
   that: it needs root and touches the live device.
2. Work in a new empty folder, with the tool at
   `C:\000CHESTA-CODE\op9pro-kernel\AnyKernel3\tools\magiskboot`
   (a Linux binary: run it in WSL):
   ```
   mkdir -p ~/vtest && cd ~/vtest
   cp <boot-stock.img> boot.img
   magiskboot unpack boot.img        # gives kernel, ramdisk.cpio
   unzip -o <VanillaKernel zip> Image -d zip
   cp zip/Image kernel
   magiskboot repack boot.img boot-vanilla-5982ed0.img
   sha256sum boot-vanilla-5982ed0.img
   ```
3. The new image must stay under the partition size and keep the stock
   header version. `magiskboot unpack` prints it; compare to the stock run.

## Safety facts

- `fastboot boot` loads the image to RAM and starts it once. The flash is
  untouched; a plain reboot returns to the current kernel.
- Phone9Pro touchscreen is dead and adb is Wi-Fi only. After a RAM boot
  adb over Wi-Fi may not come back (new kernel, Wi-Fi driver, or the Wi-Fi
  adb re-arm that fires on `sys.boot_completed`). Treat "no adb after 3
  minutes" as a failed boot, not as a wait.
- A failed RAM boot costs one reboot with the power and volume buttons
  (hold power ~15 s, then it boots the flashed kernel). Needs the USB
  cable and someone at the phone.

## Steps

All with `G:\tools\android-sdk\platform-tools\{adb,fastboot}.exe`.
Serial is the Wi-Fi one from the memory note `reference_op9pro_wifi_adb`.

1. Before: record the baseline. `adb shell uname -r` (expect
   `5.4.302-qgki-...`), `adb shell getprop ro.build.display.id`,
   `adb shell getprop ro.boot.slot_suffix`.
2. Check the image: `sha256sum` matches the one recorded here; `file` shows
   an Android boot image.
3. `adb reboot bootloader`, USB cable in. `fastboot devices` lists it.
   Confirm `fastboot getvar unlocked` says yes.
4. `fastboot boot boot-vanilla-5982ed0.img`
5. Wait up to 3 minutes for `adb devices`. If Wi-Fi adb does not return,
   try `adb connect` once, then go to "Way back".
6. Checks, all read-only:
   - `adb shell uname -r` (expect `5.4.302` plus the Vanilla suffix; differs from baseline)
   - `adb shell "zcat /proc/config.gz | grep -E 'CONFIG_(SYSVIPC|IPC_NS|POSIX_MQUEUE|PID_NS|CGROUP_PIDS|CGROUP_DEVICE|BRIDGE_NETFILTER|NETFILTER_XT_MATCH_ADDRTYPE)='"`
     All 8 must read `=y`. If `/proc/config.gz` is missing, say so:
     it is not proof of failure.
   - Docker's `check-config.sh` (from the moby repo, `contrib/check-config.sh`),
     pushed to `/data/local/tmp` and run with `CONFIG=/proc/config.gz`
     if the phone has bash; otherwise run it on the PC against
     the decompressed config copied off with `adb pull`.
   - `adb shell "logcat -d -b kernel | tail -50"` for panics or oops.
   - Wi-Fi still connected, screen unlock not needed.
7. Write down what you saw before rebooting: the 8 lines, `uname -r`,
   any dmesg warnings.

## Way back

- Normal: `adb reboot`. The flashed kernel comes back. Verify
  `uname -r` equals the baseline.
- If it hangs: hold power ~15 s (USB cable in); it reboots to the flashed
  boot. If it lands in fastboot or ramdump, run `fastboot reboot`.
- If the phone still does not boot the flashed kernel (it should not
  happen, nothing was flashed): the rescue is a stock `boot.img`
  for the installed ROM build flashed to the active slot. The memory note
  places one inside the Docker container `op9build` at
  `/work/repack_leahs/boot.img`, and the Docker engine has moved to WSL since,
  so that container may be gone. Having `boot-stock.img` from step 1 above
  is the real rescue. Persistent flash also needs the disabled-vbmeta recipe
  from `project_op9pro_kernel` (`make_vbmeta_disabled.py`), only if Chester
  asks for it.
- Do not flash anything as part of this test.

## Record

- Branch / commit tested: `feat/bridge_netfilter_parameter` / `5982ed0`
- Artifact SHA-256 and boot-image SHA-256: see below.

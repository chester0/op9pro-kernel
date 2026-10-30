# Test runbook: VanillaKernel e615f34 on the OnePlus 9 Pro (Phone9Pro)

Written 2026-10-30. Supersedes `TEST-VANILLA-5982ed0.md` (kept for the diff
analysis and the safety facts). The maintainer answered on
vanilla-kernel/VanillaKernel#2 with a green build of the same change.
Goal: boot it from RAM on Phone9Pro and check the 8 Docker options. Nothing is flashed.

## The build (VERIFIED)

- Run: https://github.com/vanilla-kernel/VanillaKernel/actions/runs/40575009384
  (27 Oct, branch `feat/bridge_netfilter_parameter`, conclusion success).
- Head SHA: `e615f34c7dcbdd6bbc9290692c02b780391dc89a` (5982ed0 was the earlier commit; the
  maintainer's fix of the broken KernelSU submodule is in this one).
- Downloaded to `C:\000CHESTA-CODE\op9pro-kernel\output\vanilla-e615f34\`
  (`gh run download 40575009384 -R vanilla-kernel/VanillaKernel -n VanillaKernel -D ...`).
  - `VanillaKernel-e615f34c7dcbdd6bbc9290692c02b780391dc89a.zip`, 22.3 MB
  - SHA-256: `79F62ED0B0917AC6F4482B41D9FF5E9FB6B9294E2AB75E8DD913B7ADB6D7F9AF`
  - Unpacked next to it in `zip\`: AnyKernel3 with **`Image.gz`** (19,221,356 bytes), not
    a raw `Image` as in the old runbook, plus `tools\magiskboot`.
- Run log: "Checked 86 option(s) from arch/arm64/configs/vanillaKernel-defconfig against
  out/.config / All fragment options applied cleanly." The fragment at `e615f34` (read through
  the GitHub API) contains CONFIG_CGROUP_PIDS=y, CONFIG_CGROUP_DEVICE=y,
  CONFIG_BRIDGE_NETFILTER=y, plus SYSVIPC, POSIX_MQUEUE, IPC_NS, PID_NS and
  NETFILTER_XT_MATCH_ADDRTYPE. The log has no line per option; the proof that
  the 3 reached the kernel is the fragment check plus `/proc/config.gz` on the phone.

## Boot image: NOT PREPARED YET (blocked)

The prep run could not read the phone: the agent live-system guard blocks `adb` for agents,
including read-only. No boot image existed locally either. So the main session
(or Kai with Chester) does steps A and B first. Nothing below was run on the phone.

### A. Read the phone and dump its boot image (read-only, root)

Address from `machine.ps1 Phone9Pro` (LAN) or `NineProTailnet` (stable tailnet address).
`ADB=G:\tools\android-sdk\platform-tools\adb.exe`; run `adb connect <addr>` first and
`adb disconnect <addr>` last.
```
adb shell "getprop ro.product.device; getprop ro.build.display.id; getprop ro.boot.slot_suffix; uname -r"
adb shell "ls -l /dev/block/by-name/ | grep -E ' boot|init_boot|vendor_boot'"
adb shell "su -c 'dd if=/dev/block/by-name/boot<slot> of=/data/local/tmp/boot-stock.img bs=1M'"
adb pull /data/local/tmp/boot-stock.img C:\000CHESTA-CODE\op9pro-kernel\output\vanilla-e615f34\boot-stock.img
adb shell rm /data/local/tmp/boot-stock.img
```
`dd if=` only reads the partition; the only write is a temp file in `/data/local/tmp` (that is
an `adb pull` source, not a flash). Use the slot from `ro.boot.slot_suffix` (`_a` or `_b`).
Expect `product.device` = `lemonadep` (never `kebab`). Then record
`Get-FileHash boot-stock.img -Algorithm SHA256` here; this file is the backup.

### B. Swap the kernel and repack (WSL, in a new empty folder; magiskboot is a Linux binary)

```
mkdir -p ~/vtest && cd ~/vtest
cp /mnt/c/000CHESTA-CODE/op9pro-kernel/output/vanilla-e615f34/boot-stock.img boot.img
M=/mnt/c/000CHESTA-CODE/op9pro-kernel/output/vanilla-e615f34/zip/tools/magiskboot
$M unpack boot.img                       # prints header version; writes kernel, ramdisk.cpio
file kernel                              # raw "Linux kernel ARM64 boot executable Image" or gzip?
```
- If `kernel` is raw: `gzip -dc <zip>/Image.gz > kernel`. If it is gzip: `cp <zip>/Image.gz kernel`.
- `$M repack boot.img boot-vanilla-e615f34.img`; `sha256sum boot-vanilla-e615f34.img`.
- It must keep the stock header version and stay below the boot partition size
  (`blockdev --getsize64` on the phone, or `ls -l` of the dump: the dump is the partition size).
- Copy the result next to the backup in `...\output\vanilla-e615f34\` and write both SHA-256 here.

## Live step (Kai with Chester)

Pre-check: baseline `adb shell uname -r` (expect `5.4.302-qgki-gcea87e380f92`), then:
```
adb reboot bootloader
fastboot devices
fastboot getvar unlocked          # must say yes
fastboot boot C:\000CHESTA-CODE\op9pro-kernel\output\vanilla-e615f34\boot-vanilla-e615f34.img
```
(`fastboot` = `G:\tools\android-sdk\platform-tools\fastboot.exe`.) Wait up to 3 minutes for adb
(`adb connect <Phone9Pro address>`; the Wi-Fi/tailnet re-arm may or may not run on the new kernel).
Treat no adb after 3 minutes as a failed boot.

Checks after the boot, all read-only:
```
adb shell uname -r                # differs from the baseline
adb shell "zcat /proc/config.gz | grep -E 'CONFIG_(SYSVIPC|IPC_NS|POSIX_MQUEUE|PID_NS|CGROUP_PIDS|CGROUP_DEVICE|BRIDGE_NETFILTER|NETFILTER_XT_MATCH_ADDRTYPE)='"
adb shell "su -c 'dmesg | grep -iE \"panic|oops|BUG:\" | head'"
adb shell "ls /sys/fs/cgroup /dev/cgroup 2>/dev/null; grep -E 'pids|devices' /proc/cgroups"
```
All 8 config lines must read `=y` (if `/proc/config.gz` is missing, that is not proof of failure;
use `/proc/cgroups` for pids and devices). Optional: Docker `check-config.sh` against the
pulled config. Write down the 8 lines and `uname -r` before leaving.

Way back: `adb reboot` (or `fastboot reboot`). A plain reboot returns to the installed kernel;
verify `uname -r` equals the baseline. If hung, hold power about 15 s. No flash is ever done.

## Physical access

- `fastboot boot` needs **USB**: a cable from the phone to a PC with fastboot. There is no
  fastboot over Wi-Fi. The prior runbook says the Evo; the Evo is where the cable should go
  (the tools and Kai's session run there), so **a USB cable phone to Evo is required**, and
  someone has to plug it in. Plug it in before `adb reboot bootloader`.
- The touchscreen is dead, but nothing here needs it: fastboot is driven from the PC, and the
  hardware buttons (power ~15 s hold, volume) are the only on-device controls.
- After the test: unplug the cable, and confirm the charge governor and Tailscale come back
  (see `reference_op9pro_wifi_adb`).

## Record

- Tested: `feat/bridge_netfilter_parameter` / `e615f34`, run 40575009384
- Zip SHA-256: `79F62ED0B0917AC6F4482B41D9FF5E9FB6B9294E2AB75E8DD913B7ADB6D7F9AF`
- boot-stock.img SHA-256: (to fill)
- boot-vanilla-e615f34.img SHA-256: (to fill)

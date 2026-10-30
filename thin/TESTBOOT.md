# Test boot of the thin kernel on the OnePlus 9 Pro (lemonadep), before anything is flashed

Written 2026-10-31. Phone: A/B, adb serial `5d7a3c0` over USB, KernelSU root, **dead touchscreen** (every step is
adb or fastboot; only the hardware buttons are used). It runs the maintainer's VanillaKernel `e615f34` on `boot_a`
(flashed 2026-10-30; `vbmeta_a` is the disabled header, so a changed boot image is not rejected at power-up).

Two candidates, built in `output\thin-20261030\` (see [README.md](README.md), "kABI"):

| Build | Zip | Risk |
|-------|-----|------|
| `full` | `VanillaKernel-thin-e615f34-1fadf98.zip` | `CONFIG_IP_VS=y` changes 2689 exported-symbol CRCs and `CONFIG_MODVERSIONS` is on: a vendor module may refuse to load ("disagrees about version") |
| `skipipvs` | `skip-ipvs\VanillaKernel-thin-skip-ipvs-e615f34-1fadf98.zip` | CRCs identical to the maintainer's; no IPVS (Docker bridge/NAT/overlay2 do not need it) |

`fastboot boot` runs an image from RAM and writes nothing; a plain `adb reboot` then returns to the installed
kernel. That is the whole point: decide with evidence, then flash only the winner. **Never `fastboot flash` before
the decision.**

The tools (all in `tools\`, dry run by default where they act):

| Tool | Runs on | Does |
|------|---------|------|
| `testboot-make.ps1` | the Evo | reads the active boot partition (root `dd`, read only), proves it is today's kernel, repacks it with each build's `Image.gz` using the zip's `magiskboot` (run on the phone), verifies each result, keeps a backup of today's image, writes the SHA-256s, removes its temp files on the phone |
| `testboot-baseline.sh` | the phone | captures the installed kernel: module list and count, module-refusal lines in dmesg, Wi-Fi, audio HAL, KernelSU root, Docker kernel options |
| `testboot-check.sh` | the phone | after a test boot: PASS / FAIL per line against that baseline, `RESULT:` last, exit 1 on any FAIL |
| `testboot-lib.sh` | the phone | sourced by the two above (one place that collects the facts); push it with them |

## The command sequence (PowerShell on the Evo)

    $S    = '5d7a3c0'
    $Repo = 'C:\000CHESTA-CODE\op9pro-kernel'
    $Out  = "$Repo\output\thin-20261030\testboot"      # gitignored; holds the backup, so never delete it
    $Dev  = '/data/local/tmp/testboot-tools'

Plug the USB cable (phone to Evo) before step 2. `adb devices` must list `5d7a3c0`.

### 1. Make the images, keep the backup

    pwsh $Repo\tools\testboot-make.ps1                 # dry run: checks the zips and SHA256SUMS, calls no adb
    pwsh $Repo\tools\testboot-make.ps1 -Execute

It stops (and removes its phone temp folder) if: the device is not a lemonadep; `su` is not root; a zip does not
match the `SHA256SUMS` beside it; the dumped boot image's kernel is **not** the running kernel (banner compared with
`/proc/version`); a pull differs from what the phone hashed; a repacked image's kernel is not the build's, or the
image is larger than the partition dump. It prints the files and the rollback command at the end.

Result in `$Out`: `boot_a-backup-<sha8>.img` (today's boot image, never overwritten or deleted by the tool),
`testboot-full.img`, `testboot-skipipvs.img`, `SHA256SUMS`. Record the three hashes in the table at the end of this
file and commit that edit. Cross-check: the backup should equal `output\vanilla-e615f34\boot-vanilla-e615f34.img`
(sha256 `c3c812436c677062cddfa15fc28feef283e83b0810f533e112b25e38f84559f4`) if that file is what was flashed on
30 Oct; if the hash differs, the phone holds a different image than the repo thinks: write down which, and carry on
with the backup you just took (it is the truth for rollback).

Do not proceed if `magiskboot` is reported not to run on the phone: the AnyKernel3 zips ship a 32-bit ARM
`magiskboot`, which the tool runs on the phone; the AnyKernel3 flasher uses the same binary. Pass `-MagiskbootPath`
with one that runs, or stop and ask.

### 2. Baseline (the installed kernel, phone in its normal state: booted, Wi-Fi up)

    adb -s $S shell mkdir -p $Dev
    adb -s $S push $Repo\tools\testboot-lib.sh $Repo\tools\testboot-baseline.sh $Repo\tools\testboot-check.sh $Dev/
    adb -s $S shell "su -c 'sh $Dev/testboot-baseline.sh'" | Tee-Object "$Out\baseline.txt"
    adb -s $S pull /data/local/tmp/testboot-baseline "$Out\baseline-installed"

The baseline stays on the phone in `/data/local/tmp/testboot-baseline` (survives the test boot). Read the
`WARNING:` lines it may print: "no audio HAL process matched" means the audio check would pass vacuously (look at
`ps -A | grep -i audio` and fix the pattern in `testboot-lib.sh`); "Wi-Fi is not associated" means connect it first.

### 3. Test boot `full` (RAM only)

    adb -s $S reboot bootloader
    fastboot devices                                    # note the serial; normally the same
    fastboot -s $S getvar unlocked                      # must say: unlocked: yes
    fastboot -s $S getvar max-download-size             # must be at least the image size (about 192 MiB)
    fastboot -s $S boot "$Out\testboot-full.img"

Wait for adb, at most 3 minutes (the Wi-Fi/tailnet re-arm may not run on the new kernel, so USB is the way in):

    $deadline = (Get-Date).AddMinutes(3)
    adb -s $S wait-for-device
    while ((adb -s $S shell getprop sys.boot_completed) -ne '1' -and (Get-Date) -lt $deadline) { Start-Sleep 3 }

No adb after 3 minutes is a failed boot: hold power about 15 s; the phone restarts on the installed kernel (nothing
was flashed). Then run the check and keep the evidence:

    adb -s $S shell "su -c 'EXPECT_IPVS=yes sh $Dev/testboot-check.sh'" | Tee-Object "$Out\check-full.txt"
    adb -s $S shell "su -c dmesg" > "$Out\dmesg-full.txt"
    adb -s $S reboot                                    # back to the installed kernel

`EXPECT_IPVS=yes` makes "CONFIG_IP_VS is on" a PASS/FAIL line: both builds print the same kernel banner
(`thin@op9pro-thin`, `-dirty`), so the config is what proves which build booted. If `su` gives no root on the test
kernel the check cannot run: that is a FAIL for "KernelSU root" in itself; record it.

After the reboot, confirm the way back: `adb -s $S shell "cat /proc/version"` must name `runner@runnervmwhx2h`
(the maintainer's build), not `thin@op9pro-thin`.

### 4. Test boot `skipipvs`

Same as step 3 with `testboot-skipipvs.img`, `EXPECT_IPVS=no`, and `check-skipipvs.txt` / `dmesg-skipipvs.txt`.
Run it even if `full` passed: it tells you what the IPVS patch costs, and it is the fallback.

### 5. Decide

| `full` | `skipipvs` | Decision |
|--------|-----------|----------|
| RESULT: PASS | any | Flash `full` if Docker swarm/overlay load balancing is wanted; otherwise `skipipvs` is the conservative pick (stock CRCs). Chester decides. |
| FAIL on lsmod count / module-load errors | PASS | Flash `skipipvs`. The failing module names are in `INFO:` lines and `dmesg-full.txt`; put them in the PR. |
| FAIL | FAIL | Flash nothing. Read the FAIL lines, `dmesg-*.txt`; the installed kernel stays. |
| did not boot | PASS | Flash `skipipvs`. |

PASS means: banner is ours, lsmod count is not lower than the baseline, no new "disagrees about version" /
"Unknown symbol" lines, Wi-Fi associated, audio HAL and `audioserver` still running, root works, every Docker
"Generally Necessary" option present. It does not test touch-free daily use; the dead touchscreen hides display
and touch problems, and the check cannot see them.

### 6. Flash the winner (only after the decision)

The path that has a recorded shape in this repo is a fastboot flash of a boot image (README.md, "Flash"); I found no
recorded 30 Oct command in the repo, only the image it produced (`output\vanilla-e615f34\boot-vanilla-e615f34.img`).
Flash **the exact image that was just test-booted**, so what runs is what was checked:

    $W = 'full'                                         # or 'skipipvs'
    adb -s $S reboot bootloader
    fastboot -s $S getvar current-slot                  # must be: a (the slot the backup came from)
    fastboot -s $S flash boot_a "$Out\testboot-$W.img"  # boot_a only; never vbmeta, never boot_b
    fastboot -s $S reboot

Do not pass `--disable-verity --disable-verification`: `vbmeta_a` is already the disabled header and stays as is.
The AnyKernel3 zip is the alternative (it unpacks the same boot partition on the phone and repacks it with the same
`magiskboot`), but it needs a recovery or a flasher app with a working screen; with a dead touchscreen the fastboot
route is the one to use.

Verify after boot: `adb -s $S shell "uname -r; cat /proc/version"` shows `thin@op9pro-thin`; run
`EXPECT_IPVS=yes|no sh $Dev/testboot-check.sh` again (same flag as the winner's test boot); and that the partition
holds the image (size = the file's length in bytes, `(Get-Item "$Out\testboot-$W.img").Length`):

    adb -s $S shell "su -c 'head -c <size> /dev/block/by-name/boot_a | sha256sum'"   # equals the image's sha256

### 7. Rollback (to the maintainer's e615f34 as it was on 2026-10-30)

From the bootloader (`adb -s $S reboot bootloader`, or, if the phone does not reach Android, hold power + volume
down; no touch needed):

    fastboot -s $S flash boot_a (Get-ChildItem $Out\boot_a-backup-*.img).FullName      # one file; check the name
    fastboot -s $S reboot

Check the file's sha256 against `$Out\SHA256SUMS` and the Record below before flashing it. If `boot_a` ever fails to
boot, the bootloader may switch to `boot_b`: `fastboot getvar current-slot` shows where it is; flash the backup to the
slot it was taken from. The older factory-state image `output\vanilla-e615f34\boot-stock.img` (sha256
`33ff9fe0783fa53a5fa774a70918e182070779da45d586263b79df9e79b817ac`, taken 30 Oct before the maintainer's kernel) is
the second line of defence; it is not today's kernel.

## What was verified without the phone (2026-10-31)

`tests\testboot-make.Tests.ps1` (fake adb: refusals, cleanup, read-only dd, backup never overwritten, hashes) and
`tests\testboot-scripts.Tests.ps1` (shellcheck, and the baseline/check logic under Git's bash with stubs), both
through `pwsh C:\000CHESTA-CODE\dotfiles\bin\test-all.ps1 -NoAffected`. **Not** verified: that `magiskboot` runs on
the phone, that `fastboot boot` accepts a 192 MiB image on this bootloader, and the `cmd wifi status`, `ps -A -o NAME`
and `/proc/config.gz` behaviour of the phone's toybox; each has a visible failure in the tools rather than a
silent pass.

## Record (fill in after step 1; commit)

| File | SHA-256 |
|------|---------|
| `boot_a-backup-<sha8>.img` (today's boot_a) | |
| `testboot-full.img` | |
| `testboot-skipipvs.img` | |
| Tested / decision / date | |

# Docker on the ROM's own kernel (Levion) - OnePlus 9 Pro, EvolutionX 17

Written 2026-10-31. Chester's question: "9 pro got the docker kernel or we need this rom kernel to modify?"
Answer: the ROM's own kernel, Levion, modified. It was built, test-booted from RAM (`fastboot boot`, nothing flashed)
and ran Docker with bridge networking and the overlay2 storage driver. What it could not have is below.

## What was built

| | |
|--|--|
| Source | `varakumar02/Levion_kernel_OP9` branch `aox-ksun` @ `7eee06f3df88` (KernelSU-Next + SUSFS, no submodules) |
| Toolchain | AOSP `clang-r547379` (what Levion's `.github/compile.sh` uses), tree digest pinned in `pins-levion.env` |
| Recipe | Levion's defconfig `vendor/lahaina-qgki_defconfig` + `fragments/levion-docker.config`, Levion's make flags, target `Image` |
| Run | `PINS_FILE=thin/pins-levion.env thin/build.sh all` (same script as the Vanilla build; `RECIPE=levion` in the pins file picks the recipe) |
| Output | `Image` sha256 `4f0d1f4b8ffa5edc3abd75322590dd84ce189e8b77802d91be1dc51798fbb1d6` (reproduced: a second run gave the same bytes), `config` |
| Cost | cold ccache about 6 min for `Image` (fetch 12 s with clang cached; clang download 4 min once), peak RSS about 2 GB |

The kernel release is `5.4.302-levion-op9+`, equal to the vermagic of the phone's vendor modules.

## The Docker options: only two fit

The phone's 48 vendor modules are built against the ROM kernel's exported-symbol CRCs (`CONFIG_MODVERSIONS`). One
different CRC (`module_layout` always is) and a module is refused, so Wi-Fi, audio and display would not come up.
`modcheck.py` compares the modules' `__versions` and vermagic with a build's `crc.txt`:

| Build | CRC mismatches in 4669 imported symbols |
|-------|-----------------------------------------|
| Levion unchanged | 0 |
| **+ PID_NS + XT_MATCH_ADDRTYPE (the fragment)** | **0** |
| + CGROUP_PIDS + CGROUP_DEVICE (also dropped MQUEUE and BRIDGE_NETFILTER) | 880 |
| + the same, + POSIX_MQUEUE | 1919 |
| + all six options moby's check-config asks for | 1923 |

Each new cgroup controller grows `CGROUP_SUBSYS_COUNT` and POSIX_MQUEUE adds to `struct user_struct`, both reach
thousands of symbols. So `CGROUP_DEVICE`, `CGROUP_PIDS`, `POSIX_MQUEUE` and `BRIDGE_NETFILTER` are not in the fragment. To
have them, the vendor modules must be rebuilt with the kernel and `vendor_dlkm` flashed with it (Levion's own
`compile.sh` does that); a test boot cannot try that. Levion already has the rest (SYSVIPC, IPC_NS, UTS_NS, NET_NS,
USER_NS, BRIDGE, VETH, OVERLAY_FS, IP6_NF_NAT, IP6_NF_TARGET_MASQUERADE).

## What had to change around the kernel (tools/)

All found by running Docker on the test-booted kernel; none is a kernel patch.

1. **POSIX_MQUEUE is missing, and runc mounts `/dev/mqueue` in every container** ("no such device"). `docker-runc-nomq.sh`
   is registered as runtime `nomq` (default) and strips that one mount from the OCI config. When the kernel has
   mqueue it does nothing. Cost: containers have no POSIX message queues.
2. **overlayfs refuses an upper on `/data`** (f2fs with casefold/encryption: "filesystem not supported"), so the old
   scripts fell back to vfs. `docker-daemon.sh` now mounts a sparse 8 GB ext4 image (`/data/docker/data.img`, loop)
   over the data-root in dockerd's private namespace, before the root view is built, and overlay2 works on it.
   `DOCKER_IMG_SIZE`, `DOCKER_EXT4_IMAGE=0`.
3. **Replies to containers were unreachable.** Android has no `from all lookup main` rule, so a reply arriving at
   wlan0 for a container address hit `32000: unreachable`. `docker-up.sh` adds `ip rule pref 5998 to 172.16.0.0/12 lookup main` <!-- gitleaks:allow Docker's default bridge range, not a machine fact -->
   next to the existing outbound rule; `docker-down.sh` removes both.

## Test boot, 2026-10-31

Image `output\levion-20261031\testboot-levion.img` (sha256 `1ebcfd415bd13188258219e6152568bbf1f65a3e149a377cc1592b66ebc94ead`):
the phone's own `boot_b` (backup `boot_b-backup-5b73a4b1.img`, equal to the live partition) with only the kernel replaced
by magiskboot on the phone. `fastboot boot` took it; adb and `sys.boot_completed` came up in about a minute.

| Check | Result |
|-------|--------|
| `/proc/version` | `5.4.302-levion-op9+ (thin@op9pro-thin)`, clang r547379 |
| vendor modules | 47 loaded, baseline 47; 0 "disagrees about version" / "Unknown symbol" in dmesg |
| Wi-Fi, audio HAL, `audioserver`, KernelSU root | all as on the installed kernel (`testboot-check.sh`) |
| `/proc/config.gz` | equals the built `config`; PID_NS, ADDRTYPE on |
| `docker info` | overlay2 (extfs, d_type true), cgroupfs, default runtime nomq |
| `docker run --rm hello-world` | OK |
| `docker run --rm alpine ping -c1 1.1.1.1` (default bridge) | 1 of 1 received, 24 ms |
| `docker-proof.sh` | `PROOF OK` |

`testboot-check.sh` also printed `FAIL: Docker check-config` on both kernels: its config reader dies with
"printf: Argument list too long" on the phone's toybox and lists every option as missing (the baseline run on the installed
kernel prints the same list). That line is a bug in the tool, not a kernel fact; the options were read from
`/proc/config.gz` by hand (row above). The other seven lines passed.

Afterwards the phone was rebooted with `adb reboot` and is back on the installed kernel (`build-user@build-host`).
`/data/docker/data.img` stays on the phone (sparse, 75 MB used).

## Flash (Kai, after reading this)

Same shape as [TESTBOOT.md](TESTBOOT.md) step 6, with this image: `fastboot flash boot_b output\levion-20261031\testboot-levion.img`
(active slot only, never vbmeta), rollback `fastboot flash boot_b output\thin-20261030\testboot\boot_b-backup-5b73a4b1.img`.
Docker then starts with `sh /data/docker/tools/docker-up.sh` (install the updated scripts first: `tools\push-docker.ps1 -Execute`,
which also copies `docker-runc-nomq.sh`). Not covered by the test: a cold power-on, and anything needing the touchscreen
(it is dead). It runs Levion `aox-ksun` of 30 Oct, a newer Levion commit than the one the installed kernel was built from (28 Oct, my reading of the build date), so SUSFS/KernelSU-Next versions differ
from the running ROM kernel (v2.3.0 / 3.4.2 against 2.1.0 / 3.2.0 in Levion's README).

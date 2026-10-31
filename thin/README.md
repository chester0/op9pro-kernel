# thin/ - "our thin kernel" for the OnePlus 9 Pro (lemonadep)

The maintainer's audited kernel, exactly as flashed on 2026-10-27, plus a small patch set of ours, built the way
the maintainer's CI builds it, reproducibly, on the Evo. This repo holds the pins, the patches and the build
script, not a copy of the kernel.

| Input | Pin |
|-------|-----|
| Kernel | `vanilla-kernel/VanillaKernel` @ `e615f34c7dcbdd6bbc9290692c02b780391dc89a` (branch `feat/bridge_netfilter_parameter`) |
| Root manager | its submodule `VanillaSU` @ `1fadf987e86ceb4a5439be75cee8eac75a0fdaa0` (build.sh checks the kernel records exactly this) |
| Toolchain | AOSP `clang-r416183b` (googlesource commit `b669748458...`), pinned by the sha256 of its extracted tree |
| Container | `ubuntu@sha256:076e7bf8...` (22.04, the maintainer's CI distro) + the maintainer's apt package list |

All pins are in [`pins.env`](pins.env). `build.sh` refuses any input that does not match its pin
(`thin/tests/build.Tests.ps1` proves it).

**Second source (2026-10-31): the ROM's own kernel, Levion.** The Vanilla build above does not boot on EvolutionX 17
(its vendor modules are Levion's). `PINS_FILE=thin/pins-levion.env thin/build.sh all` builds Levion's `aox-ksun` with the
same script and a Docker fragment, `thin/modcheck.py` checks it against the phone's vendor modules, and it was test-booted
with Docker running: see [LEVION.md](LEVION.md).

## Patches

| File | What | Size |
|------|------|------|
| `patches/vanillasu/0001-apk_sign-upstream-signature-parser-fix.patch` | VanillaSU `kernel/manager/apk_sign.c` gets upstream's fixed APK signing-block parser: tiann/KernelSU `e6cc0ef7b0` (CAN-2026-2035133: only the first ten blocks were checked, so a crafted APK passed) and `aa08b390cd` (accept only the v2 block and verity padding). Ported from KernelSU-Next legacy `165b87fa99ab`; VanillaSU's v1-signature refusal and its manager table are kept | +143 / -98 |
| `patches/kernel/0001-defconfig-docker-ip6-nat-masquerade.patch` | `CONFIG_IP6_NF_NAT=y`, `CONFIG_IP6_NF_TARGET_MASQUERADE=y` | +4 |
| `patches/kernel/0002-defconfig-docker-ipvs.patch` | `CONFIG_IP_VS=y` (the dependency) and `CONFIG_NETFILTER_XT_MATCH_IPVS=y` | +4 |

Total: four defconfig options (8 added lines) and a 241-line change to one C file; 34 + 345 lines of patch text with headers.

## kABI: read this before flashing the full build

`CONFIG_IP_VS=y` (and so the IPVS match) changes the layout of `struct net`, and that changes **2689 of the 13665**
exported-symbol CRCs of the maintainer's kernel (`__alloc_skb`, `__pskb_trim`, `cfg80211_*`, ...). The kernel is
built with `CONFIG_MODVERSIONS`: a vendor module built against the maintainer's CRCs that imports one of the changed
symbols is refused at load time ("disagrees about version of symbol"). Which vendor modules that hits was not
tested (nothing was flashed). It is the risk the 27Aaron kernel's release notes name for options that "move core
structures".

Measured A/B (same source, same toolchain, `crc.txt` = `llvm-nm vmlinux | grep __crc_`):

| Build | CRCs | Changed vs baseline |
|-------|------|---------------------|
| baseline (maintainer's source, no patch) | 13665 | - |
| + IPv6 NAT/MASQUERADE only | 13665 | **0, identical** |
| + IP_VS and the IPVS match only | 13683 | 2689 |
| full thin kernel (all three) | 13683 | 2689 |

So the IPv6 options are free; the IPVS match is the one that is not. Docker itself (bridge, NAT, overlay2) does not
need IPVS; only swarm/overlay load balancing does. `THIN_SKIP=ipvs thin/build.sh ...` builds the variant without
the IPVS patch: `VanillaKernel-thin-skip-ipvs-e615f34-1fadf98.zip`, whose CRCs equal the baseline's.
Both zips were built; the choice is Chester's. To decide with evidence before flashing, boot each from RAM and
check it against the installed kernel: [TESTBOOT.md](TESTBOOT.md).

## Run it

Inside WSL Ubuntu (Docker is the WSL engine); sources, clang and ccache live on WSL's ext4 (`~/op9thin`), never `/mnt/c`:

    wsl -d Ubuntu -- bash /mnt/c/000CHESTA-CODE/op9pro-kernel/thin/build.sh all      # fetch, patch, image, build, verify
    wsl -d Ubuntu -- env THIN_SKIP=ipvs OUT_DIR=$HOME/op9thin/out/noipvs bash .../thin/build.sh all

Steps, each also callable alone (`build.sh <step>`): `fetch` (every input at its pin, verified), `patch`
(idempotent), `image` (build container), `build` (container: `-j8`, 8 GB, no swap, the maintainer's own
`tools/build.sh config`, `tools/check-fragment.sh`, `tools/build.sh kernel`, then their AnyKernel3 packaging),
`verify`, `crc`. Environment: `BUILD_JOBS` (8), `BUILD_MEM` (8g), `OUT_DIR`, `THIN_HOME`, `THIN_PATCHES=none`
(unpatched baseline), `THIN_SKIP=<words>`.

Output (`OUT_DIR`): the flashable AnyKernel3 zip (the recipe makes no boot.img), `Image.gz`, `config`, `SHA256SUMS`,
`check-config.txt`, `apk_sign.diff`, `build.log`, `metrics.txt`, `crc.txt`. The zip has exactly the maintainer's
28 entries; only `Image.gz` differs. Same inputs give the same bytes: a second build, ccache warm and `out/` removed,
produced byte-identical `Image.gz`, zip and `.config` (the banner's user/host/time are fixed from the pinned commit).
The kernel banner ends in `-dirty` on purpose: the tree is not the pinned commit.

Where the container deviates from the maintainer's CI (all named): `build-essential`, `cpio`, `xz-utils` added
(GitHub's runner image has them; the bare ubuntu image does not), an `nproc` shim so their `tools/build.sh`
(`THREADS=$(nproc --all)`, which ignores cgroup limits) runs unmodified at `-j8`, and `zip -X` with sorted entries
and fixed mtimes in place of `zip -r9`.

## Checks (cold build, full thin kernel)

- `.config` has `CONFIG_IP6_NF_NAT=y`, `CONFIG_IP6_NF_TARGET_MASQUERADE=y`, `CONFIG_NETFILTER_XT_MATCH_IPVS=y`,
  `CONFIG_IP_VS=y`; the maintainer's `check-fragment.sh` reports all 90 fragment options applied.
- moby `contrib/check-config.sh` (pinned): every "Generally Necessary" option is enabled, including the three.
  Still missing there, all optional: `USER_NS`, `IP_VS_NFCT`, `IP_VS_PROTO_TCP`, `IP_VS_PROTO_UDP`, `IP_VS_RR`,
  `CFS_BANDWIDTH`, `FAIR_GROUP_SCHED`, `BLK_DEV_THROTTLING`, `CGROUP_PERF`, `CGROUP_HUGETLB`, `NET_CLS_CGROUP`,
  `CGROUP_NET_PRIO`, `IP_SCTP`, `NFT_*`. `IP_VS` alone gives no working IPVS: it needs a protocol and a scheduler.
  Full output: `check-config.txt`.
- `apk_sign.diff` is the built tree's `apk_sign.c` against KernelSU-Next legacy `165b87fa99ab`. The signing-block
  parser (`read_exact`, `read_length_prefixed_end`, `check_block`, the ZIP64 refusal, the loop over every block, "only
  v2 and verity padding") is identical in logic; what differs is VanillaSU's own: include paths, `ksu_filp_open_compat`,
  the v1-signature refusal, the manager table, and indentation.
- Not tested: the kernel was not flashed or booted (build only); the patched parser was compiled but not run against
  real APKs.

## Measured cost (Evo, WSL2 Ubuntu, container `-j8 --cpus 8 --memory 8g`, no swap)

| | Cold (nothing cached) | Warm (ccache kept, `out/` removed) |
|--|----------------------|-------------------------------------|
| fetch (kernel + VanillaSU clone, clang download + extract) | 290 s (clang is 4 min of it, 446 MB) | 3 s |
| container image (apt) | 41 s | cached |
| kernel build (config, compile, link, package) | 292 s | 173 s |
| **wall total** | **about 10.5 min** | **about 3 min** |

- RAM peak: 5.0 GiB working set (`docker stats`), 7.0 GiB cgroup peak including reclaimable page cache; no OOM
  at the 8 GB limit. (The `peak_working_set_mib=912` line in the cold run's `metrics.txt` is a parsing bug since
  fixed; the sampled `memory.csv` gives 5052 MiB.)
- Disk (all on ext4): clang 1.4 GB, kernel tree with git 1.6 GB, `out/` 3.0 GB, ccache 0.6 GB, container image
  0.75 GB; about 7.4 GB. Artifacts about 41 MB.
- Patch size: 8 added defconfig lines (4 options), +143/-98 in one C file (listed above).
- Hands-on time: none once the pins are set; the run is one command.

## Monthly update (new maintainer commit)

1. Set `KERNEL_SHA` and `VANILLASU_SHA` in `pins.env` (the kernel's recorded submodule commit:
   `gh api repos/vanilla-kernel/VanillaKernel/contents/VanillaSU?ref=<sha> --jq .sha`). `build.sh fetch` stops if they disagree.
2. `build.sh patch`. A patch that no longer applies stops it with the file name. Expected cases: the `apk_sign.c` patch
   conflicts if VanillaSU touched that file, and becomes redundant once VanillaSU merges the upstream fix (`grep -c
   read_length_prefixed_end` is then non-zero; delete the patch, `verify` still checks the markers). The defconfig
   patches conflict only if the fragment's tail or the networking block moves.
3. Read the maintainer's diff of `tools/build.sh` and `.github/workflows/build.yml` (the recipe): the clang pin, the
   defconfigs, the `-j` flags. Update `pins.env` and `container/` if they changed.
4. `build.sh all` (about 6 min warm), then `THIN_PATCHES=none ... build.sh crc` and compare `crc.txt` again.

Dry run on 2026-10-31 against the maintainers' newest commits (VanillaKernel `c8303954a2f4`, VanillaSU `07ca9ff11749`):
both patch sets pass `git apply --check` unchanged, and `grep read_length_prefixed_end` is 0, so the fix is still
needed there. Their tip moved to a `lineage-24.0` base and changed `tools/build.sh` (branch-naming and indentation
only; the make flags are the same). Cost of a typical month: about 15 minutes of reading and pin edits plus a 6 minute
build; a conflict in `apk_sign.c` adds a manual port.

## Tests

    pwsh C:\000CHESTA-CODE\dotfiles\bin\test-all.ps1 -Name 'thin/tests/build.Tests.ps1'

Pester 5 against an offline fixture in WSL: a wrong clang tree digest, a wrong file sha256, an unfetchable kernel
commit and a VanillaSU pin that disagrees with the kernel's submodule are all refused.

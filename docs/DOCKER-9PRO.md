# Docker on the OnePlus 9 Pro (VanillaKernel 5.4.302-qgki, KernelSU root)

Written 2026-10-30. Everything here was written and tested OFFLINE (stub `mount`/`dockerd`, fake `adb`);
nothing has run on the phone yet. Kai runs the sequence below and sends back what is listed under
"If it fails".

## The path chosen, and why (least fragile)

**The official static Docker bundle, run directly on the Android host as root, with `dockerd` inside a
private mount namespace.** No chroot, no second userland, no Termux build of Docker.

| Option | Verdict |
|---|---|
| Static bundle from download.docker.com (dockerd, containerd, runc, docker-init, proxy; all statically linked Go) | chosen: one tarball, pinned, nothing to compile, runs on any arm64 Linux kernel |
| Docker built inside Termux (gist hnmn) | needs compiling dockerd/containerd/runc by hand and patched paths; breaks on every Termux update |
| Alpine/Debian chroot with Docker inside (CGCL Android-Container) | works, but a second userland to keep alive, and bind-mounts /dev,/proc,/sys by hand |
| Droidspaces | runs full distros (and Docker inside them) but wants its own kernel integration; we already have the kernel and do not need a distro |
| termux-docker | an image to run Termux in Docker on a PC; not for running Docker on the phone |

Two Android problems the plain recipes solve badly, and what we do instead:

1. **cgroups.** Docker wants a tmpfs on `/sys/fs/cgroup` with one v1 mount per controller. Android already
   uses `/sys/fs/cgroup` (libprocessgroup) so the gist/CGCL recipes, which mount a tmpfs over it globally,
   risk breaking Android. We start dockerd with `unshare -m` and build the tmpfs + cgroup mounts inside that
   private namespace (`tools/docker-daemon.sh`); the script then checks `/proc/1/mountinfo` to prove nothing
   leaked. Controllers Android already mounts re-attach to the same hierarchy. If memory is not on a v1
   hierarchy (Android 16 may put it on cgroup v2) the script falls back to a cgroup2 mount.
2. **No `/etc/resolv.conf`.** Android has none and Go (dockerd, containerd) then asks 127.0.0.1:53, so
   image pulls fail. Inside the same private namespace a tmpfs replaces `/system/etc` (entries symlinked
   back, plus a `resolv.conf`). `/system` itself is never written.

Other decisions: data-root `/data/docker/root` (never `/system`), overlay2 if a probe mount works else vfs,
`ipv6: false`, `ip-forward-no-drop` (Docker will not set the FORWARD policy to DROP on Android),
`containerd-snapshotter` off (classic overlay2). Bridge networking if `iptables -t nat` works, else
host-only (`--iptables=false --bridge=none`; run containers with `--network host`). Android policy-routes
by fwmark, so `docker-up.sh` adds `ip rule pref 5999 from the Docker bridge range (DOCKER_BRIDGE_CIDR) lookup <default-network table>`
for containers; `docker-down.sh` removes it. The kernel lacks IP6_NF_NAT and the IPVS match: not needed.

Sources: Droidspaces wiki https://github.com/ravindu644/Droidspaces-OSS/wiki ; cgroup wrapper + `/data/docker`
+ `--iptables=false` https://gist.github.com/hnmn/b110d3840af8653d077d42382454eccb ; cgroup mount list
https://github.com/CGCL-codes/Android-Container/blob/main/files/dockerd.sh ; static bundle
https://download.docker.com/linux/static/stable/aarch64/ ; compose release
https://github.com/docker/compose/releases/tag/v5.6.1 . Docker's own `contrib/check-config.sh` (already run).

## Files

| File | Runs on | Job |
|---|---|---|
| `tools/push-docker.ps1` | Evo | download pinned bundle + compose, check sha256, `adb -s <serial>` push + install; dry run by default |
| `tools/docker-pin.json` | - | pinned versions and sha256 |
| `tools/docker-install.sh` | phone | verify sha256 again, unpack to `/data/docker/bin`, copy scripts to `/data/docker/tools` |
| `tools/docker-up.sh` | phone | start dockerd (idempotent, refuses if running, logs to `/data/docker/log/dockerd.log`) |
| `tools/docker-daemon.sh` | phone | internal: namespace setup, then `exec dockerd` |
| `tools/docker-down.sh` | phone | stop dockerd, remove the routing rule |
| `tools/docker-proof.sh` | phone | `hello-world` + `alpine` with networking, one-screen proof |
| `tools/docker-boot-service.sh` | phone | OPT-IN KernelSU `service.d` script that runs docker-up at boot |
| `compose/b-worker`, `c-sensors`, `a-timelapse` | phone | the three roles |

## Kai's sequence tonight (Evo, PowerShell; phone serial 5d7a3c0)

```powershell
cd C:\000CHESTA-CODE\op9pro-kernel          # after the PR is merged, or the worktree
# 0. once: record the Docker bundle's sha256 (downloads 74 MB, no adb), then commit docker-pin.json
pwsh tools/push-docker.ps1 -RecordHash
# 1. dry run, then push + install
pwsh tools/push-docker.ps1 -Serial 5d7a3c0
pwsh tools/push-docker.ps1 -Serial 5d7a3c0 -Execute
# 2. start
adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-up.sh'"
# 3. proof
adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-proof.sh'"
# stop
adb -s 5d7a3c0 shell "su -c 'sh /data/docker/tools/docker-down.sh'"
```

Interactive docker on the phone: `adb -s 5d7a3c0 shell`, then `su`, then
`. /data/docker/tools/docker-common.sh; docker ps`.

### If it fails, send back

```powershell
adb -s 5d7a3c0 shell "su -c 'cat /data/docker/log/diag.txt; tail -n 80 /data/docker/log/dockerd.log'"
adb -s 5d7a3c0 shell "su -c 'dmesg | tail -n 40'"
```

`diag.txt` holds /proc/cgroups, the cgroup mounts, SELinux mode, iptables version, toybox applets, the data
filesystem, ip rules and default routes. Likely first failures and the switch for each:

* "no 'unshare'" -> toybox lacks it; send diag.txt (fallback: Termux busybox).
* AVC denials in `dmesg` / "permission denied" in runc -> retry once with `docker-up.sh --selinux-permissive`
  (global until reboot; deliberately not the default).
* "leaked into the global namespace" -> `mount --make-rprivate /` unsupported by this toybox; send diag.txt.
* Containers start but no internet -> send `ip rule` and `ip route show table all | grep default`.

## Roles (compose files, Docker Compose standalone: `docker-compose`)

Compose ships as `/data/docker/bin/docker-compose`. Run from a directory pushed to the phone, e.g.
`adb -s 5d7a3c0 push compose /data/docker/compose`, then
`su -c ". /data/docker/tools/docker-common.sh; cd /data/docker/compose/b-worker && docker-compose up -d --build"`.
Restart policies are `unless-stopped`; they only come back after a reboot if the opt-in boot service is installed.

**B - neoClaw worker (first).** `compose/b-worker`: Alpine + openssh + python3 + git, host network, sshd on
2222, key auth only, user `worker`. Needs the Evo's public key in `/data/docker/shared/b-worker/authorized_keys`
(Kai: `adb push` it, `su -c mkdir -p` first). Reachable at `ssh -p 2222 worker@<phone tailnet address>` as long as the
phone's Tailscale app is up (the container does not run Tailscale itself).

**C - sensors.** `compose/c-sensors`: containers cannot read Android sensors (they sit behind the Termux:API
app / binder). The HOST runs `host-sensor-logger.sh` in Termux (needs Termux:API; the plan already flags that
APK install as Kai's decision) writing `~/sensors/*.jsonl`; the container reads that folder read-only, keeps
`/data/docker/shared/c-sensors/sensors.csv` and optionally POSTs to neoClaw (`SHIP_URL`).

**A - time-lapse (honest answer).** A container cannot reach the phone's cameras: they are behind the camera
HAL (binder + SELinux) and there is no `/dev/videoN`. Capture therefore runs on the HOST in Termux
(`compose/a-timelapse/host-capture.sh`, `termux-camera-photo`, also `sh host-capture.sh once` for the
"photo now" hook). The container only serves `~/timelapse` over HTTP on :8081 and prunes photos older than
60 days, so Docker adds little for A; it is optional.

## Power and phone notes

Docker does not touch charging: the root governor keeps 75-80 %; never use Charging Control. The phone has a
dead touchscreen: everything above is adb-driven. Data under `/data/docker` is lost on a ROM flash or format.

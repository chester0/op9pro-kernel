#!/usr/bin/env bash
# thin/build.sh - build "our thin kernel" for the OnePlus 9 Pro (lemonadep):
#   the maintainer's pinned kernel + VanillaSU, our patches on top, built in a container, packaged as AnyKernel3.
#
# Run it inside WSL Ubuntu (Docker is the WSL engine). Caches and sources live on WSL's ext4 (THIN_HOME), never /mnt/c.
#
#   thin/build.sh all            fetch + patch + image + build + verify (the whole pipeline)
#   thin/build.sh fetch          clone/download every input at its pin and verify it
#   thin/build.sh fetch-kernel | fetch-clang | fetch-checkconfig | fetch-apksign-ref   (one input)
#   thin/build.sh patch          apply thin/patches/** to the fetched trees (idempotent)
#   thin/build.sh image          build the build container image
#   thin/build.sh build          run the container: config, build, package (needs fetch+patch+image)
#   thin/build.sh verify         3 options in .config, apk_sign.c vs upstream, moby check-config, sha256s
#   thin/build.sh crc            dump the built vmlinux's exported-symbol CRCs (kABI check against a baseline)
#
# Environment (all optional):
#   PINS_FILE   pins to use (default: thin/pins.env)         THIN_HOME  work root (default: ~/op9thin)
#   BUILD_JOBS  make -j (default 8)                           BUILD_MEM  container memory limit (default 8g)
#   OUT_DIR     where finished artifacts are copied (default: $THIN_HOME/out/thin-<date>)
#   THIN_PATCHES=none   build the maintainer's unpatched source (baseline for A/B comparison)
set -euo pipefail

THIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS_FILE="${PINS_FILE:-${THIN_DIR}/pins.env}"
THIN_HOME="${THIN_HOME:-${HOME}/op9thin}"
BUILD_JOBS="${BUILD_JOBS:-8}"
BUILD_MEM="${BUILD_MEM:-8g}"
OUT_DIR="${OUT_DIR:-${THIN_HOME}/out/thin-$(date +%Y%m%d)}"
IMAGE_TAG="op9thin-build:1"

CACHE_DIR="${THIN_HOME}/cache"
SRC_DIR="${THIN_HOME}/src"
KERNEL_DIR="${SRC_DIR}/kernel"
VANILLASU_DIR="${KERNEL_DIR}/VanillaSU"
CCACHE_HOST_DIR="${CACHE_DIR}/ccache"
METRICS_FILE="${OUT_DIR}/metrics.txt"

die() {
    echo "build.sh: ERROR: $*" >&2
    exit 1
}

log() {
    echo "build.sh: $*"
}

load_pins() {
    [ -f "${PINS_FILE}" ] || die "pins file not found: ${PINS_FILE}"
    # shellcheck source=/dev/null
    . "${PINS_FILE}"
}

# fetch_file URL SHA256 DEST - download once, refuse any content whose sha256 is not the pin.
fetch_file() {
    local url="$1" want="$2" dest="$3" got
    mkdir -p "$(dirname "${dest}")"
    if [ -f "${dest}" ]; then
        got="$(sha256sum "${dest}" | cut -d' ' -f1)"
        if [ "${got}" = "${want}" ]; then
            log "cached and verified: ${dest}"
            return 0
        fi
        log "cached file has the wrong sha256, downloading again: ${dest}"
        rm -f "${dest}"
    fi
    log "downloading ${url}"
    curl -fsSL --retry 3 --retry-delay 5 -o "${dest}.part" "${url}" || {
        rm -f "${dest}.part"
        die "download failed: ${url}"
    }
    got="$(sha256sum "${dest}.part" | cut -d' ' -f1)"
    if [ "${got}" != "${want}" ]; then
        rm -f "${dest}.part"
        die "sha256 mismatch for ${url}: pinned ${want}, got ${got}; refusing it"
    fi
    mv "${dest}.part" "${dest}"
}

# fetch_git URL SHA DEST - shallow-fetch exactly one commit; refuse if HEAD is not the pinned SHA.
fetch_git() {
    local url="$1" want="$2" dest="$3" head
    if [ -d "${dest}/.git" ] && [ "$(git -C "${dest}" rev-parse HEAD 2>/dev/null || true)" = "${want}" ]; then
        log "already at pin ${want}: ${dest}"
        return 0
    fi
    # A tree at the wrong commit is thrown away whole (including out/ and the nested VanillaSU).
    rm -rf "${dest:?}"
    mkdir -p "${dest}"
    git -C "${dest}" init -q
    git -C "${dest}" fetch -q --depth 1 "${url}" "${want}" ||
        die "cannot fetch pinned commit ${want} from ${url}"
    git -C "${dest}" checkout -q --detach FETCH_HEAD
    head="$(git -C "${dest}" rev-parse HEAD)"
    [ "${head}" = "${want}" ] || die "pin mismatch: wanted ${want}, got ${head} from ${url}"
}

fetch_kernel() {
    load_pins
    fetch_git "${KERNEL_URL}" "${KERNEL_SHA}" "${KERNEL_DIR}"
    local gitlink
    gitlink="$(git -C "${KERNEL_DIR}" ls-tree HEAD VanillaSU | awk '{print $3}')"
    [ "${gitlink}" = "${VANILLASU_SHA}" ] ||
        die "kernel ${KERNEL_SHA} records VanillaSU ${gitlink}, but the pin is ${VANILLASU_SHA}; update both pins together"
    fetch_git "${VANILLASU_URL}" "${VANILLASU_SHA}" "${VANILLASU_DIR}"
}

# tree_digest DIR - sha256 of the directory's content (names, modes, links, bytes; not mtimes or owners).
tree_digest() {
    (cd "$1" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | cut -d' ' -f1)
}

# 2026-10-30: googlesource builds the clang .tar.gz on the fly and two downloads of the same commit differ
# byte for byte (different sha256), so the tarball cannot be pinned. The extracted tree is identical every
# time (checked with two downloads), so the pin is the digest of the tree.
fetch_clang() {
    load_pins
    local tree="${CACHE_DIR}/${CLANG_NAME}-${CLANG_TREE_SHA256:0:12}" tmp got
    if [ -x "${tree}/bin/clang" ] && [ "$(tree_digest "${tree}")" = "${CLANG_TREE_SHA256}" ]; then
        log "cached and verified: ${tree}"
    else
        rm -rf "${tree:?}"
        tmp="${tree}.part"
        rm -rf "${tmp:?}"
        mkdir -p "${tmp}"
        log "downloading ${CLANG_URL}"
        curl -fsSL --retry 3 --retry-delay 5 "${CLANG_URL}" | tar -xz -C "${tmp}" ||
            die "download or extraction failed: ${CLANG_URL}"
        got="$(tree_digest "${tmp}")"
        if [ "${got}" != "${CLANG_TREE_SHA256}" ]; then
            rm -rf "${tmp:?}"
            die "sha256 mismatch for the clang tree from ${CLANG_URL}: pinned ${CLANG_TREE_SHA256}, got ${got}; refusing it"
        fi
        [ -x "${tmp}/bin/clang" ] || die "clang binary missing after extraction: ${tmp}"
        mv "${tmp}" "${tree}"
    fi
    ln -sfn "${tree}" "${CACHE_DIR}/clang"
}

fetch_checkconfig() {
    load_pins
    fetch_file "${CHECKCONFIG_URL}" "${CHECKCONFIG_SHA256}" "${CACHE_DIR}/check-config.sh"
}

fetch_apksign_ref() {
    load_pins
    fetch_file "${APKSIGN_REF_URL}" "${APKSIGN_REF_SHA256}" "${CACHE_DIR}/apk_sign.ref.c"
}

cmd_fetch() {
    fetch_kernel
    fetch_clang
    fetch_checkconfig
    fetch_apksign_ref
}

apply_dir() {
    local tree="$1" patch_dir="$2" patch
    [ -d "${tree}/.git" ] || die "tree not fetched: ${tree}"
    # Patches touch tracked files only, so restoring tracked files makes this idempotent.
    git -C "${tree}" checkout -q -- .
    for patch in "${patch_dir}"/*.patch; do
        [ -e "${patch}" ] || continue
        log "applying $(basename "${patch}") to ${tree}"
        git -C "${tree}" apply --check "${patch}" || die "patch does not apply: ${patch}"
        git -C "${tree}" apply "${patch}"
    done
}

cmd_patch() {
    if [ "${THIN_PATCHES:-all}" = none ]; then
        # Baseline: the maintainer's exact source, for A/B comparison (crc, size). Restores tracked files only.
        git -C "${KERNEL_DIR}" checkout -q -- .
        git -C "${VANILLASU_DIR}" checkout -q -- .
        log "THIN_PATCHES=none: trees restored, no patch applied"
        return 0
    fi
    apply_dir "${KERNEL_DIR}" "${THIN_DIR}/patches/kernel"
    apply_dir "${VANILLASU_DIR}" "${THIN_DIR}/patches/vanillasu"
}

# Exported-symbol CRCs (modversions) of the built vmlinux. The phone's vendor modules are checked against them,
# so a patch that changes a CRC could stop a vendor module loading. Compare a baseline's crc.txt to ours.
cmd_crc() {
    load_pins
    "${CACHE_DIR}/clang/bin/llvm-nm" "${KERNEL_DIR}/out/vmlinux" |
        awk '$3 ~ /^__crc_/ { print $3, $1 }' | LC_ALL=C sort > "${OUT_DIR}/crc.txt"
    log "$(wc -l < "${OUT_DIR}/crc.txt") exported-symbol CRCs -> ${OUT_DIR}/crc.txt"
}

cmd_image() {
    load_pins
    docker build -q -t "${IMAGE_TAG}" --build-arg "BASE_IMAGE=${BUILD_BASE_IMAGE}" "${THIN_DIR}/container"
}

now() { date +%s; }

cmd_build() {
    load_pins
    [ -x "${CACHE_DIR}/clang/bin/clang" ] || die "clang not fetched (run: build.sh fetch)"
    [ -f "${KERNEL_DIR}/tools/build.sh" ] || die "kernel not fetched (run: build.sh fetch)"
    mkdir -p "${OUT_DIR}" "${CCACHE_HOST_DIR}"
    local zip_name="VanillaKernel-thin-${KERNEL_SHA:0:7}-${VANILLASU_SHA:0:7}.zip" start sampler
    start="$(now)"
    # Sample the container's working set (docker stats: usage minus reclaimable page cache) every 10 s.
    : > "${OUT_DIR}/memory.csv"
    (
        while true; do
            docker stats --no-stream --format '{{.MemUsage}}' op9thin-build 2> /dev/null >> "${OUT_DIR}/memory.csv" || true
            sleep 10
        done
    ) &
    sampler=$!
    # --memory-swap equal to --memory: no swap, so the 8 GB limit is a real limit.
    docker run --rm --name op9thin-build \
        --user "$(id -u):$(id -g)" \
        --memory "${BUILD_MEM}" --memory-swap "${BUILD_MEM}" --cpus "${BUILD_JOBS}" \
        -e "BASE_DEFCONFIG=${BASE_DEFCONFIG}" -e "FRAGMENT_DEFCONFIG=${FRAGMENT_DEFCONFIG}" \
        -e "ZIP_NAME=${zip_name}" -e "BUILD_JOBS=${BUILD_JOBS}" \
        -v "${KERNEL_DIR}:/src" -v "${CACHE_DIR}/clang/:/clang:ro" -v "${CCACHE_HOST_DIR}:/ccache" \
        -v "${OUT_DIR}:/artifacts" \
        "${IMAGE_TAG}" 2>&1 | tee "${OUT_DIR}/build.log"
    kill "${sampler}" 2> /dev/null || true
    echo "build_seconds=$(($(now) - start))" | tee -a "${METRICS_FILE}"
    # cgroup peak counts page cache too (it is reclaimable); the working-set peak is the honest RAM need.
    grep -h MEMORY_PEAK_BYTES "${OUT_DIR}/build.log" | tee -a "${METRICS_FILE}" || true
    awk -F'[ /]+' '{ v = $1; if (v ~ /GiB$/) { sub(/GiB/, "", v); v = v * 1024 } else if (v ~ /MiB$/) { sub(/MiB/, "", v); v = v + 0 } else next
                     if (v > m) m = v } END { printf "peak_working_set_mib=%d\n", m }' "${OUT_DIR}/memory.csv" |
        tee -a "${METRICS_FILE}"
}

cmd_verify() {
    load_pins
    local cfg="${OUT_DIR}/config" opt ref="${CACHE_DIR}/apk_sign.ref.c" mine="${VANILLASU_DIR}/kernel/manager/apk_sign.c"
    [ -f "${cfg}" ] || die "no built .config at ${cfg} (run: build.sh build)"

    log "docker options in the built .config:"
    for opt in CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE CONFIG_NETFILTER_XT_MATCH_IPVS CONFIG_IP_VS; do
        grep -x "${opt}=y" "${cfg}" || die "${opt}=y is not in the built .config"
    done

    log "apk_sign.c markers of the upstream fix (e6cc0ef7b0 + aa08b390cd):"
    grep -c 'read_length_prefixed_end' "${mine}" > /dev/null || die "apk_sign.c lacks the bounded block parser"
    grep -n 'id != 0x42726577u' "${mine}" || die "apk_sign.c does not reject unknown signature block ids"
    grep -n 'zip64_locator_magic == 0x07064b50' "${mine}" || die "apk_sign.c does not reject ZIP64"
    if grep -q 'loop_count++ < 10' "${mine}"; then
        die "apk_sign.c still stops after ten signature blocks"
    fi

    log "diff of our apk_sign.c against KernelSU-Next legacy (the reference carrying the fix) -> ${OUT_DIR}/apk_sign.diff"
    diff -u "${ref}" "${mine}" > "${OUT_DIR}/apk_sign.diff" || true
    diffstat_line="$(grep -c '^[+-][^+-]' "${OUT_DIR}/apk_sign.diff" || true)"
    log "changed lines vs reference: ${diffstat_line} (VanillaSU's own differences: includes, helpers, v1 check, manager table)"

    log "moby check-config -> ${OUT_DIR}/check-config.txt"
    bash "${CACHE_DIR}/check-config.sh" "${cfg}" > "${OUT_DIR}/check-config.txt" 2>&1 || true
    grep -E 'CONFIG_(IP6_NF_NAT|IP6_NF_TARGET_MASQUERADE|NETFILTER_XT_MATCH_IPVS|IP_VS)[: ]' "${OUT_DIR}/check-config.txt" || true

    log "sha256 of the artifacts:"
    (cd "${OUT_DIR}" && sha256sum ./*.zip Image.gz config | tee SHA256SUMS)
}

# stage NAME COMMAND... - run one pipeline stage and append its wall seconds to metrics.txt.
stage() {
    local name="$1" t
    shift
    t="$(now)"
    "$@"
    echo "${name}_seconds=$(($(now) - t))" | tee -a "${METRICS_FILE}"
}

report_disk() {
    {
        echo "disk_mib_clang=$(du -sm "${CACHE_DIR}/clang/" | cut -f1)"
        echo "disk_mib_ccache=$(du -sm "${CCACHE_HOST_DIR}" | cut -f1)"
        echo "disk_mib_kernel_tree_with_git=$(du -sm --exclude=out "${KERNEL_DIR}" | cut -f1)"
        echo "disk_mib_kernel_out=$(du -sm "${KERNEL_DIR}/out" | cut -f1)"
        echo "disk_mib_container_image=$(($(docker image inspect "${IMAGE_TAG}" --format '{{.Size}}') / 1048576))"
    } | tee -a "${METRICS_FILE}"
}

cmd_all() {
    local start
    start="$(now)"
    mkdir -p "${OUT_DIR}"
    stage fetch cmd_fetch
    stage patch cmd_patch
    stage image cmd_image
    cmd_build
    stage verify cmd_verify
    report_disk
    echo "total_seconds=$(($(now) - start))" | tee -a "${METRICS_FILE}"
}

case "${1:-}" in
    all) cmd_all ;;
    fetch) cmd_fetch ;;
    fetch-kernel) fetch_kernel ;;
    fetch-clang) fetch_clang ;;
    fetch-checkconfig) fetch_checkconfig ;;
    fetch-apksign-ref) fetch_apksign_ref ;;
    patch) cmd_patch ;;
    image) cmd_image ;;
    build) cmd_build ;;
    verify) cmd_verify ;;
    crc) cmd_crc ;;
    *) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac

#!/usr/bin/env bash
# Runs INSIDE the build container. Reproduces the maintainer's CI steps "Build config", "Verify defconfig
# fragment", "Build kernel" and "Pack AnyKernel3 zip" with their own scripts (tools/build.sh,
# tools/check-fragment.sh, tools/anykernel3), unmodified.
#
# Mounts: /src = patched kernel tree, /clang = clang toolchain, /ccache = compiler cache, /artifacts = output.
# Env:    BASE_DEFCONFIG, FRAGMENT_DEFCONFIG, ZIP_NAME, BUILD_JOBS (read by the nproc shim).
set -euo pipefail

export PATH="/clang/bin:${PATH}"
export HOME=/tmp/home
mkdir -p "${HOME}"
# The tree is owned by the invoking host user; git inside the container must accept it.
git config --global --add safe.directory /src

export CCACHE_DIR=/ccache
ccache -M 5G
ccache -z

clang --version | head -n 1

# Reproducibility: the kernel banner embeds user, host and build time. Fix them to constants derived from the
# pinned commit, so the same inputs give the same Image.gz (a rebuild's sha256 must equal the first build's).
epoch="$(git show -s --format=%ct HEAD)"
export KBUILD_BUILD_USER=thin
export KBUILD_BUILD_HOST=op9pro-thin
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP="$(date -u -d "@${epoch}")"

if [ "${RECIPE:-vanilla}" = levion ]; then
    # 2026-10-31: Levion's recipe (its .github/compile.sh: same make flags, "vendor/lahaina-qgki_defconfig"), plus
    # our fragment merged with the kernel's own merge_config.sh. Only the Image is built: the phone keeps its
    # vendor modules, and the exported-symbol CRCs that decide whether they load are in vmlinux.
    make_flags=(O=out ARCH=arm64 LLVM=1 CC="ccache clang" LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
        OBJDUMP=llvm-objdump READELF=llvm-readelf OBJSIZE=llvm-size STRIP=llvm-strip
        CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-)
    make "${make_flags[@]}" "${BASE_DEFCONFIG}"
    if [ -n "${FRAGMENT_DEFCONFIG}" ]; then
        ARCH=arm64 LLVM=1 ./scripts/kconfig/merge_config.sh -m -O out out/.config "${FRAGMENT_DEFCONFIG}"
        make "${make_flags[@]}" olddefconfig
        while IFS= read -r opt; do
            grep -qx "${opt}" out/.config || { echo "fragment option not applied: ${opt}" >&2; exit 1; }
        done < <(grep -E '^CONFIG_[A-Z0-9_]+=y$' "${FRAGMENT_DEFCONFIG}")
    fi
    make -j"${BUILD_JOBS}" "${make_flags[@]}" Image
    test -f out/arch/arm64/boot/Image
    cp out/arch/arm64/boot/Image /artifacts/Image
    cp out/.config /artifacts/config
    ccache -s
    if [ -r /sys/fs/cgroup/memory.peak ]; then
        echo "MEMORY_PEAK_BYTES=$(cat /sys/fs/cgroup/memory.peak)"
    fi
    exit 0
fi

./tools/build.sh config "${BASE_DEFCONFIG}" "${FRAGMENT_DEFCONFIG}"
./tools/check-fragment.sh "${FRAGMENT_DEFCONFIG}" out/.config
./tools/build.sh kernel
ccache -s

IMAGE=out/arch/arm64/boot/Image.gz
test -f "${IMAGE}"

# Package exactly as the maintainer's CI does (their tools/anykernel3 + Image.gz). Two differences, both for
# reproducibility only: file mtimes are fixed to the kernel commit time and the entry order is sorted, so the
# same inputs give the same zip bytes; -X drops extra file attributes.
package_dir="$(mktemp -d)"
cp -a tools/anykernel3/. "${package_dir}/"
cp "${IMAGE}" "${package_dir}/"
find "${package_dir}" -exec touch -h -d "@${epoch}" {} +
(cd "${package_dir}" && find . -mindepth 1 | LC_ALL=C sort | zip -X -9 -@ "/artifacts/${ZIP_NAME}" > /dev/null)
cp "${IMAGE}" /artifacts/Image.gz
cp out/.config /artifacts/config
rm -rf "${package_dir}"

# Peak memory of this container (cgroup v2), for the cost table.
if [ -r /sys/fs/cgroup/memory.peak ]; then
    echo "MEMORY_PEAK_BYTES=$(cat /sys/fs/cgroup/memory.peak)"
fi

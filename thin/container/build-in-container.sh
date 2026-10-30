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
epoch="$(git show -s --format=%ct HEAD)"
find "${package_dir}" -exec touch -h -d "@${epoch}" {} +
(cd "${package_dir}" && find . -mindepth 1 | LC_ALL=C sort | zip -X -9 -@ "/artifacts/${ZIP_NAME}" > /dev/null)
cp "${IMAGE}" /artifacts/Image.gz
cp out/.config /artifacts/config
rm -rf "${package_dir}"

# Peak memory of this container (cgroup v2), for the cost table.
if [ -r /sys/fs/cgroup/memory.peak ]; then
    echo "MEMORY_PEAK_BYTES=$(cat /sys/fs/cgroup/memory.peak)"
fi

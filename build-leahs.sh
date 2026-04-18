#!/bin/bash
# Build OP9 Pro kernel from Leahs android_kernel_oneplus_sm8350 ksunext-susfs-2.1.0 branch
# Base: LineageOS lineage-23.0 + KernelSU-Next v3.0.1-legacy + SUSFS v2.1.0 (pre-integrated)
# Note: No KPM — KernelSU-Next does not support KPM (that's SukiSU-specific)
set -eo pipefail

export PATH=/work/toolchain-aosp/r416183b/bin:/work/toolchain/bin:$PATH
export KBUILD_BUILD_USER="chester"
export KBUILD_BUILD_HOST="op9build"

MAKE_FLAGS=(
  O=out
  ARCH=arm64
  LLVM=1
  LLVM_IAS=1
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
)

cd /work/kernel4

echo "=== [1/4] make defconfig ==="
make "${MAKE_FLAGS[@]}" vendor/lahaina-qgki_defconfig

echo "=== [2/4] baseline test — Leahs defconfig as-is, no overrides ==="

echo "=== [3/4] olddefconfig to lock in ==="
make "${MAKE_FLAGS[@]}" olddefconfig

echo "--- KSU/SUSFS settings from defconfig: ---"
grep -E "^(CONFIG_KSU|CONFIG_KPM)" out/.config || true

echo "=== [4/4] building Image ==="
make "${MAKE_FLAGS[@]}" -j"$(nproc)" Image

echo ""
echo "=== BUILD COMPLETE ==="
ls -lh out/arch/arm64/boot/Image

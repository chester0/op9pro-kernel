#!/bin/bash
# Minimal kernel3 build — Matrixx-Devices/android_kernel_oneplus_sm8350 (has oplus drivers)
# + SukiSU-Ultra but with ZERO SUSFS feature overrides
# + AOSP clang-r416183b (the correct toolchain)
# Goal: confirm base kernel boots on OP9 Pro, then layer features
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

cd /work/kernel3

echo "=== [1/4] make defconfig (Matrixx lahaina-qgki with oplus drivers) ==="
make "${MAKE_FLAGS[@]}" vendor/lahaina-qgki_defconfig

echo "=== [2/4] enable SukiSU only, no SUSFS features ==="
./scripts/config --file out/.config \
  -e KSU \
  -e KSU_MANUAL_HOOK \
  -d KSU_KPROBES_HOOK \
  -d KSU_DEBUG \
  -e KSU_SUSFS \
  -e KSU_SUSFS_SUS_PATH \
  -e KSU_SUSFS_SUS_MOUNT \
  -e KSU_SUSFS_SUS_KSTAT \
  -e KSU_SUSFS_TRY_UMOUNT \
  -e KSU_SUSFS_SPOOF_UNAME \
  -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
  -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
  -e KSU_SUSFS_OPEN_REDIRECT \
  -e KSU_SUSFS_SUS_MAP \
  -e KSU_SUSFS_ENABLE_LOG \
  -e KPM

echo "=== [3/4] olddefconfig to lock in ==="
make "${MAKE_FLAGS[@]}" olddefconfig

echo "--- KSU/OPLUS settings: ---"
grep -E "^(CONFIG_KSU|CONFIG_OPLUS_SYSTEM_KERNEL_QCOM)" out/.config || true

echo "=== [4/4] building Image ==="
make "${MAKE_FLAGS[@]}" -j"$(nproc)" Image

echo ""
echo "=== BUILD COMPLETE ==="
ls -lh out/arch/arm64/boot/Image

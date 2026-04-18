#!/bin/bash
# Build OP9 Pro kernel with SukiSU-Ultra 4.1.2 (includes SUSFS 2.x with mount hiding)
# Base: Matrixx-Devices/android_kernel_oneplus_sm8350 branch 16.2
set -eo pipefail

export PATH=/work/toolchain/bin:$PATH
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

echo "=== [1/4] make defconfig ==="
make "${MAKE_FLAGS[@]}" vendor/lahaina-qgki_defconfig

echo "=== [2/4] enable SukiSU-Ultra + full SUSFS hiding + KPM ==="
./scripts/config --file out/.config \
  -e KSU \
  -e KSU_MANUAL_HOOK \
  -d KSU_KPROBES_HOOK \
  -d KSU_DEBUG \
  -e KPM \
  -e KSU_SUSFS \
  -e KSU_SUSFS_SUS_PATH \
  -e KSU_SUSFS_SUS_MOUNT \
  -e KSU_SUSFS_SUS_KSTAT \
  -e KSU_SUSFS_TRY_UMOUNT \
  -e KSU_SUSFS_SPOOF_UNAME \
  -d KSU_SUSFS_ENABLE_LOG \
  -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
  -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
  -e KSU_SUSFS_OPEN_REDIRECT \
  -e KSU_SUSFS_SUS_MAP

echo "=== [3/4] olddefconfig to lock in ==="
make "${MAKE_FLAGS[@]}" olddefconfig

echo "--- Applied KSU/SUSFS/KPM settings: ---"
grep -E "^(CONFIG_KSU|CONFIG_KPM)" out/.config || true

echo "=== [4/4] building Image ==="
make "${MAKE_FLAGS[@]}" -j"$(nproc)" Image

echo ""
echo "=== BUILD COMPLETE ==="
ls -lh out/arch/arm64/boot/Image

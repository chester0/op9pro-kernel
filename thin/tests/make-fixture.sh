#!/usr/bin/env bash
# Builds a tiny offline world for thin/tests/build.Tests.ps1: a clang-like tarball, a git repo with one commit
# whose tree records a VanillaSU gitlink, and pins files (good / wrong clang sha / wrong kernel sha / wrong gitlink).
# Usage: make-fixture.sh <empty-dir>      Prints nothing; the test reads the files it creates.
set -euo pipefail

dir="$1"
mkdir -p "${dir}/clang-src/bin" "${dir}/repo" "${dir}/home"

printf '#!/bin/sh\necho fake clang\n' > "${dir}/clang-src/bin/clang"
chmod 0755 "${dir}/clang-src/bin/clang"
tar -czf "${dir}/clang.tar.gz" -C "${dir}/clang-src" .
file_sha="$(sha256sum "${dir}/clang.tar.gz" | cut -d' ' -f1)"
# Same digest build.sh pins for the clang tree (its tree_digest function).
tree_sha="$(cd "${dir}/clang-src" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | cut -d' ' -f1)"

git -C "${dir}/repo" init -q
git -C "${dir}/repo" config user.email test@example.invalid
git -C "${dir}/repo" config user.name test
echo kernel > "${dir}/repo/README"
git -C "${dir}/repo" add README
# A gitlink to a VanillaSU commit that does not exist anywhere: only its recorded id matters to the pin check.
recorded_vsu=1111111111111111111111111111111111111111
git -C "${dir}/repo" update-index --add --cacheinfo "160000,${recorded_vsu},VanillaSU"
git -C "${dir}/repo" commit -q -m fixture
repo_sha="$(git -C "${dir}/repo" rev-parse HEAD)"

write_pins() { # name clang_tree_sha kernel_sha vanillasu_sha
    cat > "${dir}/$1.pins" << EOF
KERNEL_URL=file://${dir}/repo
KERNEL_SHA=$3
VANILLASU_URL=file://${dir}/repo
VANILLASU_SHA=$4
CLANG_NAME=clang-fixture
CLANG_URL=file://${dir}/clang.tar.gz
CLANG_TREE_SHA256=$2
CHECKCONFIG_URL=file://${dir}/clang.tar.gz
CHECKCONFIG_SHA256=${file_sha}
APKSIGN_REF_URL=file://${dir}/clang.tar.gz
APKSIGN_REF_SHA256=${file_sha}
BUILD_BASE_IMAGE=ubuntu:22.04
BASE_DEFCONFIG=x
FRAGMENT_DEFCONFIG=x
EOF
}

zeros=0000000000000000000000000000000000000000
write_pins good "${tree_sha}" "${repo_sha}" "${recorded_vsu}"
write_pins bad-clang "0000000000000000000000000000000000000000000000000000000000000000" "${repo_sha}" "${recorded_vsu}"
sed 's/^CHECKCONFIG_SHA256=.*/CHECKCONFIG_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "${dir}/good.pins" > "${dir}/bad-file.pins"
write_pins bad-kernel "${tree_sha}" "${zeros}" "${recorded_vsu}"
write_pins bad-gitlink "${tree_sha}" "${repo_sha}" "2222222222222222222222222222222222222222"

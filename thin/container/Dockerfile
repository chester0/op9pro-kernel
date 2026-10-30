# Build container for the thin kernel. Same distro as the maintainer's CI runner (ubuntu-22.04) and the same
# apt package list as their .github/workflows/build.yml ("Install build dependencies"), plus git (their
# tools/build.sh reads the commit id) and ca-certificates. Everything else comes in as a mounted, sha256-checked input.
# build-essential: GitHub's runner image already has a host toolchain; the bare ubuntu image does not, and
# HOSTCC (clang, LLVM=1) needs the host ld and libc headers to link the kernel's host tools (fixdep, ...).
# cpio + xz-utils: kernel/gen_kheaders.sh (CONFIG_IKHEADERS) stops with "cpio: not found" without them.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      bc binutils-aarch64-linux-gnu bison build-essential ca-certificates ccache cpio flex gcc-aarch64-linux-gnu git \
      libelf-dev libssl-dev make python3 rsync xz-utils zip \
 && rm -rf /var/lib/apt/lists/*

# 2026-10-30: the maintainer's tools/build.sh sets THREADS=$(nproc --all), which ignores cgroup limits and would
# start every CPU of the host. This shim makes it honour BUILD_JOBS so the maintainer's script runs unmodified
# but capped (default 8).
RUN printf '#!/bin/sh\necho "${BUILD_JOBS:-8}"\n' > /usr/local/bin/nproc && chmod 0755 /usr/local/bin/nproc

COPY build-in-container.sh /usr/local/bin/build-in-container.sh
RUN chmod 0755 /usr/local/bin/build-in-container.sh
WORKDIR /src
ENTRYPOINT ["/usr/local/bin/build-in-container.sh"]

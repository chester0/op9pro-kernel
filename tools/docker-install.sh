#!/system/bin/sh
# docker-install.sh - run ON the phone as root by push-docker.ps1, after adb push to a staging dir:
#   sh docker-install.sh <staging-dir> <docker.tgz name> <docker sha256> <compose name> <compose sha256>
# Verifies both checksums ON the phone (so a corrupt adb transfer is caught too), unpacks the static
# Docker bundle into /data/docker/bin and copies the scripts to /data/docker/tools. Idempotent.
# Refuses while dockerd runs (replacing binaries under a live daemon is asking for trouble).

STAGE="$1"
TGZ="$2"
TGZ_SHA="$3"
COMPOSE="$4"
COMPOSE_SHA="$5"

[ -n "$STAGE" ] && [ -n "$TGZ" ] && [ -n "$TGZ_SHA" ] && [ -n "$COMPOSE" ] && [ -n "$COMPOSE_SHA" ] || {
    echo "usage: sh docker-install.sh <stage> <tgz> <tgz-sha256> <compose> <compose-sha256>" >&2
    exit 2
}

# The scripts are already staged next to this one; load the shared paths from there.
# shellcheck source=docker-common.sh
. "$STAGE/docker-common.sh"

verify() { # file expected-sha256
    actual=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$actual" = "$2" ] || die "sha256 mismatch for $1: got $actual, want $2"
}

require_root
dockerd_pid >/dev/null && die "dockerd is running - run docker-down.sh first"

verify "$STAGE/$TGZ" "$TGZ_SHA"
verify "$STAGE/$COMPOSE" "$COMPOSE_SHA"

mkdir -p "$DOCKER_BIN" "$DOCKER_TOOLS" "$DOCKER_LOG_DIR" "$DOCKER_RUN" "$DOCKER_TMP" "$HOME"
tar -xzf "$STAGE/$TGZ" -C "$DOCKER_BIN" --strip-components=1 || die "tar extract failed"
cp "$STAGE/$COMPOSE" "$DOCKER_BIN/docker-compose"
for f in "$STAGE"/docker-*.sh; do
    cp "$f" "$DOCKER_TOOLS/"
done
chmod 755 "$DOCKER_BIN"/* "$DOCKER_TOOLS"/*.sh
rm -rf "${STAGE:?}"

say "installed:"
ls "$DOCKER_BIN"
"$DOCKER_BIN/dockerd" --version
"$DOCKER_BIN/docker-compose" version

#!/system/bin/sh
# docker-boot-service.sh - OPT-IN: start Docker at every boot via a KernelSU service.d script.
#   sh docker-boot-service.sh install | remove | status        (on the phone, as root)
# Not part of docker-up.sh on purpose: prove Docker works by hand first (docker-proof.sh), then
# opt in. Boot start waits for sys.boot_completed and a default route, then runs docker-up.sh.
# KernelSU runs /data/adb/service.d/*.sh late in boot:
# https://kernelsu.org/guide/module.html (boot scripts).

DIR=$(dirname "$0")
# shellcheck source=docker-common.sh
. "$DIR/docker-common.sh"

SERVICE_DIR="${KSU_SERVICE_DIR:-/data/adb/service.d}"
SERVICE="$SERVICE_DIR/99-docker-up.sh"
BOOT_LOG="$DOCKER_LOG_DIR/boot.log"

install_service() {
    mkdir -p "$SERVICE_DIR" "$DOCKER_LOG_DIR"
    cat >"$SERVICE" <<EOF
#!/system/bin/sh
# Installed by docker-boot-service.sh; remove with: sh $DOCKER_TOOLS/docker-boot-service.sh remove
# Boot start must never block other service.d scripts, hence the background subshell.
(
  until [ "\$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done
  n=0
  until ip route show table all 2>/dev/null | grep -q '^default' || [ "\$n" -ge 24 ]; do n=\$((n + 1)); sleep 5; done
  sh $DOCKER_TOOLS/docker-up.sh
) >>$BOOT_LOG 2>&1 &
EOF
    chmod 755 "$SERVICE"
    say "boot service installed: $SERVICE (log: $BOOT_LOG)"
}

main() {
    require_root
    case "$1" in
        install) install_service ;;
        remove) rm -f "$SERVICE"; say "boot service removed" ;;
        status) if [ -f "$SERVICE" ]; then say "installed: $SERVICE"; else say "not installed"; fi ;;
        *) say "usage: sh docker-boot-service.sh install|remove|status"; exit 2 ;;
    esac
}

main "$@"

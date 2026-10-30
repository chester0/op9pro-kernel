#!/data/data/com.termux/files/usr/bin/sh
# Runs in TERMUX (host side of role A). Needs `pkg install termux-api` + the Termux:API app with
# the camera permission. One still every INTERVAL seconds into ~/timelapse/YYYY-MM-DD/HHMMSS.jpg;
# also: `sh host-capture.sh once` for the neoClaw "photo now" hook.
INTERVAL="${INTERVAL:-900}"
CAMERA_ID="${CAMERA_ID:-0}"
DIR="$HOME/timelapse"

shoot() {
    day=$(date +%F)
    mkdir -p "$DIR/$day"
    termux-camera-photo -c "$CAMERA_ID" "$DIR/$day/$(date +%H%M%S).jpg"
}

if [ "$1" = once ]; then shoot; exit $?; fi
while :; do
    shoot
    sleep "$INTERVAL"
done

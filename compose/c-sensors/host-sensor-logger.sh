#!/data/data/com.termux/files/usr/bin/sh
# Runs in TERMUX on the phone (not in a container, not as root): needs the Termux:API app and
# `pkg install termux-api`. Writes one JSON line per reading to ~/sensors/<sensor>.jsonl.
# Start from Termux:Boot (~/.termux/boot/) with termux-wake-lock, see ../README.md.
# Sensor names differ per phone: list them with `termux-sensor -l`.
SENSORS="${SENSORS:-pressure,light,ambient_temperature}"
INTERVAL_MS="${INTERVAL_MS:-60000}"
DIR="$HOME/sensors"

mkdir -p "$DIR"
# -n 1 returns one reading per call; looping keeps the sensor off between samples (battery).
while :; do
    for s in $(printf '%s' "$SENSORS" | tr ',' ' '); do
        reading=$(termux-sensor -s "$s" -n 1 | tr -d '\n ')
        [ -n "$reading" ] && printf '%s\n' "$reading" >>"$DIR/$s.jsonl"
    done
    sleep $((INTERVAL_MS / 1000))
done

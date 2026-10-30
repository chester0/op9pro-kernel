#!/bin/sh
# Every INTERVAL seconds: take the newest line of each /in/*.jsonl (written by the host's
# host-sensor-logger.sh), append "time,file,json" to /out/sensors.csv, and POST it when SHIP_URL is set.
INTERVAL="${INTERVAL:-60}"
OUT=/out/sensors.csv

while :; do
    for f in /in/*.jsonl; do
        [ -f "$f" ] || continue
        line=$(tail -n 1 "$f")
        [ -n "$line" ] || continue
        printf '%s,%s,%s\n' "$(date -u +%FT%TZ)" "$(basename "$f")" "$line" >>"$OUT"
        if [ -n "${SHIP_URL:-}" ]; then
            wget -q -O /dev/null --header 'Content-Type: application/json' --post-data "$line" "$SHIP_URL" ||
                echo "ship failed for $f" >&2
        fi
    done
    sleep "$INTERVAL"
done

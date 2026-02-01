#!/usr/bin/env bash
set -euo pipefail

PID="$1"
OUT_FILE="$2"
INTERVAL="${3:-1}"

if [ -z "$PID" ] || [ -z "$OUT_FILE" ]; then
  echo "Usage: $0 <pid> <output.json> [intervalSeconds]"
  exit 1
fi

echo '{"system":[' > "$OUT_FILE"
first=true

get_load1() {
  if [ -f /proc/loadavg ]; then
    awk '{print $1}' /proc/loadavg
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/,""); print $1}'
  fi
}

while kill -0 "$PID" >/dev/null 2>&1; do
  ts=$(date +%s)
  cpu=$(ps -p "$PID" -o %cpu= | awk '{print $1}')
  rss_kb=$(ps -p "$PID" -o rss= | awk '{print $1}')
  rss_mb=$(awk "BEGIN {printf \"%.2f\", $rss_kb/1024}")
  load1=$(get_load1)

  if [ "$first" = true ]; then
    first=false
  else
    echo "," >> "$OUT_FILE"
  fi

  echo "{\"ts\":$ts,\"cpuPct\":$cpu,\"rssMb\":$rss_mb,\"load1\":$load1}" >> "$OUT_FILE"
  sleep "$INTERVAL"
done

echo "]}" >> "$OUT_FILE"

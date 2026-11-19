#!/usr/bin/env bash
# Prints the effective transport config each GameServer run's lands ran with: the adapter's
# per-land "Transport encoding configured" line (`TransportAdapter`), without its landID and with
# its fields sorted, counted per distinct config; and how many lands logged "Row addressing
# requested but not in effect". One block per server log (one per encoding run; a restart's
# earlier run is in `<log>.previous`).
#
# CI prints it after each e2e-game step, so two legs' configs can be compared line for line on
# one commit (audit plan V2: the in-turn-off legs with ROW_ADDRESSING on and off run the same
# config). It checks nothing; a log with no config line says so.
# Usage: summarize-effective-config.sh <server log dir>
set -euo pipefail
if [ $# -ne 1 ]; then
  echo "usage: $0 <server log dir>" >&2
  exit 2
fi
shopt -s nullglob
logs=("$1"/gameserver-*.log "$1"/gameserver-*.log.previous)
if [ "${#logs[@]}" -eq 0 ]; then
  echo "no GameServer log in $1"
  exit 0
fi
for log in "${logs[@]}"; do
  plain=$(sed $'s/\x1b\\[[0-9;]*m//g' "$log")
  echo "$(basename "$log"):"
  configs=$(grep -F "[TransportAdapter] Transport encoding configured " <<<"$plain" \
    | sed 's/.*Transport encoding configured //' \
    | tr -d '\r' \
    | awk -F', ' '{ n = 0; for (i = 1; i <= NF; i++) if ($i !~ /^landID=/) f[++n] = $i
        for (i = 2; i <= n; i++) { v = f[i]; j = i - 1; while (j > 0 && f[j] > v) { f[j + 1] = f[j]; j-- } f[j + 1] = v }
        line = ""; for (i = 1; i <= n; i++) line = line (i > 1 ? " " : "") f[i]; print line }' \
    | sort | uniq -c || true)
  if [ -n "$configs" ]; then
    echo "$configs"
  else
    echo "  (no adapter config line)"
  fi
  echo "  requested but not in effect: $(grep -c "Row addressing requested but not in effect" <<<"$plain" || true)"
done

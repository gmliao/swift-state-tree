#!/usr/bin/env bash
# Checks the output of `ROW_ADDRESSING=true ./test-e2e-game.sh` (CI's row addressing step):
#   1. every join negotiated rowAddressing;
#   2. the SDK never closed a connection on a row entry (4013);
#   3. no land logged that row addressing was requested but not in effect;
#   4. the live hero-defense scenarios of each encoding applied row-derived patches. Without it,
#      a server that stopped sending row entries would pass as a copy of the normal run. Other
#      runs (the replay stream, whose frames are JSON objects) may report 0.
# Usage: check-row-addressing-run.sh <run output> <server log dir> <encoding>...
set -euo pipefail
out=$1
log_dir=$2
shift 2

plain=$(sed $'s/\x1b\\[[0-9;]*m//g' "$out")
joins=$(grep -c "Updated state-update features:" <<<"$plain" || true)
without=$(grep "Updated state-update features:" <<<"$plain" | grep -vc "rowAddressing" || true)
echo "Joins: ${joins}, without rowAddressing: ${without}"
if [ "$joins" -eq 0 ] || [ "$without" -ne 0 ]; then
  echo "❌ Not every join negotiated rowAddressing"
  exit 1
fi
if grep -q "Closing the connection: row entry" <<<"$plain"; then
  echo "❌ The SDK closed a connection on a row entry"
  exit 1
fi

# Every server run's log: a restart with the same encoding keeps the earlier run in
# `<log>.previous`. No log at all fails, rather than passing as "no match".
shopt -s nullglob
logs=("$log_dir"/gameserver-*.log "$log_dir"/gameserver-*.log.previous)
if [ "${#logs[@]}" -eq 0 ]; then
  echo "❌ No GameServer log in ${log_dir}"
  exit 1
fi
if grep -q "Row addressing requested but not in effect" "${logs[@]}"; then
  echo "❌ A land ran without row addressing"
  exit 1
fi

for encoding in "$@"; do
  # The first summary line after the encoding's live scenario run starts.
  applied=$(awk -v start="▶ Running GameServer E2E tests (${encoding})..." '
    index($0, start) { inside = 1; next }
    inside && /^Row patches applied: / { print $4; exit }
  ' <<<"$plain")
  echo "Row patches applied (${encoding}, live scenarios): ${applied:-none}"
  if [ -z "$applied" ] || [ "$applied" -eq 0 ]; then
    echo "❌ The ${encoding} live scenarios applied no row-derived patch"
    exit 1
  fi
done
echo "✅ Row addressing in effect"

#!/usr/bin/env bash
# Checks the output of `ROW_ADDRESSING=true ./test-e2e-game.sh` (CI's row addressing step), per
# encoding. Each "▶ Running … (<encoding>…)" section of the output belongs to that encoding.
#
# An opcode encoding (jsonOpcode, messagepack), where row addressing takes effect:
#   1. every join negotiated rowAddressing;
#   2. its live hero-defense scenarios applied row-derived patches. Without it, a server that
#      stopped sending row entries would pass as a copy of the normal run. Other runs (the
#      visibility and resolver lands, whose state has no slot-addressed rows) may report 0.
# json, where it can't (row entries need an opcode encoding, so the server drops the feature):
#   1. no join negotiated rowAddressing;
#   2. no run applied a row-derived patch.
# Every encoding:
#   - the SDK never closed a connection on a row entry (4013);
#   - no land logged that row addressing was requested but not in effect;
#   - every join and every row patch count falls in a section.
# Usage: check-row-addressing-run.sh <run output> <server log dir> <encoding>...
set -euo pipefail
out=$1
log_dir=$2
shift 2

plain=$(sed $'s/\x1b\\[[0-9;]*m//g' "$out")

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

# Per section: "<encoding> <joins> <joins without rowAddressing> <row patches> <live>", one line per
# section with a join or a count; "-" as the encoding for lines before the first section.
sections=$(awk '
  function flush() {
    if (joins + counted > 0) print encoding, joins, without, patches, live
    joins = 0; without = 0; patches = 0; counted = 0
  }
  BEGIN { encoding = "-"; live = 0 }
  /^▶ Running / {
    flush()
    match($0, /\(([A-Za-z]+)/)
    encoding = substr($0, RSTART + 1, RLENGTH - 1)
    live = index($0, "▶ Running GameServer E2E tests (") == 1
    next
  }
  /Updated state-update features:/ { joins++; if ($0 !~ /rowAddressing/) without++ }
  /^Row patches applied: / { patches += $4; counted++ }
  END { flush() }
' <<<"$plain")

if grep -q "^- " <<<"$sections"; then
  echo "❌ Joins or row patch counts before the first section"
  exit 1
fi

for encoding in "$@"; do
  read -r joins without patches live_patches < <(awk -v e="$encoding" '
    $1 == e { j += $2; w += $3; p += $4; if ($5 == 1) lp += $4 }
    END { print j + 0, w + 0, p + 0, lp + 0 }
  ' <<<"$sections")
  echo "${encoding}: joins ${joins}, without rowAddressing ${without}, row patches ${patches} (live scenarios ${live_patches})"
  if [ "$joins" -eq 0 ]; then
    echo "❌ No join in the ${encoding} sections"
    exit 1
  fi
  if [ "$encoding" = "json" ]; then
    if [ "$without" -ne "$joins" ] || [ "$patches" -ne 0 ]; then
      echo "❌ json negotiated rowAddressing or applied row patches"
      exit 1
    fi
  else
    if [ "$without" -ne 0 ]; then
      echo "❌ Not every ${encoding} join negotiated rowAddressing"
      exit 1
    fi
    if [ "$live_patches" -eq 0 ]; then
      echo "❌ The ${encoding} live scenarios applied no row-derived patch"
      exit 1
    fi
  fi
done
echo "✅ Row addressing in effect where it can be"

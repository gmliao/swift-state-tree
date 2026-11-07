#!/usr/bin/env bash
# Runs every cell of the snapshot-baseline matrix (spec §6) and copies the raw
# scalability-matrix JSONs into raw/. Release build; USE_SNAPSHOT_FOR_SYNC=false
# for comparability with deep-research/single-room-entity-scaling.
#
# Serial sync only (`--parallel false`), pinned to CPUs $PIN_CPUS (default 0-7; empty runs
# unpinned, for a smoke test off the measurement machine). After each measured cell, the same
# cell runs again with `--capture-views` and ws-loadtest's verify-views checks that every
# recipient's state rebuilt from its frames equals its projection after every sync; the
# sweep stops at the first cell that fails. The capture is deleted once checked; its report
# stays in raw/<tag>.views.json.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
PIN=()
if [ -n "$PIN_CPUS" ]; then
  command -v taskset >/dev/null || { echo "taskset not found; set PIN_CPUS= to run unpinned" >&2; exit 1; }
  PIN=(taskset -c "$PIN_CPUS")
fi
cd "$GD"
swift build -c release --product EncodingBenchmark >/dev/null
(cd ws-loadtest && bash scripts/ensure-deps.sh >/dev/null && npm run -s build)
BIN=".build/release/EncodingBenchmark"
export USE_SNAPSHOT_FOR_SYNC=false
saved_file() { grep -m1 "Results saved to:" "$1" | sed 's/.*Results saved to: //'; }
run() { # tag, args...
  local tag="$1"; shift
  local args=(--scalability --format messagepack-pathhash --iterations 200 --ticks-per-sync 2 --parallel false "$@")
  ${PIN[@]+"${PIN[@]}"} "$BIN" "${args[@]}" > "$TOPIC/raw/$tag.log" 2>&1
  local saved; saved=$(saved_file "$TOPIC/raw/$tag.log")
  [ -f "$saved" ] || { echo "no output for $tag" >&2; exit 1; }
  mv "$saved" "$TOPIC/raw/$tag.json"
  # The gate pass: same cell, capture on. Its timings aren't measurements and aren't kept.
  local views="$TOPIC/raw/.views-$tag"
  rm -rf "$views"
  "$BIN" "${args[@]}" --capture-views "$views" > "$views.log" 2>&1
  local gate_saved; gate_saved=$(saved_file "$views.log")
  [ -f "$gate_saved" ] && rm -f "$gate_saved"
  (cd ws-loadtest && node dist/verify-views-main.js --capture "$views" --out "$TOPIC/raw/$tag.views.json") \
    || { echo "verify-views failed for $tag; capture kept in $views" >&2; exit 1; }
  rm -rf "$views" "$views.log"
  echo "done $tag"
}
for S in delta full-snapshot; do
  run "rq1-rooms-$S"     --players-per-room-list 5 --room-counts 10,30,50 --sync-strategy "$S"
  for CAP in 4 10 50 100; do
    run "monsters-cap$CAP-$S" --players-per-room-list 5 --room-counts 1 --monster-cap "$CAP" --sync-strategy "$S"
  done
  run "active-players-$S" --players-per-room-list 5,10,20,50 --room-counts 1 --monster-cap 4 --active-players --sync-strategy "$S"
done

#!/usr/bin/env bash
# Runs every cell of the snapshot-baseline matrix (spec §6) and copies the raw
# scalability-matrix JSONs into raw/. Release build; USE_SNAPSHOT_FOR_SYNC=false
# for comparability with deep-research/single-room-entity-scaling.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
cd "$GD"
swift build -c release --product EncodingBenchmark >/dev/null
BIN=".build/release/EncodingBenchmark"
export USE_SNAPSHOT_FOR_SYNC=false
run() { # tag, args...
  local tag="$1"; shift
  "$BIN" --scalability --format messagepack-pathhash --iterations 200 --ticks-per-sync 2 "$@" > "$TOPIC/raw/$tag.log" 2>&1
  local saved; saved=$(grep -m1 "Results saved to:" "$TOPIC/raw/$tag.log" | sed 's/.*Results saved to: //')
  [ -f "$saved" ] || { echo "no output for $tag" >&2; exit 1; }
  mv "$saved" "$TOPIC/raw/$tag.json"
  echo "done $tag"
}
for S in delta full-snapshot; do
  run "rq1-rooms-$S"     --players-per-room-list 5 --room-counts 10,30,50 --sync-strategy "$S"
  for CAP in 4 10 50 100; do
    run "monsters-cap$CAP-$S" --players-per-room-list 5 --room-counts 1 --monster-cap "$CAP" --sync-strategy "$S"
  done
  run "active-players-$S" --players-per-room-list 5,10,20,50 --room-counts 1 --monster-cap 4 --active-players --sync-strategy "$S"
done

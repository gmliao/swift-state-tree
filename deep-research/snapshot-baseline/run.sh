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
# stays next to the cell's JSON as <tag>.views.json.
#
# Every output of one invocation goes under raw/<RUN_ID>/, with its record raw/<RUN_ID>/run.json
# (runmeta.py): the options, the git commit, `swift --version`, `node --version`, the start and
# end times, and each cell's status as it finishes. collect.py reads the repeat and the order
# from that record. (Files directly in raw/ are the first, unrepeated sweep's.)
#
# Options (environment):
#   REPEAT=<n>       required: which repeat this sweep is.
#   RUN_ID=<id>      the sweep's directory (printed first, in every mode); generated once at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless
#                    OVERWRITE=1 (redoing cells of that sweep; run.json records the redo).
#   ORDER=delta-first|snapshot-first (default delta-first): within each axis, which strategy
#                    runs first; the other follows it back to back.
#   VERIFY_VIEWS=0   skips the gate pass (for repeats after one gated sweep: the gate doesn't
#                    depend on timing).
#   EXTRA=1          also runs the README's extra rows: JSON-object delta at 10/30/50 rooms
#                    (gated like every cell), and JSON-object delta, MessagePack delta and
#                    MessagePack full-snapshot at 100/300/500 rooms (never gated: the capture
#                    keeps only the first 10 rooms, whose frames come from the same encoder and
#                    room code as the 10/30/50-room cells, so the gate would check nothing new
#                    and a gate pass at 500 rooms costs as long as the measured pass).
#   OVERWRITE=1      with an existing RUN_ID: lets a cell replace its JSON, log or views report,
#                    each replaced file logged to raw/<RUN_ID>/overwrites.log. Without it a cell
#                    whose files exist stops the sweep, naming them.
#   DRY_RUN=1        prints every command with its final arguments and
#                    output paths, builds included, and runs none (nor writes run.json).
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
VERIFY_VIEWS="${VERIFY_VIEWS-1}"
REPEAT="${REPEAT-}"
RUN_ID="${RUN_ID-}"
ORDER="${ORDER-delta-first}"
EXTRA="${EXTRA-0}"
DRY_RUN="${DRY_RUN-0}"
OVERWRITE="${OVERWRITE-0}"
case "$ORDER" in
  delta-first) STRATEGIES=(delta full-snapshot) ;;
  snapshot-first) STRATEGIES=(full-snapshot delta) ;;
  *) echo "ORDER must be delta-first or snapshot-first, not '$ORDER'" >&2; exit 2 ;;
esac
case "$REPEAT" in
  [1-9] | [1-9][0-9]) ;;
  "") echo "REPEAT is required (the repeat this sweep is: 1, 2, ...)" >&2; exit 2 ;;
  *) echo "REPEAT must be a positive number, not '$REPEAT'" >&2; exit 2 ;;
esac
if [ -z "$RUN_ID" ]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$TOPIC" rev-parse --short HEAD)"
fi
case "$RUN_ID" in
  */* | .* | "") echo "RUN_ID must be a plain directory name, not '$RUN_ID'" >&2; exit 2 ;;
esac
OUT="$TOPIC/raw/$RUN_ID"
META=(python3 "$TOPIC/runmeta.py")
if [ -e "$OUT/run.json" ] && [ "$OVERWRITE" != 1 ]; then
  echo "raw/$RUN_ID/run.json exists: that sweep already ran (set OVERWRITE=1 to redo cells in it)" >&2; exit 1
fi
PIN=()
if [ -n "$PIN_CPUS" ]; then
  if [ "$DRY_RUN" != 1 ]; then
    command -v taskset >/dev/null || { echo "taskset not found; set PIN_CPUS= to run unpinned" >&2; exit 1; }
  fi
  PIN=(taskset -c "$PIN_CPUS")
fi
# Prints a command in a dry run, runs it otherwise.
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID"
cd "$GD"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ export USE_SNAPSHOT_FOR_SYNC=false"
  echo "+ write $OUT/run.json"
else
  "${META[@]}" start "$OUT" "$RUN_ID" "$REPEAT" "$ORDER" "$VERIFY_VIEWS" "$PIN_CPUS" "$EXTRA" "$OVERWRITE"
fi
x swift build -c release --product EncodingBenchmark
x bash -c "cd ws-loadtest && bash scripts/ensure-deps.sh && npm run -s build"
BIN=".build/release/EncodingBenchmark"
export USE_SNAPSHOT_FOR_SYNC=false
# A cell's status, appended to run.json as it finishes (or fails).
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
saved_file() { grep -m1 "Results saved to:" "$1" | sed 's/.*Results saved to: //'; }
run() { # tag, gate (gate|nogate), format, args...
  local tag="$1" gate="$2" format="$3"; shift 3
  local args=(--scalability --format "$format" --iterations 200 --ticks-per-sync 2 --parallel false "$@")
  local f existing=()
  for f in "$OUT/$tag.json" "$OUT/$tag.log" "$OUT/$tag.views.json"; do
    [ -e "$f" ] && existing+=("$f")
  done
  if [ "${#existing[@]}" -gt 0 ]; then
    if [ "$OVERWRITE" != 1 ]; then
      echo "refusing to overwrite ${existing[*]} (set OVERWRITE=1 to redo this cell)" >&2; exit 1
    fi
    for f in "${existing[@]}"; do
      echo "overwriting $f" >&2
      [ "$DRY_RUN" = 1 ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $f" >> "$OUT/overwrites.log"
    done
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ ${PIN[*]+${PIN[*]} }$BIN ${args[*]} > $OUT/$tag.log 2>&1   # then: mv <Results saved to> $OUT/$tag.json"
  else
    ${PIN[@]+"${PIN[@]}"} "$BIN" "${args[@]}" > "$OUT/$tag.log" 2>&1 \
      || { echo "$tag failed; see $OUT/$tag.log" >&2; status "$tag" failed-benchmark; exit 1; }
    local saved; saved=$(saved_file "$OUT/$tag.log")
    [ -f "$saved" ] || { echo "no output for $tag" >&2; status "$tag" failed-no-output; exit 1; }
    mv "$saved" "$OUT/$tag.json"
  fi
  if [ "$VERIFY_VIEWS" = 0 ] || [ "$gate" = nogate ]; then status "$tag" measured-gate-skipped; echo "done $tag (gate skipped)"; return; fi
  # The gate pass: same cell, capture on. Its timings aren't measurements and aren't kept.
  local views="$OUT/.views-$tag"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ $BIN ${args[*]} --capture-views $views > $views.log 2>&1"
    echo "+ (cd ws-loadtest && node dist/verify-views-main.js --capture $views --out $OUT/$tag.views.json)"
    status "$tag" measured-gate-passed
    echo "done $tag"
    return
  fi
  rm -rf "$views"
  "$BIN" "${args[@]}" --capture-views "$views" > "$views.log" 2>&1
  local gate_saved; gate_saved=$(saved_file "$views.log")
  [ -f "$gate_saved" ] && rm -f "$gate_saved"
  (cd ws-loadtest && node dist/verify-views-main.js --capture "$views" --out "$OUT/$tag.views.json") \
    || { echo "verify-views failed for $tag; capture kept in $views" >&2; status "$tag" gate-failed; exit 1; }
  rm -rf "$views" "$views.log"
  status "$tag" measured-gate-passed
  echo "done $tag"
}
MP=messagepack-pathhash
for S in "${STRATEGIES[@]}"; do
  run "rq1-rooms-$S" gate $MP --players-per-room-list 5 --room-counts 10,30,50 --sync-strategy "$S"
done
for CAP in 4 10 50 100; do
  for S in "${STRATEGIES[@]}"; do
    run "monsters-cap$CAP-$S" gate $MP --players-per-room-list 5 --room-counts 1 --monster-cap "$CAP" --sync-strategy "$S"
  done
done
for S in "${STRATEGIES[@]}"; do
  run "active-players-$S" gate $MP --players-per-room-list 5,10,20,50 --room-counts 1 --monster-cap 4 --active-players --sync-strategy "$S"
done
if [ "$EXTRA" = 1 ]; then
  run "rq1-rooms-json-delta" gate json-object --players-per-room-list 5 --room-counts 10,30,50 --sync-strategy delta
  run "rq2-rooms-json-object-delta" nogate json-object --players-per-room-list 5 --room-counts 100,300,500 --sync-strategy delta
  for S in "${STRATEGIES[@]}"; do
    run "rq2-rooms-$MP-$S" nogate $MP --players-per-room-list 5 --room-counts 100,300,500 --sync-strategy "$S"
  done
fi
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi

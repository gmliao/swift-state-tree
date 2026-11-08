#!/usr/bin/env bash
# Runs the wire-form ablation of the single-room matrix and writes the raw outputs under
# raw/<RUN_ID>/. Release build, serial sync (`--parallel false`), one room, the shipped sync path
# (USE_SNAPSHOT_FOR_SYNC unset) and the delta strategy. Pinned to CPUs $PIN_CPUS (default 0-7;
# empty runs unpinned, for a smoke run off the measurement machine).
#
# Every cell runs in five wire forms, back to back, as separate processes:
#   json        json-object (the path index and field merge don't apply to it);
#   on-on       messagepack-pathhash, --path-index on --field-merge on (the shipped default);
#   on-off      messagepack-pathhash, --path-index on --field-merge off;
#   off-on      messagepack-pathhash, --path-index off --field-merge on;
#   off-off     messagepack-pathhash, --path-index off --field-merge off.
# The knobs are passed as flags, so the benchmark's metadata records each run's form; run.sh unsets
# PATH_INDEX, FIELD_MERGE, DYNAMIC_KEY_COMPRESSION, ENABLE_DIRTY_TRACKING and
# USE_SNAPSHOT_FOR_SYNC, and run.json records that they were unset.
#
# After each measured run the same run repeats with `--capture-views` (its bytes aren't kept), and
# ws-loadtest's verify-views checks that every recipient's rebuilt state equals its projection
# after every sync (<tag>.views.json): a form whose bytes are smaller because it lost information
# fails there. The capture is deleted once checked.
#
# Options (environment):
#   REPEAT=<n>       required: which repeat this sweep is.
#   RUN_ID=<id>      the sweep's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless OVERWRITE=1.
#   CAPTURE=0        skips the capture passes (for repeats after one captured sweep).
#   OVERWRITE=1      with an existing RUN_ID: lets a cell replace its files, each logged to
#                    raw/<RUN_ID>/overwrites.log.
#   CELLS="<cell> ..." runs only these cells, for a smoke run; run.json records it, and a sweep
#                    with it isn't a full repeat.
#   FORMS="<form> ..." runs only these forms (a smoke run; recorded like CELLS).
#   DRY_RUN=1        prints every command with its final arguments, builds included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
CAPTURE="${CAPTURE-1}"
REPEAT="${REPEAT-}"
RUN_ID="${RUN_ID-}"
DRY_RUN="${DRY_RUN-0}"
OVERWRITE="${OVERWRITE-0}"
CELLS="${CELLS-}"
FORMS="${FORMS-}"
ALL_CELLS="monsters-cap4 monsters-cap10 monsters-cap50 monsters-cap100 idle-players active-players joint"
ALL_FORMS="json on-on on-off off-on off-off"
for c in $CELLS; do
  case " $ALL_CELLS " in *" $c "*) ;; *) echo "CELLS: unknown cell '$c' (one of: $ALL_CELLS)" >&2; exit 2 ;; esac
done
for f in $FORMS; do
  case " $ALL_FORMS " in *" $f "*) ;; *) echo "FORMS: unknown form '$f' (one of: $ALL_FORMS)" >&2; exit 2 ;; esac
done
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
unset USE_SNAPSHOT_FOR_SYNC PATH_INDEX FIELD_MERGE DYNAMIC_KEY_COMPRESSION ENABLE_DIRTY_TRACKING
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID"
cd "$GD"
ONLY="$CELLS"; [ -n "$FORMS" ] && ONLY="$ONLY forms:${FORMS// /,}"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ export BENCHMARK_RESULTS_DIR=$OUT/.benchmark-results"
  echo "+ write $OUT/run.json"
else
  "${META[@]}" start "$OUT" "$RUN_ID" "$REPEAT" "$CAPTURE" "$PIN_CPUS" "$OVERWRITE" "$ONLY"
fi
x swift build -c release --product EncodingBenchmark
[ "$CAPTURE" = 1 ] && x bash -c "cd ws-loadtest && bash scripts/ensure-deps.sh && npm run -s build"
BIN=".build/release/EncodingBenchmark"
# The benchmark writes its result file here (moved into place below), inside the ignored raw/,
# so a run killed between the write and the move leaves nothing in the source tree.
export BENCHMARK_RESULTS_DIR="$OUT/.benchmark-results"
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
saved_file() { grep -m1 "Results saved to:" "$1" | sed 's/.*Results saved to: //'; }
form_args() {
  case "$1" in
    json) echo "--format json-object" ;;
    on-on) echo "--format messagepack-pathhash --path-index on --field-merge on" ;;
    on-off) echo "--format messagepack-pathhash --path-index on --field-merge off" ;;
    off-on) echo "--format messagepack-pathhash --path-index off --field-merge on" ;;
    off-off) echo "--format messagepack-pathhash --path-index off --field-merge off" ;;
  esac
}
run() { # cell, form, args...
  local cell="$1" form="$2"; shift 2
  local tag="$cell-$form"
  # shellcheck disable=SC2207
  local fa=($(form_args "$form"))
  local args=(--scalability "${fa[@]}" --room-counts 1 --iterations 200 --ticks-per-sync 2 --parallel false "$@")
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
  if [ "$CAPTURE" = 0 ]; then status "$tag" measured-capture-skipped; echo "done $tag (capture skipped)"; return; fi
  local views="$OUT/.views-$tag"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ $BIN ${args[*]} --capture-views $views > $views.log 2>&1"
    echo "+ (cd ws-loadtest && node dist/verify-views-main.js --capture $views --out $OUT/$tag.views.json)"
    status "$tag" measured-captured
    echo "done $tag"
    return
  fi
  rm -rf "$views"
  "$BIN" "${args[@]}" --capture-views "$views" > "$views.log" 2>&1 \
    || { echo "capture pass failed for $tag; see $views.log" >&2; status "$tag" failed-capture; exit 1; }
  local capture_saved; capture_saved=$(saved_file "$views.log")
  [ -f "$capture_saved" ] && rm -f "$capture_saved"
  (cd ws-loadtest && node dist/verify-views-main.js --capture "$views" --out "$OUT/$tag.views.json") \
    || { echo "verify-views failed for $tag; capture kept in $views" >&2; status "$tag" gate-failed; exit 1; }
  rm -rf "$views" "$views.log"
  status "$tag" measured-captured
  echo "done $tag"
}
cell() { # cell, args...
  local name="$1" form; shift
  if [ -n "$CELLS" ]; then case " $CELLS " in *" $name "*) ;; *) return ;; esac; fi
  for form in $ALL_FORMS; do
    if [ -n "$FORMS" ]; then case " $FORMS " in *" $form "*) ;; *) continue ;; esac; fi
    run "$name" "$form" "$@"
  done
}
for CAP in 4 10 50 100; do
  cell "monsters-cap$CAP" --players-per-room-list 5 --monster-cap "$CAP"
done
cell idle-players --players-per-room-list 10,20,50 --monster-cap 4
cell active-players --players-per-room-list 5,10,20,50 --monster-cap 4 --active-players
cell joint --players-per-room-list 20 --monster-cap 20 --active-players
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi

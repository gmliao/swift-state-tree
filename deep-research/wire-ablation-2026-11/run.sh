#!/usr/bin/env bash
# Runs the wire ablation (README.md): single-room-entity-scaling's points in six forms, dirty
# tracking on and off and dynamic-key compression on and off, and writes the raw outputs under
# raw/<RUN_ID>/. Release build, serial sync (`--parallel false`), one room, the shipped sync path
# (every deep-research/serverenv.py variable unset) and the delta strategy. Pinned to CPUs
# $PIN_CPUS (default 0-7; empty runs unpinned, for a smoke run off the measurement machine).
#
# Two kinds of invocation:
#   REPEAT=<1-4>     a measured repeat: every cell once, no capture. Within a point, repeats 1 and
#                    4 run the forms in the order below and repeats 2 and 3 in reverse (ABBA).
#   CAPTURE_ONLY=1   the capture block, after all four repeats: every cell once with
#                    `--capture-views`, run with SWIFT_DETERMINISTIC_HASHING=1 so the frames don't
#                    depend on the hash seed; ws-loadtest's verify-views checks every recipient's
#                    rebuilt state against its projection after every sync (<tag>.views.json), and
#                    frames.py hashes the frames each point sent (<tag>.frames.json). The capture
#                    is deleted once both are written. Its timings aren't measurements.
#
# The forms (the benchmark's own flags set the knobs inside the process and record them):
#   mp-dt-dk      messagepack-pathhash, path index on, field merge on, dirty tracking on,  dynamic keys on
#   mp-dt-nodk    same, dynamic keys off
#   mp-nodt-dk    same, dirty tracking off, dynamic keys on
#   mp-nodt-nodk  same, dirty tracking off, dynamic keys off
#   oj-dk         opcode-json-pathhash, path index on, field merge on, dirty tracking on, dynamic keys on
#   oj-nodk       same, dynamic keys off
#
# Options (environment):
#   REPEAT=<1-4>     a measured repeat (required unless CAPTURE_ONLY=1).
#   CAPTURE_ONLY=1   the capture block (no REPEAT).
#   RUN_ID=<id>      the invocation's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless OVERWRITE=1.
#   OVERWRITE=1      with an existing RUN_ID: lets a cell replace its files, each logged to
#                    raw/<RUN_ID>/overwrites.log.
#   CELLS="<cell> ..." runs only these cells, for a smoke run; run.json records it, and collect.py
#                    skips the invocation.
#   FORMS="<form> ..." runs only these forms (a smoke run; recorded like CELLS).
#   DRY_RUN=1        prints every command with its final arguments, builds included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
REPEAT="${REPEAT-}"
CAPTURE_ONLY="${CAPTURE_ONLY-0}"
RUN_ID="${RUN_ID-}"
DRY_RUN="${DRY_RUN-0}"
OVERWRITE="${OVERWRITE-0}"
CELLS="${CELLS-}"
FORMS="${FORMS-}"
ALL_CELLS="monsters-cap4 monsters-cap10 monsters-cap50 monsters-cap100 idle-players active-players joint"
ALL_FORMS="mp-dt-dk mp-dt-nodk mp-nodt-dk mp-nodt-nodk oj-dk oj-nodk"
for c in $CELLS; do
  case " $ALL_CELLS " in *" $c "*) ;; *) echo "CELLS: unknown cell '$c' (one of: $ALL_CELLS)" >&2; exit 2 ;; esac
done
for f in $FORMS; do
  case " $ALL_FORMS " in *" $f "*) ;; *) echo "FORMS: unknown form '$f' (one of: $ALL_FORMS)" >&2; exit 2 ;; esac
done
if [ "$CAPTURE_ONLY" = 1 ]; then
  [ -z "$REPEAT" ] || { echo "CAPTURE_ONLY=1 takes no REPEAT: the capture block is one pass after the four repeats" >&2; exit 2; }
  KIND=capture
else
  case "$REPEAT" in
    1 | 2 | 3 | 4) ;;
    "") echo "REPEAT is required (1-4), or CAPTURE_ONLY=1 for the capture block" >&2; exit 2 ;;
    *) echo "REPEAT must be 1, 2, 3 or 4, not '$REPEAT'" >&2; exit 2 ;;
  esac
  KIND=measured
fi
# ABBA: repeats 2 and 3 run each point's forms in reverse.
ORDERED_FORMS="$ALL_FORMS"
case "$REPEAT" in
  2 | 3) ORDERED_FORMS="$(echo "$ALL_FORMS" | tr ' ' '\n' | tac | tr '\n' ' ')" ;;
esac
if [ -z "$RUN_ID" ]; then
  head_sha=$(git -C "$TOPIC" rev-parse --short HEAD) \
    || { echo "$TOPIC isn't in a git checkout: a run records its commit" >&2; exit 1; }
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$head_sha"
fi
case "$RUN_ID" in
  */* | .* | "") echo "RUN_ID must be a plain directory name, not '$RUN_ID'" >&2; exit 2 ;;
esac
OUT="$TOPIC/raw/$RUN_ID"
META=(python3 "$TOPIC/runmeta.py")
if [ -e "$OUT/run.json" ] && [ "$OVERWRITE" != 1 ]; then
  echo "raw/$RUN_ID/run.json exists: that invocation already ran (set OVERWRITE=1 to redo cells in it)" >&2; exit 1
fi
PIN=()
if [ -n "$PIN_CPUS" ]; then
  if [ "$DRY_RUN" != 1 ]; then
    command -v taskset >/dev/null || { echo "taskset not found; set PIN_CPUS= to run unpinned" >&2; exit 1; }
  fi
  PIN=(taskset -c "$PIN_CPUS")
fi
# deep-research/serverenv.py: every variable that changes what the server sends or how it syncs.
vars=$(python3 "$TOPIC/../serverenv.py") || exit 1
# shellcheck disable=SC2086  # vars is a space-separated list of names, split on purpose
unset $vars
[ "$DRY_RUN" = 1 ] && echo "+ unset $vars"
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID ($KIND${REPEAT:+ repeat $REPEAT})"
cd "$GD"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ export BENCHMARK_RESULTS_DIR=$OUT/.benchmark-results"
  echo "+ write $OUT/run.json"
else
  order=forward; case "$REPEAT" in 2 | 3) order=reverse ;; esac
  capture_flag=0; [ "$KIND" = capture ] && capture_flag=1
  "${META[@]}" start "$OUT" "$RUN_ID" "${REPEAT:-0}" "$order" "$capture_flag" "$PIN_CPUS" 0 "$OVERWRITE" "$CELLS" "$FORMS"
fi
x swift build -c release --product EncodingBenchmark
[ "$KIND" = capture ] && x bash -c "cd ws-loadtest && bash scripts/ensure-deps.sh && npm run -s build"
BIN=".build/release/EncodingBenchmark"
# The benchmark writes its result file here (moved into place below), inside the ignored raw/,
# so a run killed between the write and the move leaves nothing in the source tree.
export BENCHMARK_RESULTS_DIR="$OUT/.benchmark-results"
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
saved_file() { # <log>: the result file the benchmark named in it; a miss stops the run, saying why
  local line
  line=$(grep -m1 "Results saved to:" "$1") \
    || { echo "no 'Results saved to:' line in $1 (missing log, or the run wrote no result file)" >&2; exit 1; }
  printf '%s\n' "${line##*Results saved to: }"
}
form_args() {
  case "$1" in
    mp-dt-dk) echo "--format messagepack-pathhash --path-index on --field-merge on --dirty-tracking on --dynamic-key-compression on" ;;
    mp-dt-nodk) echo "--format messagepack-pathhash --path-index on --field-merge on --dirty-tracking on --dynamic-key-compression off" ;;
    mp-nodt-dk) echo "--format messagepack-pathhash --path-index on --field-merge on --dirty-tracking off --dynamic-key-compression on" ;;
    mp-nodt-nodk) echo "--format messagepack-pathhash --path-index on --field-merge on --dirty-tracking off --dynamic-key-compression off" ;;
    oj-dk) echo "--format opcode-json-pathhash --path-index on --field-merge on --dirty-tracking on --dynamic-key-compression on" ;;
    oj-nodk) echo "--format opcode-json-pathhash --path-index on --field-merge on --dirty-tracking on --dynamic-key-compression off" ;;
  esac
}
guard_existing() { # tag, files...: refuse to replace a cell's files unless OVERWRITE=1
  local tag="$1" f existing=(); shift
  for f in "$@"; do [ -e "$f" ] && existing+=("$f"); done
  [ "${#existing[@]}" -eq 0 ] && return
  if [ "$OVERWRITE" != 1 ]; then
    echo "refusing to overwrite ${existing[*]} (set OVERWRITE=1 to redo this cell)" >&2; exit 1
  fi
  for f in "${existing[@]}"; do
    echo "overwriting $f" >&2
    [ "$DRY_RUN" = 1 ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $f" >> "$OUT/overwrites.log"
  done
}
measure() { # tag, args...
  local tag="$1"; shift
  guard_existing "$tag" "$OUT/$tag.json" "$OUT/$tag.log"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ ${PIN[*]+${PIN[*]} }$BIN $* > $OUT/$tag.log 2>&1   # then: mv <Results saved to> $OUT/$tag.json"
    status "$tag" measured
    return
  fi
  ${PIN[@]+"${PIN[@]}"} "$BIN" "$@" > "$OUT/$tag.log" 2>&1 \
    || { echo "$tag failed; see $OUT/$tag.log" >&2; status "$tag" failed-benchmark; exit 1; }
  local saved; saved=$(saved_file "$OUT/$tag.log")
  [ -f "$saved" ] || { echo "no output for $tag" >&2; status "$tag" failed-no-output; exit 1; }
  mv "$saved" "$OUT/$tag.json"
  status "$tag" measured
  echo "done $tag"
}
capture() { # tag, args...
  local tag="$1"; shift
  local views="$OUT/.views-$tag"
  guard_existing "$tag" "$OUT/$tag.views.json" "$OUT/$tag.frames.json"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ SWIFT_DETERMINISTIC_HASHING=1 ${PIN[*]+${PIN[*]} }$BIN $* --capture-views $views > $views.log 2>&1"
    echo "+ (cd ws-loadtest && node dist/verify-views-main.js --capture $views --out $OUT/$tag.views.json)"
    echo "+ python3 $TOPIC/frames.py $views > $OUT/$tag.frames.json"
    status "$tag" captured
    return
  fi
  rm -rf "$views"
  SWIFT_DETERMINISTIC_HASHING=1 ${PIN[@]+"${PIN[@]}"} "$BIN" "$@" --capture-views "$views" > "$views.log" 2>&1 \
    || { echo "capture pass failed for $tag; see $views.log" >&2; status "$tag" failed-capture; exit 1; }
  local capture_saved; capture_saved=$(saved_file "$views.log")
  [ -f "$capture_saved" ] && rm -f "$capture_saved"
  (cd ws-loadtest && node dist/verify-views-main.js --capture "$views" --out "$OUT/$tag.views.json") \
    || { echo "verify-views failed for $tag; capture kept in $views" >&2; status "$tag" gate-failed; exit 1; }
  python3 "$TOPIC/frames.py" "$views" > "$OUT/$tag.frames.json" \
    || { echo "frames.py failed for $tag; capture kept in $views" >&2; status "$tag" failed-frames; exit 1; }
  rm -rf "$views" "$views.log"
  status "$tag" captured
  echo "done $tag"
}
run() { # cell, form, args...
  local cell="$1" form="$2"; shift 2
  # shellcheck disable=SC2207
  local fa=($(form_args "$form"))
  local args=(--scalability "${fa[@]}" --room-counts 1 --iterations 200 --ticks-per-sync 2 --parallel false "$@")
  if [ "$KIND" = capture ]; then capture "$cell-$form" "${args[@]}"; else measure "$cell-$form" "${args[@]}"; fi
}
cell() { # cell, args...
  local name="$1" form; shift
  if [ -n "$CELLS" ]; then case " $CELLS " in *" $name "*) ;; *) return ;; esac; fi
  for form in $ORDERED_FORMS; do
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

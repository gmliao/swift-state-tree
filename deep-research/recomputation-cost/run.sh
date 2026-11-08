#!/usr/bin/env bash
# Runs the recomputation-cost matrix (README.md) and writes the raw outputs under raw/<RUN_ID>/,
# one directory per ServerLoadTest process. Release builds of ServerLoadTest and
# ReevaluationRunner, every process pinned to CPUs $PIN_CPUS (default 0-7; empty runs unpinned,
# for a smoke run off the measurement machine). Cells: players per room 2, 5, 10 × input cadence
# 5 and 20 ticks (4 and 1 actions per player per second at 50 ms ticks).
#
# Passes, each process with 5 s ramp-up, 30 s steady and 5 s ramp-down:
#   sizes   recording on with --record-dir and --stream-dir, 10 rooms, messagepack and json
#           (TRANSPORT_ENCODING), one repeat; plus a second messagepack repeat at 10 players,
#           cadence 5. For messagepack, the first two records (sorted by name) are replayed:
#           replay-<name>.txt (ReevaluationRunner --input), verify-<name>.txt (--verify) and
#           open-<name>.json (--time-open --repeat 200). Directory sizes-<enc>-p<P>-c<C>-r<n>.
#   cost    recording on (with --record-dir: writing the record is part of its cost) against off,
#           neither with --stream-dir, 200 rooms, profiling on (profile.jsonl). Four repeats in
#           ABBA order (on-off, off-on, off-on, on-off). After each "on" process the first record
#           is verified (verify.txt) and regenerate.py --record-check writes record-check.json
#           (every room's record saved and complete, nothing left in the spool, each record
#           spanning the steady phase, its actions adding up to the actions completed); then the
#           records are deleted. Directory cost-p<P>-c<C>-r<n>-<on|off>.
#   noise   two "off" processes at 10 players, cadence 5, 200 rooms: the noise floor of the
#           on/off comparison. Directory noise-p10-c5-<a|b>.
#
# Options (environment):
#   RUN_ID=<id>      the sweep's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused.
#   CELLS="p<P>-c<C> ..."  only these cells (smoke); run.json records it.
#   SIZE_ROOMS, COST_ROOMS, STEADY, RAMP, OPEN_REPEAT, COST_REPEATS  smoke only (defaults 10, 200,
#                    30, 5, 200, 4): run.json records them, and regenerate.py refuses other values.
#   DRY_RUN=1        prints every command with its final arguments, builds included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
RUN_ID="${RUN_ID-}"
DRY_RUN="${DRY_RUN-0}"
CELLS="${CELLS-}"
SIZE_ROOMS="${SIZE_ROOMS-10}"
COST_ROOMS="${COST_ROOMS-200}"
STEADY="${STEADY-30}"
RAMP="${RAMP-5}"
OPEN_REPEAT="${OPEN_REPEAT-200}"
COST_REPEATS="${COST_REPEATS-4}"
ALL_CELLS="p2-c5 p2-c20 p5-c5 p5-c20 p10-c5 p10-c20"
for c in $CELLS; do
  case " $ALL_CELLS " in *" $c "*) ;; *) echo "CELLS: unknown cell '$c' (one of: $ALL_CELLS)" >&2; exit 2 ;; esac
done
case "$SIZE_ROOMS$COST_ROOMS$STEADY$RAMP$OPEN_REPEAT$COST_REPEATS" in
  *[!0-9]*) echo "SIZE_ROOMS, COST_ROOMS, STEADY, RAMP, OPEN_REPEAT and COST_REPEATS must be numbers" >&2; exit 2 ;;
esac
[ "$SIZE_ROOMS" -ge 2 ] || { echo "SIZE_ROOMS must be at least 2 (two records are replayed)" >&2; exit 2; }
[ "$COST_REPEATS" -ge 1 ] && [ "$COST_REPEATS" -le 4 ] || { echo "COST_REPEATS must be 1 to 4" >&2; exit 2; }
if [ -z "$RUN_ID" ]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$TOPIC" rev-parse --short HEAD)"
fi
case "$RUN_ID" in
  */* | .* | "") echo "RUN_ID must be a plain directory name, not '$RUN_ID'" >&2; exit 2 ;;
esac
OUT="$TOPIC/raw/$RUN_ID"
if [ -e "$OUT" ]; then echo "raw/$RUN_ID exists: that sweep already ran" >&2; exit 1; fi
PIN=()
if [ -n "$PIN_CPUS" ]; then
  if [ "$DRY_RUN" != 1 ]; then
    command -v taskset >/dev/null || { echo "taskset not found; set PIN_CPUS= to run unpinned" >&2; exit 1; }
  fi
  PIN=(taskset -c "$PIN_CPUS")
fi
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID"
cd "$GD"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ write $OUT/run.json"
else
  mkdir -p "$OUT"
  python3 - "$OUT/run.json" "$RUN_ID" "$PIN_CPUS" "$CELLS" "$SIZE_ROOMS" "$COST_ROOMS" "$STEADY" "$RAMP" "$OPEN_REPEAT" "$COST_REPEATS" <<'PY'
import datetime, json, subprocess, sys
def output(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
path, run_id, pin, cells, size_rooms, cost_rooms, steady, ramp, open_repeat, cost_repeats = sys.argv[1:]
commit = output("git", "rev-parse", "HEAD")
status = output("git", "status", "--porcelain")
swift = output("swift", "--version")
json.dump({
    "runId": run_id, "pinCpus": pin, "onlyCells": cells.split() or None,
    "sizeRooms": int(size_rooms), "costRooms": int(cost_rooms), "steadySeconds": int(steady),
    "rampSeconds": int(ramp), "openRepeat": int(open_repeat), "costRepeats": int(cost_repeats),
    "git": {"commit": commit, "dirty": None if commit is None else bool(status)},
    "swiftVersion": swift.splitlines()[0] if swift else None,
    "startedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(path, "w"), indent=2)
PY
fi
x swift build -c release --product ServerLoadTest
x swift build -c release --product ReevaluationRunner
BIN=".build/release/ServerLoadTest"
REPLAY=".build/release/ReevaluationRunner"
# ServerLoadTest writes its result file here first; it's moved into each process's directory.
export BENCHMARK_RESULTS_DIR="$OUT/.benchmark-results"
[ "$DRY_RUN" = 1 ] && echo "+ export BENCHMARK_RESULTS_DIR=$BENCHMARK_RESULTS_DIR"
saved_file() { grep -m1 "Results saved to:" "$1" | sed 's/.*Results saved to: //'; }
aps() { case "$1" in 5) echo 4 ;; 20) echo 1 ;; esac; }
# loadtest <dir> <rooms> <players> <cadence> <on|off> <streams 0|1> <profile 0|1> [env...]
loadtest() {
  local dir="$1" rooms="$2" players="$3" cadence="$4" record="$5" streams="$6" profile="$7"; shift 7
  local env=(env "$@")
  [ "$profile" = 1 ] && env+=("TRANSPORT_PROFILE_JSONL_PATH=$dir/profile.jsonl")
  local args=(--rooms "$rooms" --players-per-room "$players" --actions-per-player-per-second "$(aps "$cadence")"
              --duration-seconds "$STEADY" --ramp-up-seconds "$RAMP" --ramp-down-seconds "$RAMP" --record "$record")
  [ "$record" = on ] && args+=(--record-dir "$dir/records")
  [ "$streams" = 1 ] && args+=(--stream-dir "$dir/streams")
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ ${env[*]} ${PIN[*]+${PIN[*]} }$BIN ${args[*]} > $dir/loadtest.log 2>&1   # then: mv <Results saved to> $dir/loadtest.json"
    return
  fi
  mkdir -p "$dir"
  "${env[@]}" ${PIN[@]+"${PIN[@]}"} "$BIN" "${args[@]}" > "$dir/loadtest.log" 2>&1 \
    || { echo "ServerLoadTest failed; see $dir/loadtest.log" >&2; exit 1; }
  local saved; saved=$(saved_file "$dir/loadtest.log")
  [ -f "$saved" ] || { echo "no result file for $dir" >&2; exit 1; }
  mv "$saved" "$dir/loadtest.json"
}
first_records() { # the first <n> records of <dir>/records, by name
  if [ "$DRY_RUN" = 1 ]; then local i; for i in $(seq 1 "$2"); do echo "<record-$i>"; done; return; fi
  find "$1/records" -maxdepth 1 -name '*.sstr' | sort | head -n "$2"
}
replay() { # <dir>: replay, verify and time the open of the first two records
  local dir="$1" rec name
  for rec in $(first_records "$dir" 2); do
    name="$(basename "$rec" .sstr)"
    x_out "$dir/replay-$name.txt" ${PIN[@]+"${PIN[@]}"} "$REPLAY" --input "$rec"
    x_out "$dir/verify-$name.txt" ${PIN[@]+"${PIN[@]}"} "$REPLAY" --input "$rec" --verify
    x_out "$dir/open-$name.json" ${PIN[@]+"${PIN[@]}"} "$REPLAY" --time-open "$rec" --repeat "$OPEN_REPEAT"
  done
}
x_out() { # <file> <command...>: run with output to file; fail the sweep on error
  local file="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then echo "+ $* > $file 2>&1"; return; fi
  "$@" > "$file" 2>&1 || { echo "failed: $*; see $file" >&2; exit 1; }
}
selected() { [ -z "$CELLS" ] || case " $CELLS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# The cost pass's "on" side: verify one record, check every record, then drop them.
check_records() {
  local dir="$1" rec
  rec="$(first_records "$dir" 1)"
  x_out "$dir/verify.txt" ${PIN[@]+"${PIN[@]}"} "$REPLAY" --input "$rec" --verify
  x python3 "$TOPIC/regenerate.py" --record-check "$dir"
  x rm -rf "$dir/records"
}
done_line() { echo "done $1"; }

# --- sizes ------------------------------------------------------------------------------
for enc in messagepack json; do
  for cell in $ALL_CELLS; do
    selected "$cell" || continue
    players="${cell#p}"; players="${players%%-*}"; cadence="${cell##*-c}"
    dir="$OUT/sizes-$enc-$cell-r1"
    loadtest "$dir" "$SIZE_ROOMS" "$players" "$cadence" on 1 0 "TRANSPORT_ENCODING=$enc"
    [ "$enc" = messagepack ] && replay "$dir"
    done_line "sizes-$enc-$cell-r1"
  done
done
if selected p10-c5; then
  dir="$OUT/sizes-messagepack-p10-c5-r2"
  loadtest "$dir" "$SIZE_ROOMS" 10 5 on 1 0 TRANSPORT_ENCODING=messagepack
  done_line sizes-messagepack-p10-c5-r2
fi

# --- cost: ABBA over the repeats ----------------------------------------------------------
ORDERS=("on off" "off on" "off on" "on off")
for rep in $(seq 1 "$COST_REPEATS"); do
  for cell in $ALL_CELLS; do
    selected "$cell" || continue
    players="${cell#p}"; players="${players%%-*}"; cadence="${cell##*-c}"
    for side in ${ORDERS[$((rep - 1))]}; do
      dir="$OUT/cost-$cell-r$rep-$side"
      loadtest "$dir" "$COST_ROOMS" "$players" "$cadence" "$side" 0 1 TRANSPORT_ENCODING=messagepack
      [ "$side" = on ] && check_records "$dir"
      done_line "cost-$cell-r$rep-$side"
    done
  done
done

# --- noise floor ------------------------------------------------------------------------
if selected p10-c5; then
  for side in a b; do
    loadtest "$OUT/noise-p10-c5-$side" "$COST_ROOMS" 10 5 off 0 1 TRANSPORT_ENCODING=messagepack
    done_line "noise-p10-c5-$side"
  done
fi
x rm -rf "$BENCHMARK_RESULTS_DIR"
if [ "$DRY_RUN" != 1 ]; then
  python3 - "$OUT/run.json" <<'PY'
import datetime, json, sys
record = json.load(open(sys.argv[1]))
record["endedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(record, open(sys.argv[1], "w"), indent=2)
PY
fi
echo "sweep $RUN_ID complete"

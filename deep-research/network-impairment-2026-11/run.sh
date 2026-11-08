#!/usr/bin/env bash
# Runs the network-impairment sweep (design Notes/plans/2026-11-07-network-impairment-experiment-design.md,
# § 8) and writes data/<run-id>/ per run, results/<run-id>.json per ingested run, and the sweep's
# record data/<RUN_ID>/run.json. Linux, as root, in the measurement container (netns and tc).
#
# The order (plan.py): U (each repeat: U-P0, then D50J10, L5, RATE, BO75 rotated by repeat), M
# (M-P0, then COMBO, BO75 rotated), the SR calibration once (SR-CAL, 300 rooms, a 180 s pause),
# then SR. Each run is cell.py: the README's per-run steps (TIME_WAIT wait, stale sockets, impair.sh
# setup, a fresh GameServer, samplers, the schedule, the client instances, convergence at the end of
# recovery, teardown, run.json), then `analysis.py ingest` and the stop check (stopcheck.py).
#
# Exit codes: 0 done; 1 the sweep stopped on a failure; 2 bad options (CELLS naming SR without
# SR_PAUSE included); 3 stopped before SR as planned: the whole plan ran (no CELLS), every earlier
# run passed, only SR remains, SR_PAUSE isn't set.
#
# The sweep stops (exit 1, "STOPPED at <run-id>: ...", naming the step) when:
#   - a run's step fails (cell.py names it: timewait, setup, server, clients, schedule, ...);
#   - ingest fails;
#   - stopcheck.py: any table reads "missing" for the run, or a P0 run has a hard-criterion
#     failure (convergence, criterion 3, included);
# and with exit 3, not 1, when SR is next and SR_PAUSE isn't set: the expected end of the sweep's
# first invocation. srpause.py computes SR_PAUSE from data/<RUN_ID>-SR-CAL (the slow readers'
# maximum time-to-unwritable + 30 s + 10 s, design § 4), or refuses; then SR runs as its own RUN_ID.
# A refused cell (calibration.py: e.g. RATE or COMBO with a calibration of another wire form) stops
# it before anything runs for that cell.
#
# MEASURING.lock is the host agent's: this script never creates, removes or reads it.
#
# The host procedure: three RUN_IDs under one held lock, each a whole invocation, never OVERWRITE:
#   1. MODE=calibrate RUN_ID=<CAL> bash run.sh          (exit 0; writes data/<CAL>/calibration.json)
#   2. CALIBRATION=data/<CAL>/calibration.json RUN_ID=<SWEEP> bash run.sh
#                                                       (U, M, SR-CAL; exit 3 when it stops before SR)
#   3. SR_PAUSE=$(python3 srpause.py data/<SWEEP>-SR-CAL) || stop      (it refuses when SR-CAL
#      can't give one), then CALIBRATION=... CELLS=SR SR_PAUSE=$SR_PAUSE RUN_ID=<SR> bash run.sh (exit 0)
# Any other exit is a failure. CELLS= and REPEATS= per cell are for smokes only.
#
# Modes:
#   MODE=sweep (default)  the runs above.
#   MODE=calibrate        U-P0 and M-P0 at 300 rooms (<RUN_ID>-U-P0-r0, <RUN_ID>-M-P0-r0), not
#                         ingested, then calibrate.py: data/<RUN_ID>/calibration.json with RATE's and
#                         COMBO's rates and limits for this commit's wire form. A sweep reads it with
#                         CALIBRATION=<file>; without it, rate cells use the built-in 2026-11-07
#                         calibration and are refused when its wire form isn't the sweep's.
#
# Options (environment):
#   RUN_ID=<id>        the sweep's id; generated as <UTC yyyymmddTHHMMSSZ>-<short sha> when unset.
#   CELLS="<cell> ..." only these cells (plan.py cells); REPEATS="1 2 3" only these repeats.
#   ROOMS=300|10       10 is the smoke's load point (the 10-room scenarios); recorded per run.
#   SR_PAUSE=<s>       the slow reader's pause, required for SR.
#   CALIBRATION=<file> a calibration from MODE=calibrate (default: the built-in 2026-11-07 values).
#   RATE=<tc rate>, LIMITS=<down>:<up>, JITTER_REORDERS=0|1, REORDERED_PCT=<down>:<up>
#                      smoke overrides of the calibration, recorded in params.calibrationOverrides.
#   PATH_INDEX, FIELD_MERGE, TRANSPORT_ENCODING  the server's wire form (defaults: on, on,
#                      messagepack); the rate cells' calibration must have the same form.
#   SERVER_CPUS=<list> (default 0-7), CLIENT_CPUS=<list> (default 8-11): taskset lists.
#   OVERWRITE=1        lets a run replace its data/<run-id>/.
#   DRY_RUN=1          prints every run's every command and runs none (nothing is written).
#   BUILD=0            tests only (test_topic.py): skip the GameServer and ws-loadtest builds;
#                      GAMESERVER_BIN, tests only: the server binary to start. ANALYSIS_PY and
#                      STOPCHECK_PY, tests only: stand-ins for analysis.py and stopcheck.py.
#
# The smoke (pre-sweep, at 10 rooms, one M-COMBO run end to end; a mechanics check, so the 11-07
# COMBO settings are given as overrides):
#   ROOMS=10 CELLS=M-COMBO REPEATS=1 RATE=4047216bit LIMITS=168:10000 RUN_ID=smoke-m-combo bash run.sh
# Compare its plan first: the same line with DRY_RUN=1.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$(cd "$TOPIC/../../Examples/GameDemo" && pwd)"
WS="$GD/ws-loadtest"
MODE="${MODE-sweep}"
RUN_ID="${RUN_ID-}"
CELLS="${CELLS-}"
REPEATS="${REPEATS-}"
ROOMS="${ROOMS-300}"
SR_PAUSE="${SR_PAUSE-}"
CALIBRATION="${CALIBRATION-}"
SERVER_CPUS="${SERVER_CPUS-0-7}"
CLIENT_CPUS="${CLIENT_CPUS-8-11}"
OVERWRITE="${OVERWRITE-0}"
DRY_RUN="${DRY_RUN-0}"
export OVERWRITE

case "$MODE" in sweep | calibrate) ;; *) echo "MODE must be sweep or calibrate, not '$MODE'" >&2; exit 2 ;; esac
case "$ROOMS" in 300 | 10) ;; *) echo "ROOMS must be 300 or 10, not '$ROOMS'" >&2; exit 2 ;; esac
case "$SR_PAUSE" in "" | [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) ;; *) echo "SR_PAUSE must be whole seconds, not '$SR_PAUSE'" >&2; exit 2 ;; esac
for v in PATH_INDEX FIELD_MERGE; do
  case "${!v-}" in "" | true | false) ;; *) echo "$v must be true or false (or unset), not '${!v}'" >&2; exit 2 ;; esac
done
if [ -n "$CALIBRATION" ] && [ ! -f "$CALIBRATION" ]; then echo "CALIBRATION: no file $CALIBRATION" >&2; exit 2; fi
if [ "$MODE" = calibrate ]; then
  [ "$ROOMS" = 300 ] || { echo "MODE=calibrate runs at 300 rooms (design § 1: per load point, the planned one)" >&2; exit 2; }
  [ -z "$CELLS$REPEATS" ] || { echo "MODE=calibrate takes no CELLS or REPEATS: it runs U-P0 and M-P0" >&2; exit 2; }
fi
if [ -z "$RUN_ID" ]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$TOPIC" rev-parse --short HEAD)"
fi
case "$RUN_ID" in */* | .* | "") echo "RUN_ID must be a plain name, not '$RUN_ID'" >&2; exit 2 ;; esac

if [ "$MODE" = calibrate ]; then
  PLAN="U-P0 0
M-P0 0"
else
  # A named SR needs its pause up front: exit 3 is only the whole plan's planned stop before SR.
  case " $CELLS " in
    *" SR "*) [ -n "$SR_PAUSE" ] || { echo "SR_PAUSE is required with CELLS=SR (python3 srpause.py data/<SWEEP>-SR-CAL)" >&2; exit 2; } ;;
  esac
  PLAN="$(python3 "$TOPIC/plan.py" order --cells "$CELLS" --repeats "$REPEATS")" || exit 2
fi
[ -n "$PLAN" ] || { echo "nothing to run (CELLS='$CELLS' REPEATS='$REPEATS')" >&2; exit 2; }

OUT="$TOPIC/data/$RUN_ID"
META=(python3 "$TOPIC/runmeta.py")
if [ -e "$OUT/run.json" ] && [ "$OVERWRITE" != 1 ]; then
  echo "data/$RUN_ID/run.json exists: that sweep already ran (OVERWRITE=1 to redo runs in it)" >&2; exit 1
fi
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
stop() { # run-id, reason, [exit code: 1]
  echo "STOPPED at $1: $2" >&2
  status "$1" "stopped: $2"
  exit "${3:-1}"
}

echo "RUN_ID=$RUN_ID MODE=$MODE ROOMS=$ROOMS"
echo "plan:"
echo "$PLAN" | sed 's/^/  /'
if [ "$DRY_RUN" = 1 ]; then
  echo "+ write $OUT/run.json (commit, dirty, Swift, Node, impair.sh sha256, calibration, wire form)"
else
  if [ -n "$SERVER_CPUS$CLIENT_CPUS" ]; then
    command -v taskset >/dev/null || { echo "taskset not found; set SERVER_CPUS= CLIENT_CPUS= to run unpinned" >&2; exit 1; }
  fi
  for tool in ip ss tc node; do command -v "$tool" >/dev/null || { echo "$tool not found" >&2; exit 1; }; done
  "${META[@]}" start "$OUT" "$RUN_ID" 1 "$MODE" 1 "server:${SERVER_CPUS:-none} client:${CLIENT_CPUS:-none}" 0 "$OVERWRITE" "$CELLS"
  python3 - "$OUT/run.json" "$WS/scripts/impair.sh" "$ROOMS" "$REPEATS" "$SR_PAUSE" "$CALIBRATION" <<'PY'
import hashlib, json, os, pathlib, sys
path, impair, rooms, repeats, sr_pause, cal = sys.argv[1:]
record = json.load(open(path))
record["buildConfig"] = "release"
record["impairSha256"] = hashlib.sha256(pathlib.Path(impair).read_bytes()).hexdigest()
record["rooms"] = int(rooms)
record["repeats"] = [int(r) for r in repeats.split()] or None
record["srPauseS"] = int(sr_pause) if sr_pause else None
record["calibrationFile"] = cal or None
record["wire"] = {k: os.environ.get(k) or None for k in ("PATH_INDEX", "FIELD_MERGE", "TRANSPORT_ENCODING")}
record["calibrationOverrides"] = {k: os.environ[k] for k in ("RATE", "LIMITS", "JITTER_REORDERS", "REORDERED_PCT") if os.environ.get(k)}
# BUILD=0 (tests) skips the builds: regenerate.py refuses such runs.
record["build"] = os.environ.get("BUILD", "1") != "0"
record["gameserverBin"] = os.environ.get("GAMESERVER_BIN") or None
open(path, "w").write(json.dumps(record, indent=2) + "\n")
PY
fi

cd "$GD"
if [ "${BUILD-1}" != 0 ]; then
  x swift build -c release --product GameServer
  x bash -c "cd '$WS' && bash scripts/ensure-deps.sh && npm run -s build"
fi
SERVER="${GAMESERVER_BIN:-$GD/.build/release/GameServer}"
ANALYSIS="${ANALYSIS_PY:-$TOPIC/analysis.py}"
STOPCHECK="${STOPCHECK_PY:-$TOPIC/stopcheck.py}"
CELL_ARGS=(--sweep "$RUN_ID" --server "$SERVER" --rooms "$ROOMS" --server-cpus "$SERVER_CPUS" --client-cpus "$CLIENT_CPUS")
[ -n "$SR_PAUSE" ] && CELL_ARGS+=(--sr-pause "$SR_PAUSE")
[ -n "$CALIBRATION" ] && CELL_ARGS+=(--calibration "$CALIBRATION")

while read -r cell repeat; do
  [ -n "$cell" ] || continue
  rid="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import plan; print(plan.run_id(sys.argv[2], sys.argv[3], int(sys.argv[4])))' "$TOPIC" "$RUN_ID" "$cell" "$repeat")"
  echo "== $rid"
  if [ "$cell" = SR ] && [ -z "$SR_PAUSE" ]; then
    # SR comes last and any failure stops the sweep first: reaching it means every earlier run passed.
    stop "$rid" "SR needs SR_PAUSE: SR_PAUSE=\$(python3 srpause.py data/$RUN_ID-SR-CAL), then run CELLS=SR SR_PAUSE=\$SR_PAUSE as its own RUN_ID" 3
  fi
  if [ "$DRY_RUN" = 1 ]; then
    python3 "$TOPIC/cell.py" "$cell" "$repeat" "${CELL_ARGS[@]}" --dry-run < /dev/null || stop "$rid" "refused (see above)"
  else
    set +e
    python3 "$TOPIC/cell.py" "$cell" "$repeat" "${CELL_ARGS[@]}" < /dev/null
    code=$?
    set -e
    case "$code" in
      0) ;;
      3) stop "$rid" "refused before running (cell.py's message above)" ;;
      *) stop "$rid" "$(python3 -c 'import json, sys; f = json.load(open(sys.argv[1])).get("meta", {}).get("failure") or {}; print(f.get("message", "cell.py failed before writing run.json"))' "$TOPIC/data/$rid/run.json" 2>/dev/null || echo "cell.py exited $code")" ;;
    esac
  fi
  if [ "$cell" = SR-CAL ] || [ "$MODE" = calibrate ]; then
    status "$rid" ran-not-ingested
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ python3 $TOPIC/analysis.py ingest $TOPIC/data/$rid"
    echo "+ python3 $TOPIC/stopcheck.py $rid   # stop on missing, or on a P0 hard failure"
  else
    python3 "$ANALYSIS" ingest "$TOPIC/data/$rid" < /dev/null > /dev/null || stop "$rid" "step ingest: analysis.py ingest failed"
    python3 "$STOPCHECK" "$rid" < /dev/null || stop "$rid" "step stopcheck: see the reasons above"
  fi
  status "$rid" ingested
done <<< "$PLAN"

if [ "$MODE" = calibrate ]; then
  x python3 "$TOPIC/calibrate.py" --u-p0 "$TOPIC/data/$RUN_ID-U-P0-r0" --m-p0 "$TOPIC/data/$RUN_ID-M-P0-r0" \
    --name "$RUN_ID" --out "$OUT/calibration.json"
  echo "next: CALIBRATION=$OUT/calibration.json for the sweep at this commit"
fi
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi

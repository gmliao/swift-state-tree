#!/usr/bin/env bash
# Runs every cell of the external-input matrix (cells.py; design
# Notes/plans/2026-11-08-external-input-failure-experiment-design.md) and writes the raw outputs
# under raw/<RUN_ID>/<cell>/. Release builds of GameServer and ReevaluationRunner; each cell is
# one fresh GameServer process run by cell.py (server, load client, drain, convergence, records,
# replays). The server and the load client share the host, on SERVER_CPUS and CLIENT_CPUS.
#
# Options (environment):
#   REPEAT=<n>       required: which repeat this sweep is.
#   RUN_ID=<id>      the sweep's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless OVERWRITE=1.
#   OVERWRITE=1      with an existing RUN_ID: lets a cell replace its directory, logged to overwrites.log.
#   CELLS="<cell> ..." runs only these cells, for a smoke run; run.json records it, and a sweep
#                    with it isn't a full repeat.
#   SERVER_CPUS=<list>, CLIENT_CPUS=<list>  taskset lists for the server and the load client
#                    (default 0-7 and 8-11, the measurement host's split). An empty list (unpinned)
#                    is refused unless SMOKE=1; run.json records both, and regenerate.py refuses an
#                    unpinned run.
#   SMOKE=1          allows an unpinned run, for a smoke run off the measurement host.
#   ROOMS=<n>, PRE_S=<s>, STEADY_S=<s>, TAIL_S=<s>  smoke only: every cell's rooms and phase
#                    lengths; run.json records them, and regenerate.py refuses other values.
#   DRY_RUN=1        prints every command with its final arguments, builds included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
REPEAT="${REPEAT-}"
RUN_ID="${RUN_ID-}"
DRY_RUN="${DRY_RUN-0}"
OVERWRITE="${OVERWRITE-0}"
CELLS="${CELLS-}"
SERVER_CPUS="${SERVER_CPUS-0-7}"
CLIENT_CPUS="${CLIENT_CPUS-8-11}"
SMOKE="${SMOKE-0}"
if { [ -z "$SERVER_CPUS" ] || [ -z "$CLIENT_CPUS" ]; } && [ "$SMOKE" != 1 ]; then
  echo "SERVER_CPUS and CLIENT_CPUS must both be set (unpinned runs are for smokes: set SMOKE=1)" >&2; exit 2
fi
ROOMS="${ROOMS-}"
PRE_S="${PRE_S-}"
STEADY_S="${STEADY_S-}"
TAIL_S="${TAIL_S-}"
ALL_CELLS="$(python3 "$TOPIC/cells.py" names)"
for c in $CELLS; do
  case " $ALL_CELLS " in *" $c "*) ;; *) echo "CELLS: unknown cell '$c' (one of: $ALL_CELLS)" >&2; exit 2 ;; esac
done
case "$REPEAT" in
  [1-9] | [1-9][0-9]) ;;
  "") echo "REPEAT is required (the repeat this sweep is: 1, 2, ...)" >&2; exit 2 ;;
  *) echo "REPEAT must be a positive number, not '$REPEAT'" >&2; exit 2 ;;
esac
case "$ROOMS$PRE_S$STEADY_S$TAIL_S" in *[!0-9]*) echo "ROOMS, PRE_S, STEADY_S and TAIL_S must be numbers" >&2; exit 2 ;; esac
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
if [ -n "$SERVER_CPUS$CLIENT_CPUS" ] && [ "$DRY_RUN" != 1 ]; then
  command -v taskset >/dev/null || { echo "taskset not found; SMOKE=1 SERVER_CPUS= CLIENT_CPUS= runs unpinned" >&2; exit 1; }
fi
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID"
cd "$GD"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ write $OUT/run.json"
else
  "${META[@]}" start "$OUT" "$RUN_ID" "$REPEAT" fixed 1 "server:${SERVER_CPUS:-none} client:${CLIENT_CPUS:-none}" 0 "$OVERWRITE" "$CELLS"
  python3 - "$OUT/run.json" "$ROOMS" "$PRE_S" "$STEADY_S" "$TAIL_S" <<'PY'
import json, sys
path, *overrides = sys.argv[1:]
record = json.load(open(path))
record["buildConfig"] = "release"
record["overrides"] = {k: int(v) for k, v in zip(("rooms", "preS", "steadyS", "tailS"), overrides) if v}
open(path, "w").write(json.dumps(record, indent=2) + "\n")
PY
fi
x swift build -c release --product GameServer
x swift build -c release --product ReevaluationRunner
x bash -c "cd ws-loadtest && bash scripts/ensure-deps.sh && npm run -s build"
BIN_DIR="$GD/.build/release"
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
for cell in $ALL_CELLS; do
  if [ -n "$CELLS" ]; then case " $CELLS " in *" $cell "*) ;; *) continue ;; esac; fi
  if [ -e "$OUT/$cell" ]; then
    [ "$OVERWRITE" = 1 ] || { echo "refusing to overwrite $OUT/$cell (set OVERWRITE=1 to redo this cell)" >&2; exit 1; }
    echo "overwriting $OUT/$cell" >&2
    if [ "$DRY_RUN" != 1 ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $cell" >> "$OUT/overwrites.log"
      python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$OUT/$cell"
    fi
  fi
  args=(python3 "$TOPIC/cell.py" "$cell" "$OUT/$cell" --server "$BIN_DIR/GameServer" --runner "$BIN_DIR/ReevaluationRunner"
        --server-cpus "$SERVER_CPUS" --client-cpus "$CLIENT_CPUS")
  [ -n "$ROOMS" ] && args+=(--rooms "$ROOMS")
  [ -n "$PRE_S" ] && args+=(--pre-s "$PRE_S")
  [ -n "$STEADY_S" ] && args+=(--steady-s "$STEADY_S")
  [ -n "$TAIL_S" ] && args+=(--tail-s "$TAIL_S")
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ ${args[*]}"
    "${args[@]}" --dry-run | sed 's/^/    /'
    status "$cell" ran
    continue
  fi
  "${args[@]}" || { echo "$cell failed; see $OUT/$cell/cell.json" >&2; status "$cell" failed; exit 1; }
  status "$cell" ran
  echo "done $cell"
done
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi

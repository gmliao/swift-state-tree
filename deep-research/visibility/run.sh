#!/usr/bin/env bash
# Runs every cell of the visibility matrix (Notes/plans/2026-11-08-visibility-experiment-design.md)
# and writes the raw outputs under raw/<RUN_ID>/. Release build, serial sync (`--parallel false`),
# messagepack-pathhash with the delta strategy, server events off, USE_SNAPSHOT_FOR_SYNC=false,
# 10 rooms, 200 iterations. Pinned to CPUs $PIN_CPUS (default 0-7; empty runs unpinned, for a
# smoke run off the measurement machine).
#
# Every cell runs three variants as separate processes, with the land's knobs in the environment:
#   radius     each player gets the entities within its view (VISIBILITY_TEST_FILTER=radius);
#   all        the control: the same per-player path with a filter that sends every entity;
#   broadcast  the twin state, its entities in one broadcast field: the same entities, motion and
#              visibility work as all, without the per-player projection.
#
# After each measured variant, the same variant runs again with `--capture-views` on the first
# 2 rooms and `--record-dir` (that pass's timings aren't kept). verify-views checks every
# recipient's rebuilt state against its projection after every sync (<tag>.views.json);
# time-decode times the client decode and counts the bytes per room before and after deflate
# (<tag>.decode.json); capcheck.py stats counts visible entities and view changes
# (<tag>.capstats.json); replay.py runs `ReevaluationRunner --verify` on every record
# (<tag>.replay.json). Once every variant of a cell is captured, capcheck.py consistency checks
# that the radius projections are exactly the all projections' entities within the radius
# (<cell>.consistency.json), and broadcast-consistency that every player's broadcast view equals
# its all view (<cell>.broadcast-consistency.json). The sweep stops at the first failure; captures and records are
# deleted once the cell's checks have passed.
#
# Options (environment):
#   REPEAT=<n>       required: which repeat this sweep is.
#   RUN_ID=<id>      the sweep's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless OVERWRITE=1.
#   ORDER=radius-first|all-first (default radius-first): the variants' order within each cell
#                    (radius, all, broadcast or all, radius, broadcast).
#   CAPTURE=0        skips the capture passes for repeats after one captured sweep: no check
#                    depends on the measured pass's timing.
#   ALLOW_UNVERIFIED=1  passes --allow-unverified-provenance to time-decode (a dirty tree, off the
#                    measurement machine); such decode figures aren't for tables.
#   OVERWRITE=1      with an existing RUN_ID: lets a cell replace its files, logged to overwrites.log.
#   CELLS="<cell> ..." runs only these cells, for a smoke run; run.json records it, and a sweep
#                    with it isn't a full repeat.
#   ROOMS=<n>, ITERATIONS=<n>  smoke only (defaults 10 and 200): run.json records them, and
#                    regenerate.py refuses other values.
#   DRY_RUN=1        prints every command with its final arguments, builds included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
CAPTURE="${CAPTURE-1}"
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED-0}"
REPEAT="${REPEAT-}"
RUN_ID="${RUN_ID-}"
ORDER="${ORDER-radius-first}"
DRY_RUN="${DRY_RUN-0}"
OVERWRITE="${OVERWRITE-0}"
CELLS="${CELLS-}"
ROOMS="${ROOMS-10}"
ITERATIONS="${ITERATIONS-200}"
CAPTURE_ROOMS=2
# name: entity count, view radius, viewers per room, ticks per sync
CELL_TABLE="default:40:15:4:1 radius8:40:8:4:1 radius30:40:30:4:1 entities160:160:15:4:1 entities640:640:15:4:1 viewers16:40:15:16:1 tps2:40:15:4:2"
ALL_CELLS=""
for spec in $CELL_TABLE; do ALL_CELLS="$ALL_CELLS ${spec%%:*}"; done
for c in $CELLS; do
  case " $ALL_CELLS " in *" $c "*) ;; *) echo "CELLS: unknown cell '$c' (one of:$ALL_CELLS)" >&2; exit 2 ;; esac
done
case "$ORDER" in
  radius-first) VARIANTS=(radius all broadcast) ;;
  all-first) VARIANTS=(all radius broadcast) ;;
  *) echo "ORDER must be radius-first or all-first, not '$ORDER'" >&2; exit 2 ;;
esac
case "$REPEAT" in
  [1-9] | [1-9][0-9]) ;;
  "") echo "REPEAT is required (the repeat this sweep is: 1, 2, ...)" >&2; exit 2 ;;
  *) echo "REPEAT must be a positive number, not '$REPEAT'" >&2; exit 2 ;;
esac
case "$ROOMS$ITERATIONS" in *[!0-9]*) echo "ROOMS and ITERATIONS must be numbers" >&2; exit 2 ;; esac
[ "$ROOMS" -ge "$CAPTURE_ROOMS" ] || { echo "ROOMS must be at least $CAPTURE_ROOMS" >&2; exit 2; }
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
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID"
cd "$GD"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ export USE_SNAPSHOT_FOR_SYNC=false"
  echo "+ write $OUT/run.json"
else
  "${META[@]}" start "$OUT" "$RUN_ID" "$REPEAT" "$ORDER" "$CAPTURE" "$PIN_CPUS" "$ALLOW_UNVERIFIED" "$OVERWRITE" "$CELLS"
  python3 - "$OUT/run.json" "$ROOMS" "$ITERATIONS" <<'PY'
import json, sys
path, rooms, iterations = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
record = json.load(open(path))
record.update(rooms=rooms, iterations=iterations)
open(path, "w").write(json.dumps(record, indent=2) + "\n")
PY
fi
x swift build -c release --product EncodingBenchmark
x swift build -c release --product ReevaluationRunner
x bash -c "cd ws-loadtest && bash scripts/ensure-deps.sh && npm run -s build"
BIN=".build/release/EncodingBenchmark"
REPLAY=".build/release/ReevaluationRunner"
export USE_SNAPSHOT_FOR_SYNC=false
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
saved_file() { grep -m1 "Results saved to:" "$1" | sed 's/.*Results saved to: //'; }
guard() { # files a cell or variant would write
  local f existing=()
  for f in "$@"; do [ -e "$f" ] && existing+=("$f"); done
  [ "${#existing[@]}" -eq 0 ] && return
  [ "$OVERWRITE" = 1 ] || { echo "refusing to overwrite ${existing[*]} (set OVERWRITE=1 to redo this cell)" >&2; exit 1; }
  for f in "${existing[@]}"; do
    echo "overwriting $f" >&2
    [ "$DRY_RUN" = 1 ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $f" >> "$OUT/overwrites.log"
  done
}
run() { # cell, variant, entities, radius, players, ticks per sync
  local cell="$1" variant="$2" entities="$3" radius="$4" players="$5" tps="$6"
  local tag="$cell-$variant"
  local env=(env "VISIBILITY_TEST_FILTER=$variant" "VISIBILITY_TEST_ENTITY_COUNT=$entities" "VISIBILITY_TEST_VIEW_RADIUS=$radius")
  local args=(--scalability --game-type visibility-test --format messagepack-pathhash --sync-strategy delta
              --iterations "$ITERATIONS" --ticks-per-sync "$tps" --parallel false --no-server-events
              --players-per-room-list "$players" --room-counts "$ROOMS")
  guard "$OUT/$tag.json" "$OUT/$tag.log" "$OUT/$tag.views.json" "$OUT/$tag.decode.json" "$OUT/$tag.capstats.json" "$OUT/$tag.replay.json"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ ${env[*]} ${PIN[*]+${PIN[*]} }$BIN ${args[*]} > $OUT/$tag.log 2>&1   # then: mv <Results saved to> $OUT/$tag.json"
  else
    "${env[@]}" ${PIN[@]+"${PIN[@]}"} "$BIN" "${args[@]}" > "$OUT/$tag.log" 2>&1 \
      || { echo "$tag failed; see $OUT/$tag.log" >&2; status "$tag" failed-benchmark; exit 1; }
    local saved; saved=$(saved_file "$OUT/$tag.log")
    [ -f "$saved" ] || { echo "no output for $tag" >&2; status "$tag" failed-no-output; exit 1; }
    mv "$saved" "$OUT/$tag.json"
  fi
  if [ "$CAPTURE" = 0 ]; then status "$tag" measured-capture-skipped; echo "done $tag (capture skipped)"; return; fi
  local views="$OUT/.views-$tag" records="$OUT/.records-$tag"
  local unverified=()
  [ "$ALLOW_UNVERIFIED" = 1 ] && unverified=(--allow-unverified-provenance)
  local capture=(--capture-views "$views" --capture-rooms "$CAPTURE_ROOMS" --record-dir "$records")
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ ${env[*]} $BIN ${args[*]} ${capture[*]} > $views.log 2>&1"
    echo "+ (cd ws-loadtest && node dist/verify-views-main.js --capture $views --out $OUT/$tag.views.json)"
    echo "+ (cd ws-loadtest && ${PIN[*]+${PIN[*]} }node dist/time-decode-main.js --capture $views --out $OUT/$tag.decode.json${unverified[*]+ ${unverified[*]}})"
    echo "+ python3 $TOPIC/capcheck.py stats $views $OUT/$tag.capstats.json"
    echo "+ ${env[*]} python3 $TOPIC/replay.py $REPLAY $records $OUT/$tag.replay.json"
    status "$tag" measured-captured
    echo "done $tag"
    return
  fi
  rm -rf "$views" "$records"
  "${env[@]}" "$BIN" "${args[@]}" "${capture[@]}" > "$views.log" 2>&1 \
    || { echo "capture pass failed for $tag; see $views.log" >&2; status "$tag" failed-capture; exit 1; }
  local capture_saved; capture_saved=$(saved_file "$views.log")
  [ -f "$capture_saved" ] && rm -f "$capture_saved"
  (cd ws-loadtest && node dist/verify-views-main.js --capture "$views" --out "$OUT/$tag.views.json") \
    || { echo "verify-views failed for $tag; capture kept in $views" >&2; status "$tag" gate-failed; exit 1; }
  (cd ws-loadtest && ${PIN[@]+"${PIN[@]}"} node dist/time-decode-main.js --capture "$views" --out "$OUT/$tag.decode.json" ${unverified[@]+"${unverified[@]}"}) \
    || { echo "time-decode failed for $tag; capture kept in $views" >&2; status "$tag" decode-failed; exit 1; }
  python3 "$TOPIC/capcheck.py" stats "$views" "$OUT/$tag.capstats.json" \
    || { echo "capcheck stats failed for $tag; capture kept in $views" >&2; status "$tag" stats-failed; exit 1; }
  "${env[@]}" python3 "$TOPIC/replay.py" "$REPLAY" "$records" "$OUT/$tag.replay.json" \
    || { echo "replay failed for $tag; records kept in $records" >&2; status "$tag" replay-failed; exit 1; }
  rm -rf "$records" "$views.log"
  status "$tag" measured-captured
  echo "done $tag"
}
cell() { # spec name:entities:radius:players:tps
  local name entities radius players tps v
  IFS=: read -r name entities radius players tps <<< "$1"
  if [ -n "$CELLS" ]; then case " $CELLS " in *" $name "*) ;; *) return ;; esac; fi
  [ "$CAPTURE" = 0 ] || guard "$OUT/$name.consistency.json" "$OUT/$name.broadcast-consistency.json"
  for v in "${VARIANTS[@]}"; do run "$name" "$v" "$entities" "$radius" "$players" "$tps"; done
  [ "$CAPTURE" = 0 ] && return
  local radius_views="$OUT/.views-$name-radius" all_views="$OUT/.views-$name-all" broadcast_views="$OUT/.views-$name-broadcast"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ python3 $TOPIC/capcheck.py consistency $radius_views $all_views $OUT/$name.consistency.json"
    echo "+ python3 $TOPIC/capcheck.py broadcast-consistency $broadcast_views $all_views $OUT/$name.broadcast-consistency.json"
    echo "+ rm -rf $radius_views $all_views $broadcast_views"
    status "$name" consistency-checked
    return
  fi
  python3 "$TOPIC/capcheck.py" consistency "$radius_views" "$all_views" "$OUT/$name.consistency.json" \
    || { echo "consistency check failed for $name; captures kept in $radius_views and $all_views" >&2; status "$name" consistency-failed; exit 1; }
  python3 "$TOPIC/capcheck.py" broadcast-consistency "$broadcast_views" "$all_views" "$OUT/$name.broadcast-consistency.json" \
    || { echo "broadcast consistency check failed for $name; captures kept in $broadcast_views and $all_views" >&2; status "$name" consistency-failed; exit 1; }
  rm -rf "$radius_views" "$all_views" "$broadcast_views"
  status "$name" consistency-checked
  echo "done $name"
}
for spec in $CELL_TABLE; do cell "$spec"; done
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi

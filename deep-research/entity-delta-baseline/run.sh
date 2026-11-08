#!/usr/bin/env bash
# Runs every cell of the entity-delta baseline matrix (Notes/plans/2026-11-07-entity-delta-baseline.md)
# and writes the raw outputs under raw/<RUN_ID>/. Release build, serial sync (`--parallel false`),
# messagepack-pathhash with the delta strategy, the shipped sync path (every
# deep-research/serverenv.py variable unset), as in deep-research/snapshot-baseline. Pinned to CPUs $PIN_CPUS (default 0-7; empty runs unpinned, for
# a smoke run off the measurement machine).
#
# Every cell runs three variants, back to back, as separate processes:
#   sst-events  SST as it ships (server events on);
#   sst         SST with server events off (`--no-server-events`);
#   b2          the entity-delta baseline, events off (`--baseline entity-delta --no-server-events`).
# The comparison is sst against b2 (state only); sst-events shows the events' share.
#
# The `@colyseus/schema` baseline (B1) has no Swift side: in the sst variant's capture pass,
# ws-loadtest's colyseus-baseline converter turns that capture's projections into B1's frames,
# twice: `b1` (every number declared `number`, Colyseus's default) and `b1-tuned` (each field the
# narrowest fixed type covering the run's values). Each gets the same gate, decode timing,
# deflate and projection hash as the other variants (<cell>-b1*.views/.decode/.projections.json)
# and the converter's report (<cell>-b1*.colyseus.json). With CAPTURE=0 there is no B1.
#
# After each measured variant, the same variant runs again with `--capture-views` (its timings
# aren't kept). verify-views checks that every recipient's rebuilt state equals its projection
# after every sync (<tag>.views.json); time-decode times the client decode and computes the bytes
# per room before and after deflate (<tag>.decode.json); projhash.py keeps a hash of every
# player's projection after every sync (<tag>.projections.json), which regenerate.py compares
# across the three variants of a cell (the events switch and the baseline must not change the
# state). The sweep stops at the first failure. The capture is deleted once all three have run.
#
# Options (environment):
#   REPEAT=<n>       required: which repeat this sweep is.
#   RUN_ID=<id>      the sweep's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless OVERWRITE=1.
#   ORDER=sst-first|b2-first (default sst-first): within each cell, whether b2 runs after or
#                    before the two SST variants.
#   CAPTURE=0        skips the capture passes (gate, decode timing, deflate) for repeats after one
#                    captured sweep: none of the three depends on the measured pass's timing.
#   ALLOW_UNVERIFIED=1  passes --allow-unverified-provenance to time-decode (a dirty tree, off the
#                    measurement machine); such decode figures aren't for tables.
#   OVERWRITE=1      with an existing RUN_ID: lets a cell replace its files, each logged to
#                    raw/<RUN_ID>/overwrites.log.
#   CELLS="<cell> ..." runs only these cells (rooms, monsters-cap4/10/50/100, active-players), for a
#                    smoke run; run.json records it, and a sweep with it isn't a full repeat.
#   DRY_RUN=1        prints every command with its final arguments, builds included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$TOPIC/../../Examples/GameDemo"
PIN_CPUS="${PIN_CPUS-0-7}"
CAPTURE="${CAPTURE-1}"
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED-0}"
REPEAT="${REPEAT-}"
RUN_ID="${RUN_ID-}"
ORDER="${ORDER-sst-first}"
DRY_RUN="${DRY_RUN-0}"
OVERWRITE="${OVERWRITE-0}"
CELLS="${CELLS-}"
ALL_CELLS="rooms monsters-cap4 monsters-cap10 monsters-cap50 monsters-cap100 active-players"
for c in $CELLS; do
  case " $ALL_CELLS " in *" $c "*) ;; *) echo "CELLS: unknown cell '$c' (one of: $ALL_CELLS)" >&2; exit 2 ;; esac
done
case "$ORDER" in
  sst-first) VARIANTS=(sst-events sst b2) ;;
  b2-first) VARIANTS=(b2 sst-events sst) ;;
  *) echo "ORDER must be sst-first or b2-first, not '$ORDER'" >&2; exit 2 ;;
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
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
echo "RUN_ID=$RUN_ID"
cd "$GD"
# The shipped sync path and defaults: every server variable unset (deep-research/serverenv.py);
# run.json records them and regenerate.py refuses a run with any set.
vars=$(python3 "$TOPIC/../serverenv.py") || exit 1
unset $vars
if [ "$DRY_RUN" = 1 ]; then
  echo "+ cd $GD"
  echo "+ unset $vars"
  echo "+ export BENCHMARK_RESULTS_DIR=$OUT/.benchmark-results"
  echo "+ write $OUT/run.json"
else
  "${META[@]}" start "$OUT" "$RUN_ID" "$REPEAT" "$ORDER" "$CAPTURE" "$PIN_CPUS" "$ALLOW_UNVERIFIED" "$OVERWRITE" "$CELLS"
fi
x swift build -c release --product EncodingBenchmark
x bash -c "cd ws-loadtest && bash scripts/ensure-deps.sh && npm run -s build"
BIN=".build/release/EncodingBenchmark"
# The benchmark writes its result file here (moved into place below), inside the ignored raw/,
# so a run killed between the write and the move leaves nothing in the source tree.
export BENCHMARK_RESULTS_DIR="$OUT/.benchmark-results"
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
saved_file() { grep -m1 "Results saved to:" "$1" | sed 's/.*Results saved to: //'; }
variant_args() {
  case "$1" in
    sst-events) ;;
    sst) echo "--no-server-events" ;;
    b2) echo "--baseline entity-delta --no-server-events" ;;
  esac
}
b1() { # cell, sst capture dir
  local cell="$1" source="$2" typing name tag converted f
  local unverified=()
  [ "$ALLOW_UNVERIFIED" = 1 ] && unverified=(--allow-unverified-provenance)
  for typing in number tuned; do
    name=b1; [ "$typing" = tuned ] && name=b1-tuned
    tag="$cell-$name"
    converted="$OUT/.views-$tag"
    for f in "$OUT/$tag.colyseus.json" "$OUT/$tag.views.json" "$OUT/$tag.decode.json" "$OUT/$tag.projections.json"; do
      if [ -e "$f" ]; then
        [ "$OVERWRITE" = 1 ] || { echo "refusing to overwrite $f (set OVERWRITE=1 to redo this cell)" >&2; exit 1; }
        echo "overwriting $f" >&2
        [ "$DRY_RUN" = 1 ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $f" >> "$OUT/overwrites.log"
      fi
    done
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ (cd ws-loadtest && node dist/colyseus-baseline-main.js --capture $source --out $converted --report $OUT/$tag.colyseus.json --typing $typing)"
      echo "+ (cd ws-loadtest && node dist/verify-views-main.js --capture $converted --out $OUT/$tag.views.json)"
      echo "+ (cd ws-loadtest && ${PIN[*]+${PIN[*]} }node dist/time-decode-main.js --capture $converted --out $OUT/$tag.decode.json${unverified[*]+ ${unverified[*]}})"
      echo "+ python3 $TOPIC/projhash.py $converted $OUT/$tag.projections.json"
      status "$tag" converted-captured
      continue
    fi
    rm -rf "$converted"
    (cd ws-loadtest && node dist/colyseus-baseline-main.js --capture "$source" --out "$converted" --report "$OUT/$tag.colyseus.json" --typing "$typing") \
      || { echo "colyseus-baseline failed for $tag; source capture kept in $source" >&2; status "$tag" failed-convert; exit 1; }
    (cd ws-loadtest && node dist/verify-views-main.js --capture "$converted" --out "$OUT/$tag.views.json") \
      || { echo "verify-views failed for $tag; capture kept in $converted" >&2; status "$tag" gate-failed; exit 1; }
    (cd ws-loadtest && ${PIN[@]+"${PIN[@]}"} node dist/time-decode-main.js --capture "$converted" --out "$OUT/$tag.decode.json" ${unverified[@]+"${unverified[@]}"}) \
      || { echo "time-decode failed for $tag; capture kept in $converted" >&2; status "$tag" decode-failed; exit 1; }
    python3 "$TOPIC/projhash.py" "$converted" "$OUT/$tag.projections.json" \
      || { echo "projhash failed for $tag; capture kept in $converted" >&2; status "$tag" projhash-failed; exit 1; }
    rm -rf "$converted"
    status "$tag" converted-captured
    echo "done $tag"
  done
}
run() { # cell, variant, args...
  local cell="$1" variant="$2"; shift 2
  local tag="$cell-$variant"
  # shellcheck disable=SC2207
  local extra=($(variant_args "$variant"))
  local args=(--scalability --format messagepack-pathhash --sync-strategy delta --iterations 200 --ticks-per-sync 2 --parallel false ${extra[@]+"${extra[@]}"} "$@")
  local f existing=()
  for f in "$OUT/$tag.json" "$OUT/$tag.log" "$OUT/$tag.views.json" "$OUT/$tag.decode.json" "$OUT/$tag.projections.json"; do
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
  local unverified=()
  [ "$ALLOW_UNVERIFIED" = 1 ] && unverified=(--allow-unverified-provenance)
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ $BIN ${args[*]} --capture-views $views > $views.log 2>&1"
    echo "+ (cd ws-loadtest && node dist/verify-views-main.js --capture $views --out $OUT/$tag.views.json)"
    echo "+ (cd ws-loadtest && ${PIN[*]+${PIN[*]} }node dist/time-decode-main.js --capture $views --out $OUT/$tag.decode.json${unverified[*]+ ${unverified[*]}})"
    echo "+ python3 $TOPIC/projhash.py $views $OUT/$tag.projections.json"
    if [ "$variant" = sst ]; then b1 "$cell" "$views"; fi
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
  (cd ws-loadtest && ${PIN[@]+"${PIN[@]}"} node dist/time-decode-main.js --capture "$views" --out "$OUT/$tag.decode.json" ${unverified[@]+"${unverified[@]}"}) \
    || { echo "time-decode failed for $tag; capture kept in $views" >&2; status "$tag" decode-failed; exit 1; }
  python3 "$TOPIC/projhash.py" "$views" "$OUT/$tag.projections.json" \
    || { echo "projhash failed for $tag; capture kept in $views" >&2; status "$tag" projhash-failed; exit 1; }
  if [ "$variant" = sst ]; then b1 "$cell" "$views"; fi
  rm -rf "$views" "$views.log"
  status "$tag" measured-captured
  echo "done $tag"
}
cell() { # cell, args...
  local name="$1" v; shift
  if [ -n "$CELLS" ]; then case " $CELLS " in *" $name "*) ;; *) return ;; esac; fi
  for v in "${VARIANTS[@]}"; do run "$name" "$v" "$@"; done
}
cell rooms --players-per-room-list 5 --room-counts 10,30,50,100,300,500
for CAP in 4 10 50 100; do
  cell "monsters-cap$CAP" --players-per-room-list 5 --room-counts 1 --monster-cap "$CAP"
done
cell active-players --players-per-room-list 5,10,20,50 --room-counts 1 --monster-cap 4 --active-players
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi

#!/usr/bin/env bash
# Runs this topic's multi-room load matrix (README, Commands) and writes the raw outputs under
# raw/<RUN_ID>/: one fresh GameServer and one load client per run, through ws-loadtest's
# scripts/run-scalability-test.sh with a single room count, as the 2026-11-06 set was run.
#
# The matrix, in order (each run's name is its directory):
#   preflight                      TOP_ROOMS rooms (default 500), profiled: the gate before the suites;
#   overhead-profiled              TOP_ROOMS rooms, profiled   } the profiler-overhead pair, back to
#   overhead-unprofiled            TOP_ROOMS rooms, unprofiled } back, before the suites (its gate);
#   suite-<s>-<rooms>              s = 1, 2, 3; rooms = SUITE_ROOMS (default 100 300 500); profiled.
# Every table's RTT comes from profiled runs: after the pair, a profiled steady RTT p99 more than
# max(+1 ms, +25 %) over the unprofiled one stops the sweep (failed-profiler-overhead,
# profiler_overhead.py) before the suites. Sets before the arms ran the pair last.
#
# Before each run the driver waits until the host's TIME_WAIT socket count is at most
# TIMEWAIT_MAX, and logs the count and the wait to raw/<RUN_ID>/chain.log. GameServer is built
# once (release) before the first run and every run starts that binary (GAMESERVER_BIN), so no
# build runs between the TIME_WAIT wait and the load. Pinning uses PATH shims, as in
# data/provenance/shim/: run-ws-loadtest.sh starts GameServer through `stdbuf`, whose shim runs
# it under `taskset -c $SERVER_CPUS`; the `node` shim runs the load client under
# `taskset -c $CLIENT_CPUS`. Before the first run both shims are checked (first on PATH, pinning
# what they start), and during each run a watcher reads the running GameServer's
# Cpus_allowed_list from /proc; a run whose server wasn't on $SERVER_CPUS stops the sweep (with
# LOG_LEVEL=error the server's startup line, which names its CPUs, isn't logged). Each run gets a header (<run>.run-header.txt: commit, command,
# shims, toolchains, kernel, exit) and the server's log is copied next to its reports (the fixed
# log path is removed before each run, so a missing log is recorded as none, never the previous
# run's). A run that fails its phases is recorded and the sweep goes on (zero disconnects is the
# question, not a precondition), except the preflight, the gate before the suites: its failure
# stops the sweep. A run whose summary doesn't name its room count or whose report file is
# missing stops the sweep (failed-no-summary). So does a profiled run that left no server profile
# (failed-no-profile: transport-profile.jsonl, kept in the run's raw directory for the tables that
# need the server's per-input timings later, #430). So does a run whose load client may have been the
# bottleneck (failed-client-load, clientload.py): in any phase's measured window, the workers' CPU
# demand at 70 % or more of the client's CPUs, a worker's event-loop utilization over 0.5, or
# either figure missing for a configured worker. The exit is nonzero when any run failed.
#
# Options (environment):
#   RUN_ID=<id>      the sweep's directory; generated at start when unset, as
#                    <UTC yyyymmddTHHMMSSZ>-<short sha>. An existing RUN_ID is refused unless OVERWRITE=1.
#   OVERWRITE=1      with an existing RUN_ID: lets a run replace its directory, logged to overwrites.log.
#   RUNS="<run> ..." runs only these runs (names above), for a smoke run; run.json records it.
#   SERVER_CPUS=<list> (default 0-7), CLIENT_CPUS=<list> (default 8-11): taskset lists; empty
#                    runs that side unpinned (a smoke run off the measurement machine).
#   TIMEWAIT_MAX=<n> (default 200), TIMEWAIT_TIMEOUT_S=<s> (default 300): the wait before each
#                    run; a wait that times out stops the sweep.
#   ROOMS=<n>, PRE_S=<s>, STEADY_S=<s>, POST_S=<s>  smoke only: every selected run's room count
#                    and phase lengths (steady's is its measured length); run.json records them.
#   WORKLOAD=plateau|refreeze (default plateau): the game's load. plateau skips Hero Defense's spawn
#                    ramp (HERO_DEFENSE_SPAWN_RAMP_TICKS=0) and holds steady STEADY_WARMUP_S before it
#                    measures, so the load is at its plateau in the measured window (#425). refreeze
#                    runs the refreeze sweep's rules: the game's own ramp (the variable unset: 3000
#                    ticks), no hold (ws-loadtest's default warm-up, the connect ramp plus 2 s), so the
#                    load rises through steady. run.json records it (workload), with spawnRampTicks
#                    (0, or 3000) and steadyWarmupS (null under refreeze); each server must report
#                    that ramp. regenerate.py tables one workload per arm set.
#   STEADY_WARMUP_S=<s> (plateau only; default 30): steady's warm-up, before it measures (#425: the land's
#                    monster count settles at the new player count). It includes steady's connect
#                    ramp (0.5-2.5 s at 100-500 rooms), so the full 5 players per room are held a
#                    little under it. The scenario is always a copy of the default one in
#                    raw/<RUN_ID>/scenario.json with steady's warm-up set to it and its length grown
#                    by it, so steady measures exactly its default 60 s (the sets before the hold ran
#                    ws-loadtest's default warm-up, the ramp plus 2 s, and measured 55.5-57.5 s);
#                    run.json records it, and regenerate.py tables only 30.
#   PATH_INDEX=true|false, FIELD_MERGE=true|false  the server's wire features (both on by default since
#                    #308 and #301). Unset runs the defaults; `false` is a like-for-like rerun of a set
#                    sent without them (2026-11-06 had neither). run.json records both, every run
#                    records the features each JoinResponse named, and regenerate.py --sweep refuses a
#                    run whose features differ from the declared form.
#   WS_SEND_BACKLOG_MAX_BYTES, WS_SEND_BACKLOG_MAX_UNWRITABLE_MS  recorded (run.json, each header);
#                    the question is the shipped defaults, so regenerate.py --sweep refuses a sweep
#                    with either set.
#   TOP_ROOMS=<n> (default 500), SUITE_ROOMS="<n> ..." (default "100 300 500"): the matrix's top
#                    room count (the preflight and the overhead pair) and the suites' room counts, in
#                    ascending order, none over TOP_ROOMS. A host whose capacity is under the default
#                    top runs a lower one; an arm can leave out room counts over capacity. run.json
#                    records both (topRooms, suiteRooms); regenerate.py tables what each sweep ran.
#   MOVE_TO_PER_S=<n> (default 0): the MoveTo arm (#430): every player also sends n MoveTo events per
#                    second (ws-loadtest's --move-to-rate overlay, on top of 1 PlayAction/s). 0
#                    passes no flag, so the command and the scenario are the ones before the arms.
#                    run.json records it (moveToPerS); regenerate.py tables 0, 2 and 5.
#   CONTROL=1        the host-drift control after the arms: one run, control-300 (suite-1's run at
#                    300 rooms, profiled), at arm 0. run.json records it (control); regenerate.py
#                    compares its server CPU per room with the arm-0 sweep's suite-*-300 runs and
#                    reports it, untabled. Not with RUNS or a MOVE_TO_PER_S other than 0.
#   DRY_RUN=1        prints every command with its final arguments, the build included, and runs none.
set -euo pipefail
TOPIC="$(cd "$(dirname "$0")" && pwd)"
GD="$(cd "$TOPIC/../../Examples/GameDemo" && pwd)"
WS="$GD/ws-loadtest"
BASE_SCENARIO="scenarios/hero-defense/default.json"
RUN_ID="${RUN_ID-}"
OVERWRITE="${OVERWRITE-0}"
RUNS="${RUNS-}"
SERVER_CPUS="${SERVER_CPUS-0-7}"
CLIENT_CPUS="${CLIENT_CPUS-8-11}"
TIMEWAIT_MAX="${TIMEWAIT_MAX-200}"
TIMEWAIT_TIMEOUT_S="${TIMEWAIT_TIMEOUT_S-300}"
for v in PATH_INDEX FIELD_MERGE; do
  case "${!v-}" in "" | true | false) ;; *) echo "$v must be true or false (or unset for the default), not '${!v}'" >&2; exit 2 ;; esac
done
ROOMS="${ROOMS-}"
PRE_S="${PRE_S-}"
STEADY_S="${STEADY_S-}"
POST_S="${POST_S-}"
WORKLOAD="${WORKLOAD-plateau}"
case "$WORKLOAD" in
  plateau) STEADY_WARMUP_S="${STEADY_WARMUP_S-30}"; SPAWN_RAMP_EXPECTED=0 ;;
  refreeze)
    [ -z "${STEADY_WARMUP_S-}" ] || { echo "WORKLOAD=refreeze has no hold (ws-loadtest's default warm-up): not with STEADY_WARMUP_S" >&2; exit 2; }
    STEADY_WARMUP_S=""; SPAWN_RAMP_EXPECTED=3000 ;;
  *) echo "WORKLOAD must be plateau or refreeze, not '$WORKLOAD'" >&2; exit 2 ;;
esac
MOVE_TO_PER_S="${MOVE_TO_PER_S-0}"
CONTROL="${CONTROL-0}"
DRY_RUN="${DRY_RUN-0}"
# Tests only (test_topic.py): a stand-in for the scalability script, and the server log it writes.
SCALABILITY_SCRIPT="${SCALABILITY_SCRIPT-scripts/run-scalability-test.sh}"
SERVER_LOG="${SERVER_LOG-/tmp/ws-loadtest-gameserver.log}"

TOP_ROOMS="${TOP_ROOMS-500}"
SUITE_ROOMS="${SUITE_ROOMS-100 300 500}"
case "$TOP_ROOMS" in "" | *[!0-9]* | 0) echo "TOP_ROOMS must be a room count (default 500), not '$TOP_ROOMS'" >&2; exit 2 ;; esac
TOP_ROOMS=$((10#$TOP_ROOMS))
previous=0
for n in $SUITE_ROOMS; do
  case "$n" in *[!0-9]* | 0) echo "SUITE_ROOMS must be room counts (default \"100 300 500\"), not '$n'" >&2; exit 2 ;; esac
  [ "$((10#$n))" -gt "$previous" ] || { echo "SUITE_ROOMS must ascend without repeats: '$SUITE_ROOMS'" >&2; exit 2; }
  [ "$((10#$n))" -le "$TOP_ROOMS" ] || { echo "SUITE_ROOMS has $n, over TOP_ROOMS=$TOP_ROOMS: the preflight gates the top count" >&2; exit 2; }
  previous=$((10#$n))
done
[ "$previous" != 0 ] || { echo "SUITE_ROOMS must name at least one room count" >&2; exit 2; }

# name:rooms:profiled
MATRIX="preflight:$TOP_ROOMS:1 overhead-profiled:$TOP_ROOMS:1 overhead-unprofiled:$TOP_ROOMS:0"
for s in 1 2 3; do for n in $SUITE_ROOMS; do n=$((10#$n)); MATRIX="$MATRIX suite-$s-$n:$n:1"; done; done
case "$CONTROL" in
  0) ;;
  1)
    [ -z "$RUNS" ] || { echo "CONTROL=1 runs the control run only: not with RUNS" >&2; exit 2; }
    [ "$MOVE_TO_PER_S" = 0 ] || { echo "CONTROL=1 is arm 0: not with MOVE_TO_PER_S=$MOVE_TO_PER_S" >&2; exit 2; }
    MATRIX="control-300:300:1" ;;
  *) echo "CONTROL must be 0 or 1, not '$CONTROL'" >&2; exit 2 ;;
esac
ALL_RUNS=""
for spec in $MATRIX; do ALL_RUNS="$ALL_RUNS ${spec%%:*}"; done
for r in $RUNS; do
  case " $ALL_RUNS " in *" $r "*) ;; *) echo "RUNS: unknown run '$r' (one of:$ALL_RUNS)" >&2; exit 2 ;; esac
done
case "$ROOMS$PRE_S$STEADY_S$POST_S$TIMEWAIT_MAX$TIMEWAIT_TIMEOUT_S$STEADY_WARMUP_S$MOVE_TO_PER_S" in
  *[!0-9]*) echo "ROOMS, PRE_S, STEADY_S, POST_S, TIMEWAIT_MAX, TIMEWAIT_TIMEOUT_S, STEADY_WARMUP_S and MOVE_TO_PER_S must be numbers" >&2; exit 2 ;;
esac
[ "$WORKLOAD" = refreeze ] || [ -n "$STEADY_WARMUP_S" ] || { echo "STEADY_WARMUP_S must be a number (default 30)" >&2; exit 2; }
[ -n "$MOVE_TO_PER_S" ] || { echo "MOVE_TO_PER_S must be a number (default 0)" >&2; exit 2; }
MOVE_TO_PER_S=$((10#$MOVE_TO_PER_S))
[ "$ROOMS" != 0 ] || { echo "ROOMS must be at least 1" >&2; exit 2; }
if [ -z "$RUN_ID" ]; then
  head_sha=$(git -C "$TOPIC" rev-parse --short HEAD) \
    || { echo "$TOPIC isn't in a git checkout: a run records its commit" >&2; exit 1; }
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$head_sha"
fi
case "$RUN_ID" in
  */* | .* | "") echo "RUN_ID must be a plain directory name, not '$RUN_ID'" >&2; exit 2 ;;
esac
OUT="$TOPIC/raw/$RUN_ID"
# run-scalability-test.sh takes --output-dir and --scenario relative to ws-loadtest/.
REL_OUT="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$OUT" "$WS")"
META=(python3 "$TOPIC/runmeta.py")
if [ -e "$OUT/run.json" ] && [ "$OVERWRITE" != 1 ]; then
  echo "raw/$RUN_ID/run.json exists: that sweep already ran (set OVERWRITE=1 to redo runs in it)" >&2; exit 1
fi
if [ "$DRY_RUN" != 1 ]; then
  command -v ss >/dev/null || { echo "ss not found (iproute2): the TIME_WAIT wait needs it" >&2; exit 1; }
  command -v node >/dev/null || { echo "node not found" >&2; exit 1; }
  if [ -n "$SERVER_CPUS$CLIENT_CPUS" ]; then
    command -v taskset >/dev/null || { echo "taskset not found; set SERVER_CPUS= CLIENT_CPUS= to run unpinned" >&2; exit 1; }
  fi
  # run-ws-loadtest.sh starts the server without stdbuf when it's missing: the server shim would
  # never run, and the server would run unpinned without a word.
  if [ -n "$SERVER_CPUS" ]; then
    command -v stdbuf >/dev/null || { echo "stdbuf not found: the server's pinning shim needs it" >&2; exit 1; }
  fi
fi
x() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
status() { if [ "$DRY_RUN" = 1 ]; then echo "+ status $1 $2"; else "${META[@]}" cell "$OUT" "$1" "$2"; fi; }
chain() { if [ "$DRY_RUN" = 1 ]; then echo "+ chain.log: $*"; else echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$OUT/chain.log"; fi; }
timewait_count() { ss -tan state time-wait 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }

echo "RUN_ID=$RUN_ID"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ write $OUT/run.json"
  echo "+ wire: PATH_INDEX=${PATH_INDEX:-default} FIELD_MERGE=${FIELD_MERGE:-default}; send backlog: ${WS_SEND_BACKLOG_MAX_BYTES:-default} ${WS_SEND_BACKLOG_MAX_UNWRITABLE_MS:-default}"
  echo "+ arm: MoveTo ${MOVE_TO_PER_S}/s per player; control: $CONTROL; rooms: top $TOP_ROOMS, suites $(echo $SUITE_ROOMS); workload: $WORKLOAD"
else
  "${META[@]}" start "$OUT" "$RUN_ID" 1 fixed 1 "server:${SERVER_CPUS:-none} client:${CLIENT_CPUS:-none}" 0 "$OVERWRITE" "$RUNS"
  python3 - "$OUT/run.json" "$ROOMS" "$PRE_S" "$STEADY_S" "$POST_S" "$TIMEWAIT_MAX" "$TIMEWAIT_TIMEOUT_S"     "${PATH_INDEX-}" "${FIELD_MERGE-}" "${WS_SEND_BACKLOG_MAX_BYTES-}" "${WS_SEND_BACKLOG_MAX_UNWRITABLE_MS-}" "${TRANSPORT_ENCODING-}" "$STEADY_WARMUP_S" "$MOVE_TO_PER_S" "$CONTROL" "$TOP_ROOMS" "$SUITE_ROOMS" "$WORKLOAD" "$SPAWN_RAMP_EXPECTED" <<'PY'
import json, sys
path, rooms, pre, steady, post, tw_max, tw_timeout, path_index, field_merge, backlog_bytes, backlog_ms, encoding, steady_warmup, move_to, control, top_rooms, suite_rooms, workload, ramp = sys.argv[1:]
record = json.load(open(path))
record["buildConfig"] = "release"
record["overrides"] = {k: int(v) for k, v in (("rooms", rooms), ("preS", pre), ("steadyS", steady), ("postS", post)) if v}
record["timeWait"] = {"max": int(tw_max), "timeoutS": int(tw_timeout)}
# The declared wire form: null is the server's default (on).
record["wire"] = {"PATH_INDEX": path_index or None, "FIELD_MERGE": field_merge or None, "TRANSPORT_ENCODING": encoding or None}
record["sendBacklogEnv"] = {"WS_SEND_BACKLOG_MAX_BYTES": backlog_bytes or None,
                            "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": backlog_ms or None}
record["workload"] = workload
record["spawnRampTicks"] = int(ramp)
record["steadyWarmupS"] = int(steady_warmup) if steady_warmup else None
record["moveToPerS"] = int(move_to)
record["control"] = control == "1"
# The sync-path switches in the shell that started the sweep (#468); run.sh unsets them before any
# server starts, so every run takes the shipped sync path whatever the shell had.
import os
record["syncPathEnv"] = {k: os.environ.get(k) or None for k in ("USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC", "USE_SYNC_TABLES", "ROW_ADDRESSING", "SYNC_STRATEGY")}
record["topRooms"] = int(top_rooms)
record["suiteRooms"] = [int(n) for n in suite_rooms.split()]
record["spawnRampTicksEffective"] = {}
open(path, "w").write(json.dumps(record, indent=2) + "\n")
PY
fi

# The scenario: a copy of the default one, with steady's warm-up hold (STEADY_WARMUP_S; none under
# WORKLOAD=refreeze, so ws-loadtest's default warm-up applies) and the smoke's phase lengths when given. ws-loadtest leaves a phase's warm-up out of its metrics, inside
# its length: steady's length grows by the hold, so it measures its whole default length (60 s).
SCENARIO="$REL_OUT/scenario.json"
if [ "$DRY_RUN" = 1 ]; then
  echo "+ write $OUT/scenario.json from $BASE_SCENARIO: lengths (s) preflight ${PRE_S:-default}, steady ${STEADY_S:-default}, postflight ${POST_S:-default}; $([ -n "$STEADY_WARMUP_S" ] && echo "steady measured after a ${STEADY_WARMUP_S} s warm-up" || echo "steady with ws-loadtest's default warm-up (no hold)")"
else
  python3 - "$WS/$BASE_SCENARIO" "$OUT/scenario.json" "$STEADY_WARMUP_S" "$PRE_S" "$STEADY_S" "$POST_S" <<'PY'
import json, sys
source, target, warmup, *lengths = sys.argv[1:]
scenario = json.load(open(source))
for phase, seconds in zip(("preflight", "steady", "postflight"), lengths):
    if seconds:
        scenario["phases"][phase]["durationSeconds"] = int(seconds)
steady = scenario["phases"]["steady"]
if warmup:
    steady["warmupSeconds"] = int(warmup)
    steady["durationSeconds"] += int(warmup)
open(target, "w").write(json.dumps(scenario, indent=2) + "\n")
PY
fi

# Pinning shims, as in data/provenance/shim/.
SHIM="$OUT/shim"
if [ -n "$SERVER_CPUS$CLIENT_CPUS" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$SERVER_CPUS" ]; then echo "+ shim $SHIM/stdbuf: exec taskset -c $SERVER_CPUS <stdbuf> \"\$@\""; fi
    if [ -n "$CLIENT_CPUS" ]; then echo "+ shim $SHIM/node: exec taskset -c $CLIENT_CPUS <node> \"\$@\""; fi
  else
    mkdir -p "$SHIM"
    if [ -n "$SERVER_CPUS" ]; then
      printf '#!/bin/bash\nexec taskset -c %s %s "$@"\n' "$SERVER_CPUS" "$(command -v stdbuf)" > "$SHIM/stdbuf"
      chmod +x "$SHIM/stdbuf"
    fi
    if [ -n "$CLIENT_CPUS" ]; then
      printf '#!/bin/bash\nexec taskset -c %s %s "$@"\n' "$CLIENT_CPUS" "$(command -v node)" > "$SHIM/node"
      chmod +x "$SHIM/node"
    fi
  fi
fi

cd "$GD"
x swift build -c release --product GameServer
export GAMESERVER_BIN="$GD/.build/release/GameServer"
# Hero Defense's spawn ramp (HERO_DEFENSE_SPAWN_RAMP_TICKS; the game's own is 3000 ticks): 0 starts
# every land at the final spawn rate, so its monster count is at its plateau within seconds
# instead of growing through the run (#425). The server inherits it through the scripts; run.json
# records it (spawnRampTicks), and per run the value the server reported at startup
# (spawnRampTicksEffective, from its log; a run whose server reports another value fails). A record
# doesn't carry it: replay one with the same value (HeroDefenseEnvKeys.spawnRampTicks).
# WORKLOAD=refreeze runs the game's own ramp: the variable unset, the server's default (3000 ticks).
if [ "$WORKLOAD" = refreeze ]; then unset HERO_DEFENSE_SPAWN_RAMP_TICKS; else export HERO_DEFENSE_SPAWN_RAMP_TICKS=0; fi
export GAMESERVER_SOURCE_SHA="$(git -C "$TOPIC" rev-parse HEAD)"
# The shipped sync path (#468): the sync-path switches are unset for every server, whatever the shell
# had (run.json records the shell's values, syncPathEnv; each run header says so too).
SYNC_PATH_SHELL="USE_SNAPSHOT_FOR_SYNC=[${USE_SNAPSHOT_FOR_SYNC:-unset}] IN_TURN_SYNC=[${IN_TURN_SYNC:-unset}] USE_SYNC_TABLES=[${USE_SYNC_TABLES:-unset}] ROW_ADDRESSING=[${ROW_ADDRESSING:-unset}] SYNC_STRATEGY=[${SYNC_STRATEGY:-unset}]"
unset USE_SNAPSHOT_FOR_SYNC IN_TURN_SYNC USE_SYNC_TABLES ROW_ADDRESSING SYNC_STRATEGY
[ "$DRY_RUN" != 1 ] || echo "+ unset USE_SNAPSHOT_FOR_SYNC IN_TURN_SYNC USE_SYNC_TABLES ROW_ADDRESSING SYNC_STRATEGY (the shell had: $SYNC_PATH_SHELL)"
[ "$DRY_RUN" != 1 ] || echo "+ export GAMESERVER_BIN=$GAMESERVER_BIN GAMESERVER_SOURCE_SHA=$GAMESERVER_SOURCE_SHA HERO_DEFENSE_SPAWN_RAMP_TICKS=${HERO_DEFENSE_SPAWN_RAMP_TICKS-unset} (expected from the server: $SPAWN_RAMP_EXPECTED)"

# Whether two taskset/kernel CPU lists ("0-7", "0,2-3") name the same CPUs.
same_cpus() {
  python3 -c 'import sys
def cpus(s):
    out = set()
    for part in filter(None, s.strip().split(",")):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out
sys.exit(0 if sys.argv[1].strip() and cpus(sys.argv[1]) == cpus(sys.argv[2]) else 1)' "$1" "$2"
}
# The affinity watcher of the current run, stopped after the run and on every exit.
watcher=""
stop_watcher() {
  if [ -n "$watcher" ]; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    watcher=""
  fi
}
trap stop_watcher EXIT
# Writes the CPU list of the first process running $GAMESERVER_BIN to $1, polling for up to 120 s.
watch_server_affinity() {
  local target p i
  target=$(readlink -f "$GAMESERVER_BIN")
  for ((i = 0; i < 240; i++)); do
    for p in /proc/[0-9]*; do
      if [ "$(readlink -f "$p/exe" 2>/dev/null)" = "$target" ]; then
        sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$p/status" > "$1" 2>/dev/null && return 0
      fi
    done
    sleep 0.5
  done
}

# Before the first run: both shims come first on PATH and pin what they start.
if [ -n "$SERVER_CPUS$CLIENT_CPUS" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ check the shims: PATH=$SHIM:\$PATH resolves stdbuf and node to them, and each runs on its CPUs"
  else
    if [ -n "$SERVER_CPUS" ]; then
      got=$(PATH="$SHIM:$PATH" stdbuf -oL sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status)
      [ "$(PATH="$SHIM:$PATH" command -v stdbuf)" = "$SHIM/stdbuf" ] && same_cpus "$got" "$SERVER_CPUS" \
        || { echo "the stdbuf shim doesn't pin to $SERVER_CPUS (got '$got')" >&2; exit 1; }
    fi
    if [ -n "$CLIENT_CPUS" ]; then
      got=$(PATH="$SHIM:$PATH" node -e 'process.stdout.write(require("fs").readFileSync("/proc/self/status", "utf8").match(/^Cpus_allowed_list:\s*(.*)$/m)[1])')
      [ "$(PATH="$SHIM:$PATH" command -v node)" = "$SHIM/node" ] && same_cpus "$got" "$CLIENT_CPUS" \
        || { echo "the node shim doesn't pin to $CLIENT_CPUS (got '$got')" >&2; exit 1; }
    fi
  fi
fi

wait_timewait() { # run
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ wait until TIME_WAIT <= $TIMEWAIT_MAX (at most ${TIMEWAIT_TIMEOUT_S}s), logged to $OUT/chain.log"
    return
  fi
  local count waited=0
  count=$(timewait_count)
  chain "before $1: TIME_WAIT=$count"
  while [ "$count" -gt "$TIMEWAIT_MAX" ]; do
    if [ "$waited" -ge "$TIMEWAIT_TIMEOUT_S" ]; then
      chain "$1 not started: TIME_WAIT=$count after ${waited}s"
      status "$1" failed-timewait
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
    count=$(timewait_count)
  done
  chain "$1 start: TIME_WAIT=$count waited=${waited}s"
}

FAILED=0
for spec in $MATRIX; do
  IFS=: read -r name rooms profiled <<< "$spec"
  if [ -n "$RUNS" ]; then case " $RUNS " in *" $name "*) ;; *) continue ;; esac; fi
  [ -n "$ROOMS" ] && rooms="$ROOMS"
  args=(--room-counts "$rooms" --scenario "$SCENARIO" --output-dir "$REL_OUT/$name")
  # The run's lands, per second, from its own server (HeroDefenseStats): collect.py checks the
  # steady window's monster load is stationary from it.
  stats="$OUT/$name/land-stats.jsonl"
  [ "$profiled" = 1 ] && args+=(--profile)
  # Arm 0 passes no flag: the command is the one before the arms.
  [ "$MOVE_TO_PER_S" != 0 ] && args+=(--move-to-rate "$MOVE_TO_PER_S")
  path_prefix=""
  [ -n "$SERVER_CPUS$CLIENT_CPUS" ] && path_prefix="PATH=$SHIM:\$PATH "
  if [ -e "$OUT/$name" ]; then
    [ "$OVERWRITE" = 1 ] || { echo "refusing to overwrite $OUT/$name (set OVERWRITE=1 to redo this run)" >&2; exit 1; }
    echo "overwriting $OUT/$name" >&2
    if [ "$DRY_RUN" != 1 ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $name" >> "$OUT/overwrites.log"
      rm -rf "$OUT/$name" "$OUT/$name.log" "$OUT/$name.run-header.txt"
    fi
  fi
  wait_timewait "$name"
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ rm -f $SERVER_LOG"
    echo "+ (cd $WS && HERO_DEFENSE_STATS_PATH=$stats ${path_prefix}bash $SCALABILITY_SCRIPT ${args[*]}) > $OUT/$name.log 2>&1"
    echo "+ header $OUT/$name.run-header.txt; copy $SERVER_LOG to $OUT/$name/gameserver.log (or record none)"
    echo "+ check the summary names $rooms rooms and its run's report exists, else failed-no-summary"
    [ "$profiled" = 1 ] && echo "+ check the server profile is in $OUT/$name (transport-profile.jsonl, not empty), else failed-no-profile"
    echo "+ check the client's load in every phase (clientload.py, client CPUs ${CLIENT_CPUS:-as the client saw them}), else failed-client-load"
    [ "$name" = preflight ] && echo "+ stop the sweep if preflight failed"
    [ "$name" = overhead-unprofiled ] && echo "+ check the profiler's overhead (profiler_overhead.py): overhead-profiled's steady RTT p99 within max(+1 ms, +25 %) of this run's, else failed-profiler-overhead"
    status "$name" ran
    continue
  fi
  header="$OUT/$name.run-header.txt"
  # The server log is a fixed path: remove it, so a run whose server never started can't keep
  # the previous run's log.
  rm -f "$SERVER_LOG"
  {
    echo "sha=$GAMESERVER_SOURCE_SHA"
    echo "start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cmd: ${path_prefix}bash $SCALABILITY_SCRIPT ${args[*]}"
    for s in stdbuf node; do [ -f "$SHIM/$s" ] && echo "shim $s: $(tail -n 1 "$SHIM/$s")"; done
    echo "WS_SEND_BACKLOG_* env: [${WS_SEND_BACKLOG_MAX_BYTES:-unset}] [${WS_SEND_BACKLOG_MAX_UNWRITABLE_MS:-unset}]"
    echo "sync-path env: unset for the server; the shell had $SYNC_PATH_SHELL"
    echo "wire env: PATH_INDEX=[${PATH_INDEX:-unset}] FIELD_MERGE=[${FIELD_MERGE:-unset}] TRANSPORT_ENCODING=[${TRANSPORT_ENCODING:-unset}]"
    echo "spawn ramp env: HERO_DEFENSE_SPAWN_RAMP_TICKS=[${HERO_DEFENSE_SPAWN_RAMP_TICKS:-unset}]"
    swift --version 2>&1
    node --version
    uname -r
    uptime
  } > "$header"
  mkdir -p "$OUT/$name"
  export HERO_DEFENSE_STATS_PATH="$stats"
  watch_server_affinity "$OUT/$name.server-affinity.txt" &
  watcher=$!
  set +e
  if [ -n "$path_prefix" ]; then
    (cd "$WS" && PATH="$SHIM:$PATH" bash "$SCALABILITY_SCRIPT" "${args[@]}") > "$OUT/$name.log" 2>&1
  else
    (cd "$WS" && bash "$SCALABILITY_SCRIPT" "${args[@]}") > "$OUT/$name.log" 2>&1
  fi
  code=$?
  set -e
  # The server has exited with the run: the watcher has seen it or never will.
  stop_watcher
  echo "exit=$code end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$header"
  mkdir -p "$OUT/$name"
  if [ -f "$SERVER_LOG" ]; then
    cp "$SERVER_LOG" "$OUT/$name/gameserver.log"
    echo "server log: $name/gameserver.log" >> "$header"
  else
    echo "server log: none (the server didn't write one)" >> "$header"
  fi
  # A summary isn't proof the run ran (e6f30a74: a summary read clean after skipping room counts):
  # it must name this run's room count and that run's report must exist.
  summary=$(find "$OUT/$name" -name summary.json -type f | sed -n 1p)  # not head: pipefail (see first_records)
  why=""
  if [ -z "$summary" ]; then
    why="no summary"
  else
    why=$(python3 - "$summary" "$rooms" "$WS" <<'PY'
import json, os, sys
path, rooms, ws = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    summary = json.load(open(path))
except (OSError, ValueError) as e:
    print(f"unreadable summary ({e})")
    sys.exit(0)
counts = (summary.get("config") or {}).get("roomCounts")
runs = summary.get("runs") or []
if counts != [rooms]:
    print(f"the summary's room counts are {counts}, not [{rooms}]")
elif len(runs) != 1 or runs[0].get("rooms") != rooms:
    print(f"the summary's runs are {[r.get('rooms') for r in runs]}, not one run of {rooms} rooms")
else:
    report = runs[0].get("reportJson") or ""
    if not report or not os.path.isfile(report if os.path.isabs(report) else os.path.join(ws, report)):
        print(f"the summary's run has no report file ({report or 'none named'})")
PY
)
  fi
  if [ -n "$why" ]; then
    echo "$name: $why; see $OUT/$name.log" >&2
    echo "summary check: $why" >> "$header"
    status "$name" failed-no-summary
    exit 1
  fi
  # The spawn ramp the server ran with: its startup line in the log (none from a build without it).
  # Only from a log there is: under pipefail a sed on a missing file would end the sweep.
  ramp=""
  if [ -f "$OUT/$name/gameserver.log" ]; then
    ramp=$(sed -n 's/^GameServer effective spawnRampTicks=\(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$OUT/$name/gameserver.log" | sed -n 1p)
  fi
  echo "server spawnRampTicks: ${ramp:-<not reported>}" >> "$header"
  python3 - "$OUT/run.json" "$name" "$ramp" <<'PY'
import json, sys
path, name, ramp = sys.argv[1:]
record = json.load(open(path))
record.setdefault("spawnRampTicksEffective", {})[name] = int(ramp) if ramp else None
open(path, "w").write(json.dumps(record, indent=2) + "\n")
PY
  # A run without a server log is already recorded so ("server log: none"); one with a log must show the ramp.
  if [ -f "$OUT/$name/gameserver.log" ] && [ "$ramp" != "$SPAWN_RAMP_EXPECTED" ]; then
    echo "$name: the server ran with spawnRampTicks '${ramp:-<not reported>}', not $SPAWN_RAMP_EXPECTED" >&2
    status "$name" failed-spawn-ramp; exit 1
  fi
  # The running server's CPU list, read by the watcher: with pinning, the server shim must have run.
  affinity=$(cat "$OUT/$name.server-affinity.txt" 2>/dev/null || true)
  echo "server Cpus_allowed_list: ${affinity:-<not seen>}" >> "$header"
  if [ -n "$SERVER_CPUS" ] && ! same_cpus "$affinity" "$SERVER_CPUS"; then
    echo "$name: the server ran on CPUs '${affinity:-<not seen>}', not $SERVER_CPUS" >&2
    status "$name" failed-pinning; exit 1
  fi
  # A profiled run keeps its server profile in its raw directory, which goes to the private store with
  # the rest: the per-input costs #430 asks for are built from it later, without re-measuring.
  if [ "$profiled" = 1 ]; then
    profile=$(find "$OUT/$name" -name transport-profile.jsonl -type f -size +0 | sed -n 1p)  # not head: pipefail
    if [ -z "$profile" ]; then
      echo "server profile: none" >> "$header"
      echo "$name: a profiled run, but its server left no transport-profile.jsonl in $OUT/$name" >&2
      status "$name" failed-no-profile; exit 1
    fi
    echo "server profile: ${profile#"$OUT"/}" >> "$header"
  fi
  # The load client must not have been the bottleneck (clientload.py): the sweep stops when it may have been.
  rc=0; load=$(python3 "$TOPIC/clientload.py" check "$summary" "$WS" "$CLIENT_CPUS") || rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$load" | sed 's/^/client load: /' >> "$header"
    if [ "$rc" = 1 ]; then
      echo "$name: the load client may have been the bottleneck:" >&2
    else
      echo "$name: the client-load check couldn't run (exit $rc):" >&2
    fi
    printf '%s\n' "$load" >&2
    status "$name" failed-client-load; exit 1
  fi
  echo "client load: within the bounds" >> "$header"
  # The profiler-overhead pair, back to back before the suites: a profiler that moved the RTT tail
  # stops the sweep, since every table's RTT comes from profiled runs (profiler_overhead.py).
  [ "$name" = overhead-profiled ] && profiled_summary="$summary"
  if [ "$name" = overhead-unprofiled ] && [ -z "${profiled_summary-}" ]; then
    echo "profiler overhead: not checked (overhead-profiled didn't run in this invocation)" >> "$header"
  elif [ "$name" = overhead-unprofiled ]; then
    rc=0; overhead=$(python3 "$TOPIC/profiler_overhead.py" check "$profiled_summary" "$summary" "$WS") || rc=$?
    if [ "$rc" != 0 ]; then
      echo "profiler overhead: $overhead" >> "$header"
      echo "$name: $overhead" >&2
      status "$name" failed-profiler-overhead; exit 1
    fi
    echo "profiler overhead: $overhead" >> "$header"
  fi
  if [ "$code" = 0 ]; then
    status "$name" passed
    echo "done $name"
  else
    FAILED=$((FAILED + 1))
    status "$name" failed-run
    echo "$name failed (exit $code); see $OUT/$name.log" >&2
    # The preflight is the gate before the suites: they don't run after it fails.
    if [ "$name" = preflight ]; then
      echo "the preflight failed: the sweep stops before the suites" >&2
      exit 1
    fi
  fi
done
if [ "$DRY_RUN" = 1 ]; then echo "+ end $OUT/run.json"; else "${META[@]}" end "$OUT"; fi
[ "$FAILED" = 0 ] || { echo "$FAILED run(s) failed" >&2; exit 1; }

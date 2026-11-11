#!/usr/bin/env bash
# Checks EncodingBenchmark's `--join-through-router` and `--row-addressing`:
# - each refused combination exits 2 and names what it refuses;
# - a small router run (messagepack-pathhash, row addressing on and off) completes, every
#   session joined, and its result's routerJoin records perConnection bytes and whether row
#   entries were in effect, the sync-lag policy it ran with, no connection the server closed,
#   and every ack taken (none dropped, no session with unacked frames after the last sync);
# - a run without the flags has no routerJoin and records both flags off;
# - --active-players' injected moves reach router-joined players.
# Usage: Examples/GameDemo/scripts/check-encoding-benchmark-router.sh [path to a built EncodingBenchmark]
# Without a path it builds EncodingBenchmark in debug. Runs in CI's examples job.
set -euo pipefail

cd "$(dirname "$0")/.."
BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  # A debug build is enough: this checks behaviour, not numbers (and CI's `swift test` has built it).
  swift build --product EncodingBenchmark >/dev/null
  BIN="$(swift build --show-bin-path)/EncodingBenchmark"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BENCHMARK_RESULTS_DIR="$WORK/results"
failures=0

refuses() {
  local expected="$1"
  shift
  local code=0
  "$BIN" "$@" >"$WORK/out" 2>&1 || code=$?
  if [[ "$code" != 2 ]] || ! grep -qF -- "$expected" "$WORK/out"; then
    echo "FAIL: $* exited $code, expected 2 with: $expected"
    sed -n '1,5s/^/    /p' "$WORK/out"
    failures=$((failures + 1))
  else
    echo "ok: refuses $*"
  fi
}

refuses "--row-addressing on doesn't support runs without --join-through-router on" --row-addressing on --rooms 2
refuses "--format opcode-json (row entries need a -pathhash format)" --join-through-router on --row-addressing on --format opcode-json --rooms 2
refuses "--row-addressing on doesn't support --all" --join-through-router on --row-addressing on --all --rooms 2
refuses "--join-through-router on doesn't support --format json-object" --join-through-router on --format json-object --rooms 2
refuses "--all (it runs the json-object format)" --join-through-router on --all --rooms 2
refuses "--game-type other than hero-defense" --join-through-router on --game-type card-game --rooms 2
refuses "--use-worker-pool" --join-through-router on --use-worker-pool --rooms 2
refuses "--compare-worker-pool" --join-through-router on --compare-worker-pool --rooms 2
refuses "--hash-cost" --join-through-router on --hash-cost
refuses "--baseline entity-delta" --join-through-router on --baseline entity-delta --parallel false --rooms 2

# Reads a JSON result from stdout (the last top-level object) and checks it with python.
run_json() {
  local name="$1" check="$2"
  shift 2
  if ! "$BIN" "$@" --output json --iterations 5 --ticks-per-sync 1 >"$WORK/$name.out" 2>"$WORK/$name.err"; then
    echo "FAIL: $name: $* exited non-zero"
    sed 's/^/    /' "$WORK/$name.out" "$WORK/$name.err" | tail -8
    failures=$((failures + 1))
    return
  fi
  if python3 -I - "$WORK/$name.out" "$check" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
start = text.rfind("\n{") + 1 if not text.startswith("{") else 0
result = json.loads(text[start:])
check = sys.argv[2]
router = result.get("routerJoin")
if check == "default":
    assert router is None, f"routerJoin on a default run: {router}"
    config = result["config"]
    assert config["joinThroughRouter"] is False and config["rowAddressing"] is False, config
elif check in ("rows-on", "rows-off"):
    assert router, "no routerJoin"
    assert router["joinPath"] == "router" and router["bytesCounted"] == "perConnection", router
    assert router["rowAddressingRequested"] == (check == "rows-on"), router
    assert router["rowAddressingInEffect"] == (check == "rows-on"), router
    assert ("rowAddressing" in router["stateUpdateFeatures"]) == (check == "rows-on"), router
    # The lands run as hosted: the sync sequence is on, every connection acks, and none is closed.
    assert "syncSequence" in router["stateUpdateFeatures"], router
    assert router["serverCloses"] == 0, router
    # Every ack was taken: none dropped, no session left with unacked frames after the last sync.
    assert router["droppedAcks"] == 0 and router["sessionsWithUnackedFrames"] == 0, router
    assert "resyncAfterMs" in router["syncLagPolicy"], router
    assert result["bytesPerSync"] > 0, result["bytesPerSync"]
else:
    raise SystemExit(f"unknown check {check}")
PY
  then
    echo "ok: $name"
  else
    echo "FAIL: $name: its result didn't pass the $check check"
    failures=$((failures + 1))
  fi
}

run_json default default --format messagepack-pathhash --rooms 2 --players-per-room 3 --parallel false
run_json router-rows-off rows-off --format messagepack-pathhash --rooms 2 --players-per-room 3 --parallel false --join-through-router on
run_json router-rows-on rows-on --format messagepack-pathhash --rooms 2 --players-per-room 3 --parallel true --join-through-router on --row-addressing on
run_json router-rows-on-json rows-on --format opcode-json-pathhash --rooms 1 --players-per-room 3 --parallel false --join-through-router on --row-addressing on

# The injected moves reach router-joined players: a keeper takes a player's input only from the
# client ID the transport assigned, so with --active-players the router path must send more.
bytes_per_sync() {
  "$BIN" --format messagepack-pathhash --rooms 1 --players-per-room 3 --parallel false --join-through-router on \
    "$@" --output json --iterations 10 --ticks-per-sync 1 2>/dev/null |
    python3 -I -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.rfind("\n{")+1:] if not t.startswith("{") else t)["bytesPerSync"])'
}
idle="$(bytes_per_sync)"
active="$(bytes_per_sync --active-players)"
if [[ -n "$idle" && -n "$active" && "$active" -gt "$idle" ]]; then
  echo "ok: active players move the router path ($idle -> $active bytes per sync)"
else
  echo "FAIL: --active-players didn't change the router path's bytes ($idle -> $active)"
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all router flag checks passed"

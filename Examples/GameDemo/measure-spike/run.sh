#!/bin/bash
# One ws-loadtest run against GameServer (release) from a worktree.
# usage: run.sh <tree: base|spike|variant> <scenario.json> <outdir> <encoding> [ENV=VAL ...]
# env: PPR (players per room, default 1), WORKERS (default 8), LOADTEST_DIAG_DIR (client diagnostics)
set -u
source "$(dirname "$0")/lib.sh"
TREE=$1; SC=$2; OUT=$3; ENC=$4; shift 4
mkdir -p "$OUT"
[ -n "${LOADTEST_DIAG_DIR:-}" ] && mkdir -p "$LOADTEST_DIAG_DIR"
BIN=$(cd $M/$TREE/Examples/GameDemo && swift build -c release --show-bin-path)/GameServer
[ -x "$BIN" ] || { echo "missing binary $BIN: build it first (setup.sh)"; exit 1; }
kill_port
( cd $M/$TREE/Examples/GameDemo && env LOG_LEVEL=error NO_COLOR=1 ENABLE_REEVALUATION=false \
    REEVALUATION_RECORDS_DIR=/tmp/spike-reeval TRANSPORT_ENCODING=$ENC SPIKE_MAX_PLAYERS=64 \
    SPIKE_METRICS_PATH=$OUT/metrics.jsonl SPIKE_METRICS_INTERVAL_S=5 "$@" "$BIN" > $OUT/server.log 2>&1 ) &
for i in $(seq 1 60); do (echo >/dev/tcp/localhost/8080) 2>/dev/null && break; sleep 0.5; done
SPID=$(port_pid)
bash $WS/monitoring/collect-system-metrics.sh "$SPID" "$OUT/system.json" 1 > /dev/null 2>&1 &
MON=$!
cpusample $OUT/cpu.txt $SPID &
date +%s > $OUT/start
( cd $WS && LOADTEST_PLAYERS_PER_ROOM=${PPR:-1} node dist/cli.js --scenario "$SC" --workers ${WORKERS:-8} --output-dir "$OUT" --system-metrics "$OUT/system.json" > $OUT/client.log 2>&1 )
kill $MON 2>/dev/null
sleep 6   # last metrics window
kill -TERM $SPID 2>/dev/null; sleep 2; kill -9 $SPID 2>/dev/null
echo "$(date +%T) done $TREE $(basename $SC) $ENC -> $OUT"

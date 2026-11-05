#!/bin/bash
# One ServerLoadTest run (in-process transport, no sockets) from the base worktree.
# usage: slt.sh <A|B> <rooms> <outdir>   A: no client decode, B: full client decode (LOADTEST_CLIENT_DECODE=1)
# Workload as ws-loadtest: PlayAction 1/s per player (LOADTEST_SEND=action); ramp 8 / steady 65 / down 5 s.
set -u
source "$(dirname "$0")/lib.sh"
ARM=$1; N=$2; OUT=$3; mkdir -p $OUT
BIN=$(cd $M/base/Examples/GameDemo && swift build -c release --show-bin-path)/ServerLoadTest
[ -x "$BIN" ] || { echo "missing binary $BIN: build it first (setup.sh)"; exit 1; }
DEC=0; [ "$ARM" = B ] && DEC=1
date +%s > $OUT/start
( cd $OUT && env LOADTEST_SEND=action LOADTEST_CLIENT_DECODE=$DEC SPIKE_METRICS_PATH=$OUT/metrics.jsonl SPIKE_METRICS_INTERVAL_S=5 \
    "$BIN" --rooms $N --players-per-room 5 --ramp-up-seconds 8 --duration-seconds 65 --ramp-down-seconds 5 --log-level error > $OUT/slt.log 2>&1 ) &
PID=$!
sleep 1; SPID=$(pgrep -nf "[S]erverLoadTest --rooms")
cpusample $OUT/cpu.txt $SPID &
wait $PID
echo "$(date +%T) done slt $ARM $N -> $OUT"

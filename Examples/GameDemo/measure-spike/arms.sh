#!/bin/bash
# Client cost: A (ServerLoadTest, no decode), B (ServerLoadTest + full client decode), C (ws-loadtest,
# with diagnostics), base tree, 5-player rooms, 300 and 500 rooms, n=3, interleaved A,B,C.
source "$(dirname "$0")/lib.sh"
O=$R/arms
# smoke: B must record clientDecode and clientRTT
mkdir -p $O/smoke
BIN=$(cd $M/base/Examples/GameDemo && swift build -c release --show-bin-path)/ServerLoadTest
(cd $O/smoke && LOADTEST_SEND=action LOADTEST_CLIENT_DECODE=1 SPIKE_METRICS_PATH=$O/smoke/metrics.jsonl SPIKE_METRICS_INTERVAL_S=2 \
  "$BIN" --rooms 2 --players-per-room 5 --ramp-up-seconds 2 --duration-seconds 6 --ramp-down-seconds 1 --log-level error > $O/smoke/slt.log 2>&1)
grep -q clientDecode $O/smoke/metrics.jsonl && grep -q clientRTT $O/smoke/metrics.jsonl || { echo "SMOKE FAILED (see $O/smoke)"; exit 1; }
for i in 1 2 3; do
  for n in 300 500; do
    $S/slt.sh A $n $O/A-$n-$i
    $S/slt.sh B $n $O/B-$n-$i
    C=$O/C-$n-$i; mkdir -p $C/client; tcp_stats > $C/tcp-before.txt
    LOADTEST_DIAG_DIR=$C/client PPR=5 WORKERS=5 $S/run.sh base $S/scenarios/cap$n.json $C messagepack LOG_LEVEL=info 2>/dev/null
    tcp_stats > $C/tcp-after.txt
  done
done
python3 $S/analyze_arms.py $O > $O/summary.txt; echo "ARMS DONE -> $O/summary.txt"
# If C's disconnects are ping/pong timeouts during worker event-loop lag (see summary), run:
#   for i in 1 2 3; do C=$O/C10-500-$i; mkdir -p $C/client; tcp_stats > $C/tcp-before.txt
#     LOADTEST_DIAG_DIR=$C/client PPR=5 WORKERS=10 $S/run.sh base $S/scenarios/cap500.json $C messagepack LOG_LEVEL=info
#     tcp_stats > $C/tcp-after.txt; done

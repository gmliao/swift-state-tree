#!/bin/bash
# Coincident-sync (fold) variant vs base: cap300 (5-player rooms, messagepack, 5 workers) and
# json50 (one 50-player room, json, 1 worker), n=3, interleaved base/variant per scenario.
source "$(dirname "$0")/lib.sh"
O=$R/fold
for i in 1 2 3; do
  for t in base variant; do PPR=5 WORKERS=5 $S/run.sh $t $S/scenarios/cap300.json $O/cap300-$t-$i messagepack 2>/dev/null; done
  for t in base variant; do PPR=50 WORKERS=1 $S/run.sh $t $S/scenarios/json50.json $O/json50-$t-$i json 2>/dev/null; done
done
python3 $S/summarize.py $O > $O/summary.txt; echo "FOLD DONE -> $O/summary.txt"

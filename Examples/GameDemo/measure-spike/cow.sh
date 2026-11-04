#!/bin/bash
# CoW copy accounting (SPIKE_COW=1): base vs spike, cap300 + json50, n=3, interleaved.
# Applies cow/cow_patch.py to both worktrees, rebuilds, runs, then reverts and rebuilds.
source "$(dirname "$0")/lib.sh"
O=$R/cow
for t in base spike; do
  python3 $S/cow/cow_patch.py $M/$t || exit 1
  (cd $M/$t/Examples/GameDemo && swift build -c release --product GameServer 2>&1 | grep -E "error:|Build complete" | tail -3)
done
for i in 1 2 3; do
  for t in base spike; do PPR=5 WORKERS=5 $S/run.sh $t $S/scenarios/cap300.json $O/cap300-$t-$i messagepack SPIKE_COW=1 2>/dev/null; done
  for t in base spike; do PPR=50 WORKERS=1 $S/run.sh $t $S/scenarios/json50.json $O/json50-$t-$i json SPIKE_COW=1 2>/dev/null; done
done
for t in base spike; do
  (cd $M/$t && git checkout -- Sources/SwiftStateTree/Sync/SyncPolicy.swift Sources/SwiftStateTree/Runtime/LandKeeper.swift && rm -f Sources/SwiftStateTree/Support/SpikeCow.swift)
  (cd $M/$t/Examples/GameDemo && swift build -c release --product GameServer 2>&1 | tail -1)
done
python3 $S/analyze_cow.py $O > $O/summary.txt; echo "COW DONE -> $O/summary.txt"

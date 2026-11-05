#!/bin/bash
# CoW copy accounting (SPIKE_COW=1): base vs spike, cap300 + json50, n=3, interleaved.
# Applies cow/cow_patch.py to both worktrees, rebuilds, runs, then reverts and rebuilds.
source "$(dirname "$0")/lib.sh"
O=$R/cow
mkdir -p $O
revert_patch() {
  (cd $M/$1 && git checkout -- Sources/SwiftStateTree/Sync/SyncPolicy.swift Sources/SwiftStateTree/Runtime/LandKeeper.swift && rm -f Sources/SwiftStateTree/Support/SpikeCow.swift)
}
# Builds GameServer in tree $1 (log $2). A failed build aborts the script (after reverting the
# patch in both trees), so a stale binary is never measured.
build_or_die() {
  if ! (cd $M/$1/Examples/GameDemo && swift build -c release --product GameServer > "$2" 2>&1); then
    grep -E "error:" "$2" | head -10
    echo "COW ABORTED: GameServer build failed in $1 (log: $2); patch reverted, rebuild before other runs"
    revert_patch base; revert_patch spike
    exit 1
  fi
  tail -1 "$2"
}
for t in base spike; do
  python3 $S/cow/cow_patch.py $M/$t || exit 1
  build_or_die $t $O/build-patched-$t.log
done
for i in 1 2 3; do
  for t in base spike; do PPR=5 WORKERS=5 $S/run.sh $t $S/scenarios/cap300.json $O/cap300-$t-$i messagepack SPIKE_COW=1 2>/dev/null; done
  for t in base spike; do PPR=50 WORKERS=1 $S/run.sh $t $S/scenarios/json50.json $O/json50-$t-$i json SPIKE_COW=1 2>/dev/null; done
done
for t in base spike; do
  revert_patch $t
  build_or_die $t $O/build-reverted-$t.log
done
python3 $S/analyze_cow.py $O > $O/summary.txt; echo "COW DONE -> $O/summary.txt"

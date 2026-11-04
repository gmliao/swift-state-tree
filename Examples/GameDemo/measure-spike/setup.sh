#!/bin/bash
# usage: MEASURE_ROOT=<empty dir> ./setup.sh   (run from a clone of the repo)
# Creates the three worktrees, builds every release binary and the load client. Run once, before
# any measurement: no build may run during a measurement window.
set -eu
: "${MEASURE_ROOT:?}"
REPO=$(git rev-parse --show-toplevel)
git -C $REPO fetch origin measure/base-59894dc measure/spike-672b559 measure/variant-fold
mkdir -p $MEASURE_ROOT
git -C $REPO worktree add --detach $MEASURE_ROOT/base    origin/measure/base-59894dc
git -C $REPO worktree add --detach $MEASURE_ROOT/spike   origin/measure/spike-672b559
git -C $REPO worktree add --detach $MEASURE_ROOT/variant origin/measure/variant-fold
for t in base spike variant; do
  (cd $MEASURE_ROOT/$t/Examples/GameDemo && swift build -c release --product GameServer)
done
(cd $MEASURE_ROOT/base/Examples/GameDemo && swift build -c release --product ServerLoadTest)
(cd $MEASURE_ROOT/base/Examples/GameDemo/ws-loadtest && npm ci && npm run build)
echo "setup done: $MEASURE_ROOT"

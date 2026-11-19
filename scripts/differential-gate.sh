#!/usr/bin/env bash
# The differential harness's gate run (#555, plan rev 10 "The gate"), job 2 of 2: in the pinned
# image, under the verify key, the full matrix compared with the goldens, bytes included. Fails
# closed: the wrong toolchain, a skipped or filtered-out suite, zero cells, a masked cell, or
# fewer cells compared than the index lists each fail. Prints the counts and the SHA it built.
#
# Usage (in the pinned image): scripts/differential-gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_SWIFT="Swift version 6.2.4"
FILTER='SwiftStateTreeNIOTests\.(DifferentialHarnessTests|DiffSelfCheckTests)'
INDEX=Tests/SwiftStateTreeNIOTests/Differential/Golden/index.json

VERSION=$(swift --version 2>&1)
VERSION=${VERSION%%$'\n'*}
case "$VERSION" in
    *"$EXPECTED_SWIFT"*) ;;
    *) echo "differential-gate: expected $EXPECTED_SWIFT, got: $VERSION" >&2; exit 1 ;;
esac
if [[ "${IN_TURN_SYNC:-true}" == "false" ]]; then
    echo "differential-gate: IN_TURN_SYNC=false would mask the in-turn cells; the gate runs the full matrix" >&2
    exit 1
fi
[[ -f "$INDEX" ]] || { echo "differential-gate: no golden index" >&2; exit 1; }
LISTED=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['files']))" "$INDEX")

git config --global --add safe.directory "$PWD" 2>/dev/null || true
echo "differential-gate: building $(git rev-parse HEAD) with $VERSION"
export SST_DIFFERENTIAL_VERIFY=1
SST_TOOLCHAIN="$(uname -sm) $VERSION"
export SST_TOOLCHAIN
unset SST_UPDATE_GOLDEN

swift build --build-tests
LOG=$(mktemp)
set +e
swift test --skip-build --filter "$FILTER" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
[[ "$STATUS" == "0" ]] || { echo "differential-gate: the harness failed" >&2; exit 1; }

COUNTS=$(grep -E "^Differential harness: [0-9]+ cell\(s\) compared" "$LOG" | tail -1 || true)
[[ -n "$COUNTS" ]] || { echo "differential-gate: the harness suite didn't run" >&2; exit 1; }
RAN=$(sed -E 's/^Differential harness: ([0-9]+) cell.*/\1/' <<< "$COUNTS")
MASKED=$(sed -E 's/.* ([0-9]+) masked.*/\1/' <<< "$COUNTS")
echo "differential-gate: $RAN compared, $MASKED masked, $LISTED listed"
[[ "$RAN" -gt 0 && "$MASKED" == "0" && "$RAN" == "$LISTED" ]] \
    || { echo "differential-gate: the counts don't cover the index" >&2; exit 1; }
if grep -q "decoded views only" "$LOG"; then
    echo "differential-gate: the goldens weren't recorded with this toolchain; bytes weren't compared" >&2
    exit 1
fi
echo "differential-gate: passed at $(git rev-parse HEAD)"

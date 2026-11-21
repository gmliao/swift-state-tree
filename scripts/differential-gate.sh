#!/usr/bin/env bash
# The differential harness's gate run (#555, plan rev 10 "The gate"), job 2 of 2: in the pinned
# image, under the verify key, the full matrix compared with the goldens, bytes included. Fails
# closed: the wrong toolchain, a skipped or filtered-out suite, zero cells, or
# fewer cells compared than the index lists each fail. Every test the two suites declare must
# be in Swift Testing's results (its xunit file), passed: a printed line proves nothing. The
# lists flag (SST_DIFFERENTIAL_MAIN_LISTS, 1 on main) is the workflow's to state. Prints the
# counts and the SHA it built.
#
# Usage (in the pinned image): scripts/differential-gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_SWIFT="Swift version 6.2.4"
FILTER='^SwiftStateTreeNIOTests\.DifferentialHarness/(DifferentialHarnessTests|DiffSelfCheckTests)/'
INDEX=Tests/SwiftStateTreeNIOTests/Differential/Golden/index.json
SUITES=(Tests/SwiftStateTreeNIOTests/Differential/DifferentialHarnessTests.swift
        Tests/SwiftStateTreeNIOTests/Differential/DiffSelfCheckTests.swift)

VERSION=$(swift --version 2>&1)
VERSION=${VERSION%%$'\n'*}
case "$VERSION" in
    *"$EXPECTED_SWIFT"*) ;;
    *) echo "differential-gate: expected $EXPECTED_SWIFT, got: $VERSION" >&2; exit 1 ;;
esac
case "${SST_DIFFERENTIAL_MAIN_LISTS:-}" in
    0|1) ;;
    *) echo "differential-gate: SST_DIFFERENTIAL_MAIN_LISTS must be 0 or 1 (the workflow states whose lists these are)" >&2; exit 1 ;;
esac
[[ -f "$INDEX" ]] || { echo "differential-gate: no golden index" >&2; exit 1; }
LISTED=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['files']))" "$INDEX")

git config --global --add safe.directory "$PWD" 2>/dev/null || true
echo "differential-gate: building $(git rev-parse HEAD) with $VERSION"
export SST_DIFFERENTIAL_VERIFY=1
SST_TOOLCHAIN="$(uname -sm) $VERSION"
export SST_TOOLCHAIN
unset SST_UPDATE_GOLDEN

swift build --build-tests
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/test.log"
set +e
swift test --skip-build --no-parallel --filter "$FILTER" --xunit-output "$WORK/xunit.xml" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
[[ "$STATUS" == "0" ]] || { echo "differential-gate: the harness failed" >&2; exit 1; }

# Every @Test in the two suites' (protected) files, by suite, passed in Swift Testing's results.
python3 - "$WORK/xunit-swift-testing.xml" "${SUITES[@]}" <<'PY'
import re, sys, xml.etree.ElementTree as ET
results, files = sys.argv[1], sys.argv[2:]
try:
    cases = ET.parse(results).getroot().iter("testcase")
except (OSError, ET.ParseError) as error:
    sys.exit(f"differential-gate: no Swift Testing results ({error})")
# A completed result: a `time`, and no failure, skip or error. Keyed by the fully qualified ID.
passed = set()
for case in cases:
    if case.get("time") and all(case.find(tag) is None for tag in ("failure", "skipped", "error")):
        passed.add((case.get("classname", ""), case.get("name", "")))
missing = []
for path in files:
    suite = "SwiftStateTreeNIOTests.DifferentialHarness." + path.rsplit("/", 1)[-1].removesuffix(".swift")
    text = open(path).read()
    names = re.findall(r"@Test\b[^\n]*\n\s*func\s+(\w+)\(", text)
    declared = len(re.findall(r"^\s*@Test\b", text, re.M))
    if not names or len(names) != declared:
        sys.exit(f"differential-gate: {path} has {declared} @Test line(s) but {len(names)} test name(s) found: put each @Test on the line before its func")
    missing += [f"{suite}.{name}()" for name in names if (suite, f"{name}()") not in passed]
if missing:
    sys.exit("differential-gate: these tests didn't pass in the results: " + ", ".join(missing))
print(f"differential-gate: every declared test passed ({len(passed)} in the results)")
PY

# The harness's summary: "<run> cell(s) run, <compared> compared, <threw> threw, <replaced>
# replaced, <listed> listed". A cell that threw is run but not compared.
COUNTS_RE='^Differential harness: ([0-9]+) cell\(s\) run, ([0-9]+) compared, ([0-9]+) threw, ([0-9]+) replaced, ([0-9]+) listed$'
[[ $(grep -cE "$COUNTS_RE" "$LOG") == "1" ]] \
    || { echo "differential-gate: expected exactly one counts line from the harness" >&2; exit 1; }
COUNTS=$(grep -E "$COUNTS_RE" "$LOG")
RAN=$(sed -E "s/$COUNTS_RE/\1/" <<< "$COUNTS")
COMPARED=$(sed -E "s/$COUNTS_RE/\2/" <<< "$COUNTS")
THREW=$(sed -E "s/$COUNTS_RE/\3/" <<< "$COUNTS")
REPLACED=$(sed -E "s/$COUNTS_RE/\4/" <<< "$COUNTS")
echo "differential-gate: $RAN run, $COMPARED compared, $THREW threw, $REPLACED replaced (retired rows), $LISTED listed"
[[ "$RAN" -gt 0 && $((RAN + REPLACED)) == "$LISTED" ]] \
    || { echo "differential-gate: the counts don't cover the index" >&2; exit 1; }
[[ "$THREW" == "0" && "$COMPARED" == "$RAN" ]] \
    || { echo "differential-gate: $THREW cell(s) threw; $COMPARED of $RAN run were compared" >&2; exit 1; }
if grep -q "decoded views only" "$LOG"; then
    echo "differential-gate: the goldens weren't recorded with this toolchain; bytes weren't compared" >&2
    exit 1
fi
echo "differential-gate: passed at $(git rev-parse HEAD)"

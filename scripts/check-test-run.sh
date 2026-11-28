#!/usr/bin/env bash
# Fails a CI test step whose log shows a test run that verified nothing (#975). `swift test`
# exits 0 when Swift Testing discovers no tests in a bundle (a Windows release build found none
# in six of seven bundles) and when a filter matches nothing, so the exit status alone is a
# false green. The step fails when its log has:
#   - `No matching test cases were run` (a filter that matched no test);
#   - a Swift Testing closing line `Test run with 0 tests` (a bundle that ran and found none);
#   - no Swift Testing closing line at all.
# Bundles without a match for a step's filter print no Swift Testing block (Linux and macOS,
# checked on CI run 46111237290), so a zero-test block in a green run is never expected. Every
# step this checks runs Swift Testing tests; XCTest's per-bundle `Executed 0 tests` lines are
# ignored (only one XCTest test exists, and every bundle prints its line).
# Assumption: a step that runs only XCTest tests prints no Swift Testing closing line, so this
# check would fail it falsely. No step it is wired into is one; don't wire it into one.
# Carriage returns and NUL bytes are removed before matching, so a log with Windows line ends
# or written as UTF-16 is read whole; the patterns are ASCII, matched in the C locale as text,
# so a non-ASCII byte left over from UTF-16 can't turn a line into a binary match.
#
# Usage: scripts/check-test-run.sh <log> <step name>
#        scripts/check-test-run.sh --self-test

set -euo pipefail

# Prints the log's closing lines; exits 1, with a GitHub error annotation, when the run verified
# nothing.
check() {
  local log=$1 step=$2 text closing
  text=$(LC_ALL=C tr -d '\r\000' < "$log")
  closing=$(LC_ALL=C grep -aE 'Test run with [0-9]+ tests? in ' <<<"$text" || true)
  if [ -n "$closing" ]; then
    echo "Swift Testing closing lines:"
    echo "$closing"
  fi
  if LC_ALL=C grep -aq 'No matching test cases were run' <<<"$text"; then
    echo "::error title=$step::the filter matched no test (\"No matching test cases were run\", #975)"
    return 1
  fi
  if [ -z "$closing" ]; then
    echo "::error title=$step::no Swift Testing closing line (\"Test run with N tests\"): the run verified nothing (#975)"
    return 1
  fi
  if LC_ALL=C grep -aqE 'Test run with 0 tests in ' <<<"$closing"; then
    echo "::error title=$step::a test bundle ran 0 tests (\"Test run with 0 tests\", #975)"
    return 1
  fi
}

self_test() {
  local dir status=0
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' RETURN

  # A green run: seven bundles, one with known issues, and XCTest's empty lines.
  cat > "$dir/good.log" <<'EOF'
Build complete! (12.34s)
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
◇ Test run started.
✔ Test run with 271 tests in 21 suites passed after 0.408 seconds.
◇ Test run started.
✔ Test run with 56 tests in 3 suites passed after 44.091 seconds.
◇ Test run started.
✔ Test run with 1061 tests in 151 suites passed after 12.885 seconds.
◇ Test run started.
━ Test run with 1446 tests in 164 suites passed after 13.474 seconds with 6 known issues.
◇ Test run started.
✔ Test run with 396 tests in 61 suites passed after 5.842 seconds.
◇ Test run started.
✔ Test run with 84 tests in 12 suites passed after 3.899 seconds.
◇ Test run started.
✔ Test run with 1 test in 1 suite passed after 0.008 seconds.
EOF
  # #975, Windows release, unfiltered: six bundles found no tests, the macro suites ran.
  cat > "$dir/zero.log" <<'EOF'
Build complete! (812.45s)
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
✔ Test run with 84 tests in 12 suites passed after 3.120 seconds.
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
EOF
  # #975, Windows release, with CI's filter: nothing ran.
  cat > "$dir/nomatch.log" <<'EOF'
Build complete! (801.02s)
warning: No matching test cases were run
EOF
  # A run that printed no Swift Testing summary (it crashed before one, or ran no bundle).
  printf 'Build complete! (1.00s)\n' > "$dir/none.log"
  # The good and zero-test logs with Windows line ends, and as UTF-16.
  sed 's/$/\r/' "$dir/good.log" > "$dir/good-crlf.log"
  sed 's/$/\r/' "$dir/zero.log" > "$dir/zero-crlf.log"
  iconv -f UTF-8 -t UTF-16LE "$dir/good-crlf.log" > "$dir/good-utf16.log"
  iconv -f UTF-8 -t UTF-16LE "$dir/zero-crlf.log" > "$dir/zero-utf16.log"

  expect() {
    local want=$1 name=$2 out got=0
    out=$(check "$dir/$name.log" "self-test $name" 2>&1) || got=$?
    if [ "$want" = pass ] && [ "$got" -ne 0 ]; then
      echo "self-test: $name should pass, failed:"; echo "$out"; status=1
    elif [ "$want" = fail ] && [ "$got" -eq 0 ]; then
      echo "self-test: $name should fail, passed:"; echo "$out"; status=1
    fi
  }
  expect pass good
  expect pass good-crlf
  expect pass good-utf16
  expect fail zero
  expect fail zero-crlf
  expect fail zero-utf16
  expect fail nomatch
  expect fail none
  if [ "$status" -eq 0 ]; then echo "check-test-run self-test passed"; fi
  return "$status"
}

if [ "${1:-}" = --self-test ]; then
  self_test
  exit $?
fi
if [ $# -ne 2 ]; then
  echo "usage: $0 <log> <step name> | --self-test" >&2
  exit 2
fi
check "$1" "$2"

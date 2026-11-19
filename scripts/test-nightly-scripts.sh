#!/usr/bin/env bash
# Tests scripts/nightly-gate.sh and scripts/nightly-report.sh against a stub `gh` that logs every
# call and answers from FAKE_* variables, in a throwaway git repository.
# Usage: scripts/test-nightly-scripts.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
# Logs the call (and stdin for --body-file -), then answers the queries the scripts make.
set -euo pipefail
echo "gh $*" >> "$FAKE_LOG"
case " $* " in
  *" --body-file - "*) sed 's/^/  | /' >> "$FAKE_LOG" ;;
esac
case "$1 $2" in
  "run list") echo "${FAKE_LAST:-}" ;;
  "issue list") echo "${FAKE_OPEN:-}" ;;
  "run view") printf '%s\n' "${FAKE_FAILED:-}" ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/gh.log" GITHUB_RUN_ID=1

# Three commits: c1 (the last green), c2, c3 (under test).
repo="$tmp/repo"
git init -q "$repo"
for n in 1 2 3; do
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "commit $n"
done
c1=$(git -C "$repo" rev-parse HEAD~2)
c3=$(git -C "$repo" rev-parse HEAD)

# From here each case's condition is a list that may fail: errexit would end the run at the
# first failing case without naming it, so each case reports through `check` instead.
set +e
failures=0
check() { # <name> <condition result: 0 ok>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     /' "$FAKE_LOG" "$tmp/out"; failures=$((failures + 1)); fi
}
run() { # <script> <args...>; output in $tmp/out, gh calls in $FAKE_LOG
  : > "$FAKE_LOG"
  (cd "$repo" && GITHUB_OUTPUT="$tmp/github-output" "$root/scripts/$1" "${@:2}") > "$tmp/out" 2>&1 \
    || echo "exit $?" >> "$tmp/out"
}
has() { grep -qF -- "$1" "$2"; }
lacks() { if grep -qE -- "$1" "$2"; then return 1; fi; }
empty() { if [ -s "$1" ]; then return 1; fi; }

# Gate.
FAKE_LAST=$c3 run nightly-gate.sh schedule "$c3"
has "run=false" "$tmp/out" && has "--event schedule" "$FAKE_LOG"; check "gate: a scheduled run skips the commit the last green scheduled run tested" $?
FAKE_LAST=$c1 run nightly-gate.sh schedule "$c3"
has "run=true" "$tmp/out"; check "gate: a scheduled run tests a new commit" $?
FAKE_LAST="" run nightly-gate.sh schedule "$c3"
has "run=true" "$tmp/out"; check "gate: a scheduled run with no green one before it runs" $?
FAKE_LAST=$c3 run nightly-gate.sh workflow_dispatch "$c3"
has "run=true" "$tmp/out" && empty "$FAKE_LOG"; check "gate: a dispatch run always runs and asks nothing" $?
FAKE_LAST=$c3 run nightly-gate.sh push "$c3"
has "run=true" "$tmp/out"; check "gate: a tag run always runs" $?

# Report.
FAKE_OPEN="" FAKE_LAST=$c1 FAKE_FAILED="- build / build (in-turn sync true)" run nightly-report.sh failure "$c3" https://example.invalid/run/1
has "gh issue create --title Nightly failing on main --label nightly-failure --label bug --label priority: before-rerun --milestone Test and CI reliability --body-file -" "$FAKE_LOG" \
  && has "gh label create nightly-failure" "$FAKE_LOG" \
  && has "  | - build / build (in-turn sync true)" "$FAKE_LOG" \
  && has "commit 3" "$FAKE_LOG" && has "commit 2" "$FAKE_LOG" && ! has "commit 1" "$FAKE_LOG"
check "report: a failure with no open issue opens one, listing the failed job and only the commits after the last green" $?
FAKE_OPEN=7 FAKE_LAST=$c1 FAKE_FAILED="- e2e / e2e-tests" run nightly-report.sh failure "$c3" https://example.invalid/run/1
has "gh issue comment 7 --body-file -" "$FAKE_LOG" && ! has "issue create" "$FAKE_LOG"; check "report: a failure with an open issue comments on it" $?
FAKE_OPEN="" FAKE_LAST="" run nightly-report.sh failure "$c3" https://example.invalid/run/1
has "No green scheduled nightly" "$FAKE_LOG" && has "commit 1" "$FAKE_LOG"; check "report: a failure with no green run before lists the recent commits" $?
FAKE_OPEN=7 run nightly-report.sh success "$c3" https://example.invalid/run/1
has "gh issue comment 7 --body Green at $c3" "$FAKE_LOG" && has "gh issue close 7" "$FAKE_LOG"; check "report: green with an open issue comments and closes it" $?
FAKE_OPEN="" run nightly-report.sh success "$c3" https://example.invalid/run/1
lacks "gh issue (create|comment|close)" "$FAKE_LOG"; check "report: green with no open issue writes nothing" $?
FAKE_OPEN=7 run nightly-report.sh other "$c3" https://example.invalid/run/1
empty "$FAKE_LOG"; check "report: a cancelled or skipped run reports nothing" $?

if [ $failures -ne 0 ]; then
  echo "test-nightly-scripts: $failures failed"
  exit 1
fi
echo "test-nightly-scripts: passed"

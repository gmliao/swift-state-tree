#!/usr/bin/env bash
# Tests scripts/nightly-gate.sh and scripts/nightly-report.sh against a stub `gh`, in a throwaway
# git repository. The stub logs every call and answers each query from a FAKE_* JSON value through
# the call's own --jq filter, so the filters run for real; the query flags are checked as exact
# lines in the log. Needs jq.
# Usage: scripts/test-nightly-scripts.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "test-nightly-scripts: needs jq" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
# Logs the call (and stdin for --body-file -), then answers a query from its FAKE_* JSON.
set -euo pipefail
echo "gh $*" >> "$FAKE_LOG"
case " $* " in
  *" --body-file - "*) sed 's/^/  | /' >> "$FAKE_LOG" ;;
esac
filter=.
prev=
for arg in "$@"; do
  if [ "$prev" = --jq ]; then filter=$arg; fi
  prev=$arg
done
case "$1 $2" in
  "run list") json=${FAKE_RUNS:-[]} ;;
  "run view") json=${FAKE_JOBS:-'{"jobs":[]}'} ;;
  "issue list") json=${FAKE_ISSUES:-[]} ;;
  "issue view") json=${FAKE_ISSUE:-'{"body":""}'} ;;
  *) exit 0 ;;
esac
printf '%s\n' "$json" | jq -r "$filter"
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/gh.log" GITHUB_RUN_ID=1

# Three commits: c1, c2, c3.
repo="$tmp/repo"
git init -q "$repo"
for n in 1 2 3; do
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "commit $n"
done
c1=$(git -C "$repo" rev-parse HEAD~2)
c2=$(git -C "$repo" rev-parse HEAD~1)
c3=$(git -C "$repo" rev-parse HEAD)
runs() { # <sha...>: a run list answer, newest first
  local out="" s
  for s in "$@"; do out="$out${out:+,}{\"headSha\":\"$s\"}"; done
  echo "[$out]"
}
url=https://example.invalid/run/1
gate_query='gh run list --workflow nightly.yml --event schedule --status success --limit 1 --json headSha --jq .[0].headSha // ""'
issue_query='gh issue list --label nightly-failure --state open --limit 1 --json number --jq .[0].number // ""'
green_query='gh run list --workflow nightly.yml --event schedule --status success --limit 20 --json headSha --jq .[].headSha'

# From here each case's condition is a list that may fail: errexit would end the run at the
# first failing case without naming it, so each case reports through `check` instead.
set +e
failures=0
check() { # <name> <condition result: 0 ok>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else
    echo "FAIL $1"; sed 's/^/     /' "$FAKE_LOG" "$tmp/out" "$tmp/github-output"; failures=$((failures + 1))
  fi
}
run() { # <script> <args...>; output in $tmp/out, gh calls in $FAKE_LOG, outputs in $tmp/github-output
  : > "$FAKE_LOG"
  : > "$tmp/github-output"
  (cd "$repo" && GITHUB_OUTPUT="$tmp/github-output" "$root/scripts/$1" "${@:2}") > "$tmp/out" 2>&1 \
    || echo "exit $?" >> "$tmp/out"
}
has() { grep -qF -- "$1" "$2"; }
line() { grep -qxF -- "$1" "$2"; }
lacks() { if grep -qE -- "$1" "$2"; then return 1; fi; }
empty() { if [ -s "$1" ]; then return 1; fi; }
exited0() { lacks '^exit ' "$tmp/out"; }
# The gate's answer as Actions reads it: only $GITHUB_OUTPUT, one line, nothing else.
output_is() { [ "$(cat "$tmp/github-output")" = "run=$1" ]; }

# Gate.
FAKE_RUNS=$(runs "$c3") run nightly-gate.sh schedule "$c3"
exited0 && output_is false && line "$gate_query" "$FAKE_LOG"
check "gate: a scheduled run skips the commit the last green scheduled run tested" $?
FAKE_RUNS=$(runs "$c1") run nightly-gate.sh schedule "$c3"
exited0 && output_is true && line "$gate_query" "$FAKE_LOG"
check "gate: a scheduled run tests a new commit" $?
FAKE_RUNS=$(runs) run nightly-gate.sh schedule "$c3"
exited0 && output_is true; check "gate: a scheduled run with no green one before it runs" $?
FAKE_RUNS=$(runs "$c3") run nightly-gate.sh workflow_dispatch "$c3"
exited0 && output_is true && empty "$FAKE_LOG"; check "gate: a dispatch run always runs and asks nothing" $?
FAKE_RUNS=$(runs "$c3") run nightly-gate.sh push "$c3"
exited0 && output_is true && empty "$FAKE_LOG"; check "gate: a tag run always runs and asks nothing" $?
run nightly-gate.sh schedule
has "exit 2" "$tmp/out" && empty "$tmp/github-output"; check "gate: a usage error exits 2 and writes no output" $?

# Report: the result from the jobs' results.
# As gh gives them: completed jobs carry a conclusion; the report job itself is still in
# progress, with an empty conclusion.
jobs_failed='{"jobs":[{"name":"gate","status":"completed","conclusion":"success"},{"name":"build / build (variants)","status":"completed","conclusion":"failure"},{"name":"e2e / e2e-game (messagepack)","status":"completed","conclusion":"cancelled"},{"name":"e2e / e2e-tests","status":"completed","conclusion":"timed_out"},{"name":"build / shellcheck","status":"completed","conclusion":"success"},{"name":"report","status":"in_progress","conclusion":""},{"name":"build / docs","status":"completed","conclusion":"skipped"}]}'
FAKE_ISSUES='[]' FAKE_RUNS=$(runs "$c1") FAKE_JOBS=$jobs_failed run nightly-report.sh success failure success "$c3" "$url"
exited0 && line "$issue_query" "$FAKE_LOG" && line "$green_query" "$FAKE_LOG" \
  && has "gh issue create --title Nightly failing on main --label nightly-failure --label bug --label priority: before-rerun --milestone Test and CI reliability --body-file -" "$FAKE_LOG" \
  && has "gh label create nightly-failure" "$FAKE_LOG" \
  && line "  | Nightly failed at $c3: $url" "$FAKE_LOG" \
  && line "  | - build / build (variants) (failure)" "$FAKE_LOG" \
  && line "  | - e2e / e2e-game (messagepack) (cancelled)" "$FAKE_LOG" \
  && line "  | - e2e / e2e-tests (timed_out)" "$FAKE_LOG" \
  && lacks "\(success\)|\(skipped\)|\(\)|report" "$FAKE_LOG" \
  && has "commit 3" "$FAKE_LOG" && has "commit 2" "$FAKE_LOG" && ! has "commit 1" "$FAKE_LOG"
check "report: a failure with no open issue opens one, listing every job that didn't pass and only the commits after the last green" $?
FAKE_ISSUES='[{"number":7}]' FAKE_RUNS=$(runs "$c1") run nightly-report.sh success success failure "$c3" "$url"
exited0 && has "gh issue comment 7 --body-file -" "$FAKE_LOG" && ! has "issue create" "$FAKE_LOG"
check "report: a failure with an open issue comments on it" $?
FAKE_ISSUES='[]' FAKE_RUNS=$(runs) FAKE_JOBS='{"jobs":[{"name":"gate","status":"completed","conclusion":"failure"}]}' run nightly-report.sh failure skipped skipped "$c3" "$url"
exited0 && has "gh issue create" "$FAKE_LOG" && line "  | - gate (failure)" "$FAKE_LOG" \
  && has "No green scheduled nightly" "$FAKE_LOG" && has "commit 1" "$FAKE_LOG"
check "report: a failed gate is a failure (opens the issue); with no green run before, it lists the recent commits" $?
FAKE_ISSUES='[]' FAKE_RUNS=$(runs "$c3" "$c1") run nightly-report.sh success failure success "$c2" "$url"
exited0 && has "last green scheduled nightly ($c1)" "$FAKE_LOG" && has "commit 2" "$FAKE_LOG" \
  && ! has "commit 3" "$FAKE_LOG" && ! has "commit 1" "$FAKE_LOG"
check "report: a rerun of an older failed run takes as baseline the newest green its commit contains" $?
FAKE_ISSUES='[{"number":7}]' FAKE_ISSUE="{\"body\":\"Nightly failed at $c2: $url\n\nFailed jobs:\"}" run nightly-report.sh success success success "$c3" "$url"
exited0 && line "$issue_query" "$FAKE_LOG" && line "gh issue view 7 --json body --jq .body" "$FAKE_LOG" \
  && has "gh issue comment 7 --body Green at $c3" "$FAKE_LOG" && has "gh issue close 7" "$FAKE_LOG"
check "report: green on a commit that contains the failing one comments on the issue and closes it" $?
FAKE_ISSUES='[{"number":7}]' FAKE_ISSUE="{\"body\":\"Nightly failed at $c3: $url\"}" run nightly-report.sh success success success "$c2" "$url"
exited0 && has "left open" "$tmp/out" && lacks "gh issue (comment|close)" "$FAKE_LOG"
check "report: a rerun of an older green run leaves a newer failure's issue open" $?
FAKE_ISSUES='[]' run nightly-report.sh success success success "$c3" "$url"
exited0 && lacks "gh issue (create|comment|close)" "$FAKE_LOG"; check "report: green with no open issue writes nothing" $?
FAKE_ISSUES='[{"number":7}]' run nightly-report.sh success cancelled success "$c3" "$url"
exited0 && empty "$FAKE_LOG"; check "report: a cancelled half reports nothing" $?
FAKE_ISSUES='[{"number":7}]' run nightly-report.sh cancelled skipped skipped "$c3" "$url"
exited0 && empty "$FAKE_LOG"; check "report: a cancelled gate reports nothing" $?
run nightly-report.sh failure "$c3" "$url"
has "exit 2" "$tmp/out" && empty "$FAKE_LOG"; check "report: a usage error exits 2 and calls nothing" $?

if [ $failures -ne 0 ]; then
  echo "test-nightly-scripts: $failures failed"
  exit 1
fi
echo "test-nightly-scripts: passed"

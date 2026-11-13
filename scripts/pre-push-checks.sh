#!/usr/bin/env bash
# CI's build-free checks, run locally before a push (to main or a PR branch), so a check that only
# CI runs can't turn main red after the push. No build, no build slot.
#
# Always (cheap, as CI runs them on every push):
#   lessons     scripts/lint-lessons.sh --self-test, then the repository (CI: build › Lint lessons)
#   wall-clock  scripts/lint-wall-clock-tests.sh --self-test, then with the base's baseline
#               (CI: wall-clock-tests)
#   ShellCheck  every tracked script, plus new untracked ones, outside CI's exclusion; an excluded
#               script with no findings fails (CI: shellcheck). The exclusion is read from the
#               workflow, so it can't drift. Needs ShellCheck 0.11.0, the version CI pins.
# When the change reaches them (files changed since the merge base with <base>, committed or not):
#   deep-research  deep-research/** changed: deep-research/run-tests.sh (every test file, Linux-gated
#               classes forced off Linux)
#   serverenv   Sources/** or Examples/** changed (and deep-research didn't): deep-research/
#               test_serverenv.py, which fails on a server env key missing from serverenv.py (#513)
# Not covered (the build-slot verification and the push's own CI): swift build and test, E2E,
# generated schemas and codegen, the TypeScript SDK and ws-loadtest tests.
#
# Usage: scripts/pre-push-checks.sh [base]   (default origin/main; run `git fetch` first)
# Tests: scripts/test-pre-push-checks.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
base="${1:-origin/main}"
workflow=.github/workflows/build-and-test.yml
failed=()

fork="$(git merge-base "$base" HEAD 2>/dev/null)" || { echo "pre-push-checks: no merge base with $base" >&2; exit 2; }
changed="$( { git diff --name-only "$fork"; git ls-files --others --exclude-standard; } | sort -u)"
touches() { grep -qE "$1" <<<"$changed"; }

run() {  # name, command...
  local name=$1 log rc=0
  shift
  log="$(mktemp)"
  "$@" > "$log" 2>&1 || rc=$?
  if [ $rc -eq 0 ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name (exit $rc)"
    tail -25 "$log" | sed 's/^/      /'
    failed+=("$name")
  fi
  rm -f "$log"
}

lessons() { scripts/lint-lessons.sh --self-test && scripts/lint-lessons.sh; }

wall_clock() {
  local baseline rc=0
  baseline="$(mktemp)"
  git show "$fork:scripts/wall-clock-baseline.txt" > "$baseline" 2>/dev/null || : > "$baseline"
  { scripts/lint-wall-clock-tests.sh --self-test && scripts/lint-wall-clock-tests.sh --base-baseline "$baseline"; } || rc=$?
  rm -f "$baseline"
  return $rc
}

shell_check() {
  local excluded version f
  version="$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p')"
  if [ "$version" != 0.11.0 ]; then
    echo "ShellCheck ${version:-not found}, CI pins 0.11.0: install that version"
    return 1
  fi
  excluded="$(sed -n "s/^ *excluded='\(.*\)'$/\1/p" "$workflow")"
  if [ -z "$excluded" ]; then
    echo "no excluded='...' line in $workflow: update pre-push-checks.sh with the CI step"
    return 1
  fi
  local files=() held=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z --cached --others --exclude-standard '*.sh' '*.bash' | grep -zvE "$excluded")
  while IFS= read -r -d '' f; do held+=("$f"); done < <(git ls-files -z '*.sh' '*.bash' | grep -zE "$excluded")
  [ "${#files[@]}" -gt 0 ] || { echo "no shell scripts found"; return 1; }
  shellcheck "${files[@]}" || return 1
  for f in "${held[@]}"; do
    if shellcheck "$f" > /dev/null; then
      echo "$f has no findings now: remove it from the exclusion in $workflow (CI fails otherwise)"
      return 1
    fi
  done
}

echo "pre-push-checks: base $base (merge base ${fork:0:12}), $(grep -c . <<<"$changed") changed file(s)"
run lessons lessons
run wall-clock wall_clock
run shellcheck shell_check
if touches '^deep-research/'; then
  run deep-research bash deep-research/run-tests.sh
elif touches '^(Sources|Examples)/'; then
  run serverenv bash -c 'cd deep-research && python3 test_serverenv.py'
else
  echo "skip  deep-research, serverenv (nothing they cover changed)"
fi
echo "not covered: swift build/test, E2E, generated schemas/codegen, TypeScript SDK and ws-loadtest tests (build-slot verification and CI)"
if [ ${#failed[@]} -ne 0 ]; then
  echo "pre-push-checks: FAILED: ${failed[*]}"
  exit 1
fi
echo "pre-push-checks: passed"

#!/usr/bin/env bash
# CI's build-free checks, run locally before a push (to main or a PR branch), so a check that only
# CI runs can't turn main red after the push. No build, no build slot.
#
# Always (cheap, as CI runs them on every push):
#   lessons     scripts/lint-lessons.sh --self-test, then the repository (CI: build › Lint lessons)
#   solutions-index  scripts/solutions-index.py --self-test, then --check: Notes/solutions/README.md's
#               index is what the entries' front matter generates (CI: build › Check the solutions index)
#   wall-clock  scripts/lint-wall-clock-tests.sh --self-test, then with the base's baseline
#               (CI: wall-clock-tests)
#   turns       scripts/lint-turns.sh --self-test, then the repository (CI: build › Lint turns)
#   gate-close  scripts/gate-close-census.sh --self-test, then Sources (CI: build › Gate-close census)
#   turns-doc-blocks  scripts/check-turns-doc-blocks.py --self-test, then the repository: every
#               Swift block of the Turns docs appears in a tested file, the comparison
#               SwiftStateTurnsTests makes after a build (CI: build › swift test)
#   plan-index  scripts/check-plan-index.sh --self-test, then Notes/plans/README.md: one row per plan
#               and no conflict marker, after a union merge (CI: the Plan index workflow)
#   image-pin   scripts/check-ci-image-pin.sh --self-test, then the repository: one Swift image
#               digest in the workflows and the Dockerfiles, named by every SwiftPM cache key
#               (CI: the Image pin workflow)
#   variant-selection  scripts/check-variant-test-selection.sh --self-test, then the repository: the
#               build job's variant runs read nothing the left-out tests could (a TransportAdapter
#               built without transportEnvConfig outside the filtered targets, R1, and the rest of
#               R1-R3 and E1-E5). Python, plus `swift package dump-package` for the test targets'
#               dependencies: that compiles Package.swift with swiftc (a few seconds), builds no
#               target and needs no build slot; fails, not skips, when `swift` is missing
#               (CI: build › The variant runs left out can't read their variable)
#   text-encoding  scripts/lint-text-encoding.py --self-test, then deep-research/ and scripts/:
#               Python text I/O without encoding= (a non-UTF-8 locale, such as cp950 on Windows,
#               breaks it). Not in CI yet.
#   classify    scripts/classify-golden-changes.py --self-test: the golden-change classes, the
#               recordPayload class for #700 K1a included, on fixtures. Not in CI yet.
#   ShellCheck  every tracked script, plus new untracked ones, outside CI's exclusion; an excluded
#               script with no findings fails (CI: shellcheck). The exclusion is read from the
#               workflow, so it can't drift. Needs ShellCheck 0.11.0, the version CI pins. Skipped
#               when no .sh/.bash file and not the workflow changed: CI's result can't differ from
#               the base's then, so a host without ShellCheck can push other changes.
# When the change reaches them (files changed since the merge base with <base>, committed or not):
#   deep-research  deep-research/** changed: deep-research/run-tests.sh (every test file, Linux-gated
#               classes forced off Linux)
#   readers     deep-research didn't change: each deep-research test that reads files outside
#               deep-research/ runs when one of the paths it reads changed (the table below): the
#               server env list against Sources (#513), the pipefail-reader check against every
#               tracked shell script, the sync-lag defaults against Sources and ws-loadtest, the
#               state-shape fixtures, and the ignore rules the record paths rely on
# Not covered (the build-slot verification and the push's own CI): swift build and test (with
# them the plain-data lint, a test), E2E, generated schemas and codegen, the TypeScript SDK and
# ws-loadtest tests.
#
# Usage: scripts/pre-push-checks.sh [base]   (default origin/main; run `git fetch` first)
# Tests: scripts/test-pre-push-checks.sh
set -uo pipefail
# git exports GIT_DIR to a hook run from a linked worktree. Drop git's repository variables, so
# neither these commands nor a test's own `git init` or `git commit` in a temporary directory
# reach that repository (a deep-research test once set core.bare on the clone that way).
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
# Python's own text I/O in UTF-8 whatever the host's locale (belt and braces: the lint below keeps
# deep-research/ and scripts/ explicit).
export PYTHONUTF8=1
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

solutions_index() { python3 scripts/solutions-index.py --self-test && python3 scripts/solutions-index.py --check; }

wall_clock() {
  local baseline rc=0
  baseline="$(mktemp)"
  git show "$fork:scripts/wall-clock-baseline.txt" > "$baseline" 2>/dev/null || : > "$baseline"
  { scripts/lint-wall-clock-tests.sh --self-test && scripts/lint-wall-clock-tests.sh --base-baseline "$baseline"; } || rc=$?
  rm -f "$baseline"
  return $rc
}

# The check reads the package manifest with `swift package dump-package`: without Swift it can't
# tell which test targets reach the transport, so the topic fails with that, as the ShellCheck
# topic does without its pinned version, instead of passing on nothing.
variant_selection() {
  if ! swift --version > /dev/null 2>&1; then
    echo "swift not found on PATH: check-variant-test-selection.sh reads the package manifest with \`swift package dump-package\` (CI runs it after \`swift --version\`)"
    return 1
  fi
  scripts/check-variant-test-selection.sh --self-test && scripts/check-variant-test-selection.sh
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
run solutions-index solutions_index
run wall-clock wall_clock
run turns bash -c 'scripts/lint-turns.sh --self-test && scripts/lint-turns.sh'
run gate-close bash -c 'scripts/gate-close-census.sh --self-test && scripts/gate-close-census.sh'
run turns-doc-blocks bash -c 'python3 scripts/check-turns-doc-blocks.py --self-test && python3 scripts/check-turns-doc-blocks.py'
run plan-index bash -c 'scripts/check-plan-index.sh --self-test && scripts/check-plan-index.sh'
run image-pin bash -c 'scripts/check-ci-image-pin.sh --self-test && scripts/check-ci-image-pin.sh'
run variant-selection variant_selection
run text-encoding bash -c 'python3 scripts/lint-text-encoding.py --self-test && python3 scripts/lint-text-encoding.py'
run classify python3 scripts/classify-golden-changes.py --self-test
if touches '\.(sh|bash)$' || touches "^${workflow//./\\.}$"; then
  run shellcheck shell_check
else
  echo "skip  shellcheck (no shell file changed)"
fi
# The deep-research tests that read files outside deep-research/, one row per reader: a label, the
# paths it reads (grep -E on the changed paths), the test file, and a unittest selector (empty: the
# whole file). A trigger must cover every path its test reads: a test that starts reading another
# path outside deep-research/ adds it here, or a change there skips the test until CI runs it.
# Fields are separated by tabs.
readers="$(cat <<'EOF'
serverenv	^Sources/	deep-research/test_serverenv.py	
pipefail-readers	\.(sh|bash)$	deep-research/test_pipefail_readers.py	
sync-lag-defaults	^Sources/SwiftStateTreeTransport/(SyncLag|TransportEnvKeys)\.swift$|^Examples/GameDemo/ws-loadtest/src/worker\.ts$	deep-research/network-impairment-2026-11/test_topic.py	SyncLagDefaults
stateshape-fixtures	^Examples/GameDemo/ws-loadtest/tests/fixtures/	deep-research/entity-delta-baseline/test_stateshape.py	
runmeta-ignored	(^|/)\.gitignore$	deep-research/test_runmeta_dirty.py	
multiroom-ignored	(^|/)\.gitignore$	deep-research/multiroom-load-2026-11/test_topic.py	Plan.test_outputs_stay_under_the_topics_ignored_raw
EOF
)"
reader() (  # test file, [selector]: from its own directory, as run-tests.sh runs it (a subshell, so
            # the cd doesn't leak into the next row)
  cd "$(dirname "$1")" && SST_FORCE_LINUX_TESTS=1 python3 "$(basename "$1")" ${2:+"$2"}
)
if touches '^deep-research/'; then
  run deep-research bash deep-research/run-tests.sh
else
  ran_reader=0
  while IFS=$'\t' read -r label trigger file selector; do
    if touches "$trigger"; then
      run "$label" reader "$file" "$selector"
      ran_reader=1
    fi
  done <<<"$readers"
  [ $ran_reader -eq 1 ] || echo "skip  deep-research and its readers (nothing they read changed)"
fi
echo "not covered: swift build/test (incl. the plain-data lint test), E2E, generated schemas/codegen, TypeScript SDK and ws-loadtest tests (build-slot verification and CI)"
if [ ${#failed[@]} -ne 0 ]; then
  echo "pre-push-checks: FAILED: ${failed[*]}"
  exit 1
fi
echo "pre-push-checks: passed"

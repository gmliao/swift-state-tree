#!/usr/bin/env bash
# Runs every deep-research Python test file as CI's "deep-research Python tests" step does: each
# file from its own directory, failing on a non-zero exit or on output with no "Ran N tests".
# Off Linux it sets SST_FORCE_LINUX_TESTS=1, so the Linux-gated classes (the topics' fakes) run
# too rather than skip: a change their code reaches must run them before it is pushed.
# Usage: bash deep-research/run-tests.sh   (from anywhere in the checkout)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
case "$(uname -s)" in
  Linux) ;;
  *) export SST_FORCE_LINUX_TESTS=1; echo "Not Linux: SST_FORCE_LINUX_TESTS=1 (Linux-gated test classes run anyway)" ;;
esac
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
count=0
failed=()
while IFS= read -r -d '' f; do
  count=$((count + 1))
  rc=0
  (cd "$(dirname "$f")" && python3 "$(basename "$f")") > "$log" 2>&1 || rc=$?
  ran="$(grep -E '^Ran [0-9]+ tests? in ' "$log" | tail -1)"
  skipped="$(grep -oE 'skipped=[0-9]+' "$log" | tail -1)"
  if [ $rc -ne 0 ]; then
    echo "FAIL $f (exit $rc)"; tail -20 "$log"; failed+=("$f")
  elif [ -z "$ran" ] || [[ "$ran" == "Ran 0 tests"* ]]; then
    echo "FAIL $f: no tests run"; failed+=("$f")
  else
    echo "ok   $f: ${ran% in *}${skipped:+ ($skipped)}"
  fi
# Tracked and untracked (not ignored) files: a new test file runs before it is added.
done < <(git ls-files -z --cached --others --exclude-standard 'deep-research/*test_*.py' 'deep-research/**/test_*.py')
echo "$count test files, ${#failed[@]} failed"
[ ${#failed[@]} -eq 0 ]

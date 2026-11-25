---
title: "A test harness under errexit dies without naming the failing case"
module: scripts
date: 2026-11-19
problem_type: gotcha
component: shell-test-harness
symptoms:
  - "a shell test harness exits 1 with no FAIL line and no summary"
  - "a mutant of the script under test is caught, but the harness names no case"
  - "cond1 && cond2; check \"name\" $? never reaches check"
root_cause: errexit_applies_to_the_last_command_of_an_and_list
resolution_type: design_rule
severity: low
tags:
  - shell
  - errexit
  - set-e
  - test-harness
  - mutation
related:
  - "Notes/solutions/2026-11-08-early-exit-reader-under-pipefail.md"
---

**Problem.** `scripts/test-nightly-scripts.sh` checks each case as `has A "$out" && has B "$log"; check "<name>" $?`, under `set -euo pipefail`. A mutant of `nightly-gate.sh` (dropping `--event schedule`) made the harness exit 1 at once. It printed no `FAIL` line, no later cases and no summary. A second mutant, whose case ended in a `!` negation, was reported normally.

**Root cause.** `set -e` doesn't apply to the commands of an `&&` list, except the last one. When that last command fails, the shell exits before `check` runs. A list ending in `! cmd` is exempt, because a negated command never triggers errexit. So a case "fails" by killing the run, and which case it was is lost.

**Fix.** The harness keeps `set -euo pipefail` for its setup, then turns errexit off (`set +e`) before the cases. Each case reports through `check`. `run` also records a script's non-zero exit in the output instead of ending the harness.

**Prevention.**
- **A harness whose cases are `cond; check name $?` runs those cases without errexit.** Keep `set -e` for the setup, where stopping is right.
- **Mutation-check a new harness case by case:** each mutant must make the harness name the case that catches it, not just exit non-zero. An exit code alone hides both this trap and a case that catches nothing.
- **Use helpers rather than a bare `!`:** `lacks pattern file` and `empty file` (functions that return 1) state a negative condition without the `!` exemption that ShellCheck's SC2251 flags.

---
module: scripts
date: 2026-11-19
problem_type: gotcha
component: pre-push-checks
symptoms:
  - "pre-push-checks: passed, then CI's examples job fails in deep-research/test_pipefail_readers.py"
  - "skip  deep-research, serverenv (nothing they cover changed) on a change to a shell script"
  - "a deep-research test fails on CI for a change outside deep-research/"
root_cause: a_checker_triggered_by_its_own_directory_reads_files_outside_it
resolution_type: design_rule
severity: medium
tags:
  - pre-push
  - ci
  - deep-research
  - shell
  - pipefail
related:
  - "#608"
---

**Problem.** #608 changed `scripts/check-must-not-compile.sh`. Line 106 pipes into `grep -q` under `pipefail`, the class `deep-research/test_pipefail_readers.py` refuses. `scripts/pre-push-checks.sh` passed, and the failure showed up only in CI's `examples` job, on two pushes (runs 44305963192, 44419378907):

```
'scripts/check-must-not-compile.sh:106: grep -q: elif ! grep -F -- "$expected" <<<"$errors" | grep -q -E "/$name:|^macro expansion @"; then'
```

**Root cause.** Pre-push ran the deep-research tests only when `deep-research/**` changed, and `test_serverenv.py` alone when `Sources/` or `Examples/` changed. The trigger was the directory the tests live in, not the files they read. Several of them read outside it:

- `test_pipefail_readers.py`: every tracked `*.sh` / `*.bash`, anywhere;
- network-impairment's `SyncLagDefaults`: `Sources/SwiftStateTreeTransport/SyncLag.swift`, `TransportEnvKeys.swift` and `Examples/GameDemo/ws-loadtest/src/worker.ts`;
- `entity-delta-baseline/test_stateshape.py`: `Examples/GameDemo/ws-loadtest/tests/fixtures/`;
- `test_runmeta_dirty.py` and multiroom's ignored-output test: the `.gitignore` rules, through `git check-ignore`.

A change to any of those paths skipped the test that reads them, so CI was the first to run it.

**Fix.**
- `pre-push-checks.sh` keeps a table of these readers: a label, the paths each one reads (`grep -E` on the changed paths), the test file, and a unittest selector.
- When `deep-research/` didn't change, each row runs if its paths changed: the file, or only the class or test that reads outside.
- The full suite takes about 4 minutes on the Mac. The selectors keep a `Sources/` change to the few seconds of the readers it reaches: network-impairment's file alone takes 132 s, its `SyncLagDefaults` class milliseconds.
- `scripts/test-pre-push-checks.sh` pins three of the rows:
  - a new tracked script with `yes | head -1` under `pipefail` fails `pipefail-readers`;
  - a changed sync-lag default fails `sync-lag-defaults`;
  - a `.gitignore` change runs the ignore readers.

**Prevention.**
- **A checker's trigger covers every path the checker reads,** not the directory it lives in. A test that starts reading a new path outside its directory adds that path to its trigger in the same change.
- **To find what a test reads,** look for the repository root it builds paths from (`REPO`, `ROOT`, `TOPIC.parent.parent`, `HERE.parent`) and for `git ls-files` or `git check-ignore` run in the real checkout, not in a temporary repository.
- **A checker that reads tracked files only** (`git ls-files`) needs the probe in its own test to be added to the index, as a push would carry it. An untracked probe passes and proves nothing.

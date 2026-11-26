---
title: "A script that reads stdin only in hook mode must not infer hook mode from ! -t 0"
module: scripts
date: 2026-11-26
problem_type: gotcha
component: pre-push-checks
symptoms:
  - "scripts/pre-push-checks.sh run from a command line with a piped stdin prints nothing and never ends"
  - "`sleep 30 | timeout 10 bash scripts/pre-push-checks.sh origin/main` exits 124"
root_cause: not_a_tty_is_not_hook_mode
resolution_type: code_fix
severity: medium
tags:
  - bash
  - stdin
  - git-hook
  - pre-push
  - hang
related:
  - "#856"
  - "#921"
---

## Problem

`scripts/pre-push-checks.sh` reads the pre-push hook's ref lines from stdin so it can check the pushed commits (#856). It took "stdin is not a terminal" (`[ ! -t 0 ]`) to mean "run as a hook". Many command-line callers have a stdin that is not a terminal and never ends: `ssh host cmd`, a background job with a pipe, an agent run without `< /dev/null`. The read loop waited for an end of input that never came, so a command that used to run the checks hung with no output.

## Root cause

`! -t 0` says what stdin is not, not who wrote it. A hook's stdin and an idle pipe look the same until a read is attempted, and a read has no end on a pipe whose writer stays open.

## Fix

Git writes every ref line before it starts the hook, so the first line is there at once. The first `read` is bounded (`read -r -t 5`): no line within the bound means command-line use, and the checkout is checked as before. Later reads have no bound, because a line has arrived and the rest follow. A self-test case keeps stdin open as a pipe for the whole run and expects the run to finish and check the checkout; on the version without the bound it ends at `timeout` with exit 124.

## Prevention

- A script that reads stdin only in some mode takes the mode from something it was told (an argument, a variable the hook sets), or bounds its first read. It never infers the mode from `! -t 0`.
- Test the other mode too: a self-test case whose stdin is a pipe that stays open until the run ends (a holder that exits when a file appears, so the case leaves no orphan process).
- A flag passed by `.git/hooks/pre-push` would work but sits in each clone's untracked hook file; every clone would need an update.

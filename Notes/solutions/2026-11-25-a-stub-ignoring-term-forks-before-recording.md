---
module: CI
date: 2026-11-25
problem_type: bug_class
component: ci-apt-install
symptoms:
  - "a stub plan that should produce four log entries produces only three"
  - "an ok dpkg stub appears as Killed in ci-apt-install output"
  - "every-attempt-hangs passes but the call log is short on a loaded runner"
root_cause: stub_forks_external_commands_before_writing_its_log_entry
resolution_type: code_fix
severity: medium
tags:
  - ci
  - apt
  - stub
  - shell
  - signal
  - builtins
  - flaky
related:
  - "#821"
  - "#659"
  - "#665"
---

# A stub ignoring TERM forks before it records and can be killed before the record

## Problem

[`scripts/test-ci-apt-install.sh`](../../scripts/test-ci-apt-install.sh) stubs `apt-get` and `dpkg`
to follow a plan. The stubs ignore TERM from their first line so that a `stubborn` stub can't be
ended by a TERM that arrives while it is reading its plan. With `CI_APT_DPKG_TIMEOUT=1
CI_APT_KILL_AFTER=1`, only the KILL at 2 s ends a stub.

The stub ran four external commands before it wrote its log line: `basename` (to get the tool name),
`ps … | tr` (to record its process group), `cat` (to read the call counter) and `sed` (to read the
plan word). On a loaded CI runner those forks took more than 2 s, so KILL ended an `ok` or `fail`
stub before `echo "$tool $*" >> log` ran. The log had fewer entries than expected.

The failing run (#821) showed this in `every-attempt-hangs`: its dpkg plan is `ok ok ok ok`, so
none of its dpkg stubs should hang. The output showed `Killed timeout … dpkg --configure -a` and
`exit 137; installing anyway`, meaning an `ok` dpkg stub was killed before recording.

## Root cause

The stub's first observable action after `trap '' TERM` was to `fork + exec` external tools. With
a 2 s bound and a loaded runner, those forks exceeded the bound before the log write. KILL ended
the stub before `echo` ran.

## Fix

PR #821 rewrites the stub to use **builtins only** until the plan word is known, and to **write the
log entry first**:

```bash
trap '' TERM
tool=${0##*/}                              # ${0##*/} is a builtin parameter expansion
echo "$tool $*" >> "$APT_STUB_DIR/log"    # record first, before any fork
read -r n < "$APT_STUB_DIR/$tool.calls"   # read builtin
n=$((n + 1))                              # arithmetic expansion
echo "$n" > "$APT_STUB_DIR/$tool.calls"
word= i=0
while IFS= read -r line; do              # read builtin loop — no sed or cat
  i=$((i + 1))
  if [ "$i" -eq "$n" ]; then word=$line; break; fi
done < "$APT_STUB_DIR/$tool.plan"
case "$word" in
  ok) exit 0 ;;
  hang) ps -o pgid= $$ | tr -d ' ' >> "$APT_STUB_GROUPS"; trap - TERM; exec sleep 600 ;;
  stubborn) ps -o pgid= $$ | tr -d ' ' >> "$APT_STUB_GROUPS"; while :; do sleep 1; done ;;
  *) exit 100 ;;
esac
```

The group record moves to `hang` and `stubborn` only. Those are the only stubs that outlive their
bound; an `ok` or `fail` stub exits at once and leaves no group behind. If `ps` is slow in a `hang`
stub, KILL ends the whole group — `ps` included — before the record. Nothing is left to clean up.

The test adds a `slow-forks` case that puts a shim directory ahead of the stubs on `PATH`. Each
shim for `basename`, `ps`, `tr`, `cat` and `sed` runs `sleep 3` and then `exec`s the real tool.
With the old stub every stub is killed before recording; with the fixed stub the `ok` and `fail`
paths never fork those tools.

## Prevention

- **Record first, with builtins.** A test stub that ignores TERM must write any observable state
  (log entries, counters) before it forks any external command. Use shell parameter expansion
  (`${0##*/}`), arithmetic (`$((n + 1))`), and the `read` builtin in place of `basename`, `cat`
  and `sed`.
- **Group recording belongs on the wait paths only.** An `ok` or `fail` stub exits in
  microseconds; recording its process group is unnecessary overhead and a window for a kill race.
  Record the group only when the stub will outlive its bound (`hang`, `stubborn`).
- **Pin the failing case with a shim.** To expose the race deterministically in a test, put a shim
  directory ahead of the stubs on `PATH`. Each shim sleeps past the bound, then `exec`s the real
  tool. The case fails with the old stub and passes with the fixed one.

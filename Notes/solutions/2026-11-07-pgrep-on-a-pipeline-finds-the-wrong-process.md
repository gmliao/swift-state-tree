---
module: manual checks, process control
date: 2026-11-07
problem_type: test_methodology
component: shell (pgrep, pipelines, background jobs)
symptoms:
  - "A server started as `server | head -c1 &` keeps answering after the script killed it"
  - "A control run against the old build answers /health although the old build crashed"
  - "`kill -0 $PID` says alive for a process that died"
root_cause: pid_of_a_subshell_or_pipeline_taken_for_the_server
resolution_type: procedure
severity: medium
tags:
  - methodology
  - shell
  - manual-check
  - process-control
related:
  - "https://github.com/gmliao/swift-state-tree/pull/283"
---

# `pgrep` on a pipeline finds the wrong process

## Problem
A manual check ran a server with its output in a pipe, `( .build/debug/GameServer 2>&1 | head -c1 >/dev/null ) &`, took its PID with `pgrep -f "debug/GameServer" | head -1`, polled `/health`, then killed that PID. The PID was the subshell's: its command line also contains `debug/GameServer`, and it is older, so `head -1` picked it. The real server kept running and kept port 8080. The control run that followed, against a build with the bug, then got its `/health` answers from the server left over from the first run, while the control server itself had already crashed. Both results were wrong in the same direction: "alive".

## Root cause
- `pgrep -f` matches the full command line of every process. A subshell, a `bash -c "..."` wrapper or a script that runs the server has the server's path in its command line too.
- `$!` after `cmd | other &` is the PID of the pipeline's last command (`head`), not the server's.
- `kill -0` on a subshell that waits for its pipeline says "alive" as long as any part of the pipeline runs. It doesn't say the server is alive.
- `/health` answers come from whatever listens on the port, not necessarily from the process under test.

## Resolution
- Take the server's PID by anchoring on the binary path: `pgrep -nf "^$BIN"` (`^` matches only a process whose command line starts with the binary). Check that exactly one process matches.
- Before each run, check that the port is free (`lsof -nP -iTCP:<port> -sTCP:LISTEN`), and fail the run if it isn't. After each run, check that it's free again.
- Read the server's exit status where it matters: `bash -c "$BIN 2>&1 | head -c1 >/dev/null; echo \${PIPESTATUS[0]}"`. 141 is 128 + SIGPIPE.
- Always run a control against the build without the change, and compare the two. A check that passes on both builds tests nothing.

## Prevention
For a manual check of a long-running process, write a small script that refuses a busy port, takes the PID by `^<binary>`, polls, kills that PID and checks the port afterwards. Run it on the change and on a control build, and report both.

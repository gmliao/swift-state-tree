---
module: tests (exit tests), process signals
date: 2026-11-07
problem_type: test_methodology
component: Swift Testing exit tests, SIGPIPE on Darwin
symptoms:
  - "An exit test expecting .signal(SIGPIPE) intermittently reports .exitCode(n) on macOS"
  - "The write returns EPIPE, the disposition is SIG_DFL, and the process still isn't killed"
  - "Linux never shows it"
root_cause: process_directed_signal_delivered_after_the_writer_exits
resolution_type: test_fix
severity: medium
tags:
  - testing
  - signals
  - darwin
  - exit-test
  - flaky
related:
  - "https://github.com/gmliao/swift-state-tree/issues/291"
  - "https://github.com/gmliao/swift-state-tree/pull/295"
---

# A Darwin pipe write's SIGPIPE is process-directed: the writer can exit before it lands

## Problem

The negative control "without the helper, a write to a closed pipe ends the process with SIGPIPE" failed in 9 of 15 macOS runs with `.exitCode(2)`: the child wrote to a pipe whose read end was closed, got `EPIPE`, and reached its `exit(2)`.

## Root cause

Ruled out with probes in the failing child (state encoded into the exit code): the descriptor had no `F_NOSIGPIPE`; SIGPIPE wasn't blocked on the writing thread (`pthread_sigmask`), wasn't pending after the write (`sigpending`), and the disposition was `SIG_DFL` before and after. The body ran on a worker thread, not the main thread.

What fits (inferred, not observed directly): for an `EPIPE` from a non-socket descriptor, XNU's `dofilewrite` calls `psignal` on the *process*, not on the writing thread. The signal is generated during the write, but its fatal delivery can land later, on another thread, and the writer can reach `exit` first. Linux signals the writing thread inside `pipe_write`, so the process dies at the write.

Three hypotheses (descriptor flag, process mask, per-thread mask) were each plausible and each wrong; only probing the failing child settled it.

## Fix

The child checks that the write returned `EPIPE`, then waits, bounded (10 s), for the signal before `exit(2)`. The assertion stays `.signal(SIGPIPE)`. The wait is a watchdog: the signal ends it, and the test still takes about 0.2 s. Before: 6 of 15 runs passed; after: 15 of 15; a mutant that ignores SIGPIPE in the child still fails.

## Prevention

- An exit test that expects a signal must not let the raising code fall through to `exit` straight away; follow the raising call with a bounded wait for the signal, and check the call's own result (here `EPIPE`) before waiting.
- Don't assume a synchronous-looking signal (SIGPIPE, and others raised for a file operation) is delivered on the calling thread, or before the call returns, on every platform.
- To diagnose a child process that exits wrongly, encode its state (flags, masks, dispositions, thread) into the exit code; that settles in one run what reasoning can't.

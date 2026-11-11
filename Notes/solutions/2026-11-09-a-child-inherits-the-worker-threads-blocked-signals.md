---
module: SwiftStateTree
date: 2026-11-09
problem_type: gotcha
component: process-signals
symptoms:
  - "a child process started from async code ignores SIGTERM on Linux"
  - "`kill -TERM $$` in a spawned shell doesn't end it; the shell exits normally"
  - "a signal test passes on macOS and fails on Linux CI"
root_cause: concurrency_worker_threads_block_async_signals_and_children_inherit_the_mask
resolution_type: code_fix
severity: medium
tags:
  - signals
  - linux
  - cross-platform
  - process
  - testing
related:
  - "#351"
  - "#372"
---

## Problem

The #351 exit test "a child process started with exec gets the default SIGTERM action back" passed on macOS and failed on Linux CI. In the test, the child installs the shutdown-signal handler, starts `/bin/sh -c 'kill -TERM $$; exit 7'` with Foundation's `Process`, and expects the shell to die of SIGTERM. On Linux the shell exited normally.

## Root cause

The test's body runs in async code, on a Swift concurrency worker thread (libdispatch). Those threads block asynchronous signals, so that signals are delivered to a thread that isn't blocking them. A process started with `fork`/`posix_spawn` **inherits its spawner's signal mask**, and exec keeps it. The shell therefore started with SIGTERM blocked: `kill -TERM $$` left the signal pending, and the shell ran on to `exit 7`.

Darwin's `Process` clears the signal mask when it spawns, so macOS passed. swift-corelibs-foundation's `Process` on Linux doesn't, so the child kept the worker thread's mask. A plain `posix_spawn` with default attributes fails the same way on both platforms. The handler wasn't the cause: exec resets a caught signal to its default action, as it should.

Measured on `swift:6.2.4-noble`: a detached `Task` reads SIGTERM as blocked in its thread's mask. A spawn from a thread with SIGTERM blocked gives a shell that exits 7. The same spawn with an empty mask gives a shell killed by SIGTERM.

## Fix

The test spawns with `posix_spawn` and waits with `waitpid` directly. It sets `POSIX_SPAWN_SETSIGMASK` with an empty set, so the child starts with no signals blocked. It deliberately leaves `POSIX_SPAWN_SETSIGDEF` unset, because the default action must come from exec itself, which is what the test checks. Each failure exits with a distinct code (spawn, wait, exited *n*, another signal), so a CI failure says which one happened.

## Prevention

- **A child started from async code gets the worker thread's blocked signals,** on Linux even through Foundation's `Process`. When a child must receive signals (a supervisor test, a helper that is sent SIGTERM), spawn it with `POSIX_SPAWN_SETSIGMASK` and an empty mask.
- **Signal tests that pass on macOS prove nothing about Linux:** the two `Process` implementations differ in what they reset. Run them on the pinned Linux image before relying on them.
- **Pin it with a mutant:** setting the signal to `SIG_IGN` in the child before the spawn must fail the test. It does: exit 27, the shell exiting 7.

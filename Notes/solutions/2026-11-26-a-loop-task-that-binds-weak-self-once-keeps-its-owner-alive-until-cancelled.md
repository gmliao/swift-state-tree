---
title: "A loop Task that binds its weak self once keeps its owner alive, and the owner's deinit can't cancel it"
module: SwiftStateTree
date: 2026-11-26
problem_type: bug_class
component: land-keeper
symptoms:
  - "re-evaluation spool files (sst-record-*.sstr) pile up in the temporary directory"
  - "a keeper dropped without a shutdown is never deinitialized"
  - "a weak reference to a keeper's recorder stays non-nil after the keeper goes out of scope"
root_cause: strong_binding_of_weak_self_across_a_loop
resolution_type: code_fix
severity: medium
tags:
  - retain-cycle
  - task
  - weak-self
  - deinit
  - recorder
related:
  - "#910"
  - "#346"
---

# A loop Task that binds its weak self once keeps its owner alive, and the owner's deinit can't cancel it

## Problem

The keeper's tick and sync loops started as `Task { [weak self] in … guard let self = self else { return }; while !Task.isCancelled { sleep; await self.work() } }`. A keeper with a started loop that was dropped without `forceShutdown` was never deinitialized. Its re-evaluation recorder was never released either, so the recorder's deinit, which deletes an unsaved spool file, never ran. A developer Mac collected about 30,000 spool files from test runs (#910).

## Root cause

The `[weak self]` capture is weak, but `guard let self` at the closure's top scope binds a strong reference for the rest of the closure: the whole loop, sleeps included. The loop ends only when the task is cancelled, and the keeper cancels it in its `deinit` or in the drain. The `deinit` can't run while the loop holds the keeper, so only the drain ends the loop.

The first fix moved the guard into the loop body but kept one `guard let first = self` before the loop for its first call. That binding has the same top-level scope and held the keeper again. The test still failed on the tick loop; the sync loop, which had no such call, passed.

## Fix

Take the strong reference inside each iteration, after the sleep: `guard let keeper = self else { return }` in the `while` body, so it is released at the end of every iteration. A call before the loop uses `if let keeper = self { … } else { return }`, whose binding ends with its braces. `RecorderReleaseTests` drops a keeper with a 10 ms tick loop and one with a 10 ms sync loop, and checks that the recorder goes and its spool file is deleted.

The adapter's strong link to its keeper is a different case and stays (#346): the drain breaks it, as the test's adapter row pins.

## Rule

In a long-lived `Task` that captures its owner weakly, bind the owner strongly only inside the work of one iteration, never at the closure's top scope (`guard let self`, or a `guard let` before the loop). Check that the owner's `deinit` can run while the task sleeps: if the task holds the owner across an await, the `deinit`'s cancel is dead code.

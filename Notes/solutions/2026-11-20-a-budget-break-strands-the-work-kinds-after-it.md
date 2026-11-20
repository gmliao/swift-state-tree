---
module: SwiftStateTurns
date: 2026-11-20
problem_type: bug_class
component: turn-driver
symptoms:
  - "a due follow-up doesn't step in its job when the same segment releases many parked inputs"
  - "work queued behind a capped release waits for a later, unrelated job"
  - "a test passes with a large maxReleasesPerBatch and fails with a cap of 1 or 2"
root_cause: a_loop_that_breaks_at_one_kinds_budget_skips_every_kind_placed_after_it
resolution_type: design_rule
severity: medium
tags:
  - turns
  - driver
  - budget
  - drain-loop
  - follow-ups
related:
  - "#702"
---

# A budget break strands the work kinds after it

## Problem

`TurnActor.runSegment` drains one segment in a fixed order: products, abandonments, queued inputs, then releases of parked inputs. Releases are capped by `maxReleasesPerBatch`, and when a releasable key is left at `budget == 0` the loop scheduled `continueDrain` and **broke out**. #702 added a new work kind, the due follow-ups, after the releases. The plan's review found what the draft did: a segment that hit the cap never reached the follow-ups it held. That happened when a follow-up job's first step released more parked inputs than the cap, or a gate's result step did.

## Root cause

The `break` was written when releases were the last kind in the loop, so "the budget is spent" and "nothing else to do in this segment" were the same thing. Adding a kind after the budgeted branch made them differ, and nothing in the loop said the break covered only one kind.

## Fix

A capped segment stops releasing (a `capped` flag skips the release branch) and goes on with the other kinds; the follow-ups it holds step, each one re-checked and its products drained first. The cap still bounds releases per batch (core rule 7), and the rest of the parked inputs wait for `continueDrain` as before. Cases 27 and 27b in `Tests/SwiftStateTurnsTests/FollowUpTests.swift` run with a cap of 1 on both entry paths.

## Prevention

- When a drain loop has an early exit for one kind's budget, the exit stops that kind, not the loop. Write it as "skip this branch from now on", and let the loop end when no kind has work.
- When adding a work kind to such a loop, name where it sits relative to every budget and exit, and test it with the budget exhausted (a cap of 1 or 2), not only with the default.
- The generated orders already run every third seed with a budget of 2 (`GeneratedOrderTests.budget(for:)`); a new kind should be reachable from the generator so those seeds cover it.

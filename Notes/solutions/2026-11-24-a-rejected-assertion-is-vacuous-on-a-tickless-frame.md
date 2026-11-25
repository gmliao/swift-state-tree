---
title: "A `rejected` assertion is vacuous on a tickless frame"
module: SwiftStateTree
date: 2026-11-24
problem_type: testing_practice
component: replay-rejected-check
symptoms:
  - "a replay test asserts no divergence for a refused input, and a mutant that lists the input as refused still passes"
  - "takeRecordedPassMismatch(for:) is nil whatever replay refused"
root_cause: replay_compares_rejected_lists_only_on_tick_lands_and_tickless_records_with_passes
resolution_type: design_rule
severity: low
tags:
  - replay
  - tickless
  - rejected
  - mutant
  - testing
related:
  - "#778"
  - "#586"
---

# A `rejected` assertion is vacuous on a tickless frame

## Problem

#778 pins how replay reports a recorded action whose payload doesn't decode, before #700 K1a moves that decode. One assertion was "the action isn't in the replayed `rejected` list". It was checked as "no divergence for tick 0" (`takeRecordedPassMismatch(for: 0) == nil`) against a frame that lists no refused input. The test reused `ReplayInputDecodeTests`' land, which has no tick. A mutant that listed every refused input, the undecodable action included, still passed.

## Root cause

Replay compares the inputs it refused with the frame's recorded `rejected` list in two places. A tick land compares them after its tick's inputs (LandKeeper.swift, after `processPendingActions`, guarded by `!isTickless`). A tickless land compares them per recorded pass. A tickless frame without passes, which is what a hand-written record without `passes` gives, has nothing to compare. So on that land the mismatch is nil whatever replay refuses, and the assertion can't fail.

## Fix

The test's land got a `Tick` (an hour's interval, never fired by the test; `stepTickOnce` drives it). Then the mutant failed: `Expectation failed: await keeper.takeRecordedPassMismatch(for: 0) == nil`.

## Prevention

- A replay assertion on `rejected` needs a land and record where replay compares the list: a tick land, or a tickless record with `passes`. Run the mutant that changes the list before trusting the assertion.
- This is the same class as [a verdict never checked on one land kind](2026-11-14-a-verdict-never-checked-on-one-land-kind.md), seen from the other side: the check exists but doesn't run on the land kind the test happens to use. [A surviving mutant](2026-11-13-a-surviving-mutant-is-a-coverage-gap-or-an-equivalent-site.md) is how it showed.
- Pinned by `ReplayPayloadDecodeFailureTests` (#778), with both mutants in its PR body.

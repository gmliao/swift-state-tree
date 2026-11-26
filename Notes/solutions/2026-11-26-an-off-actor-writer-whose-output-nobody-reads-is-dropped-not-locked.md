---
title: "An off-actor writer whose output nobody reads is dropped, not locked"
module: SwiftStateTree
date: 2026-11-26
problem_type: design_pattern
component: land-keeper
symptoms:
  - "an async handler's context writes a keeper structure that has no lock, after an internal await"
  - "a fix proposal adds a lock to a structure the actor otherwise owns"
  - "a hold point shows the write running while the actor is inside another synchronous segment"
root_cause: an_async_handler_resumes_off_the_actor_and_its_context_closures_reach_actor_state_directly
resolution_type: design_rule
severity: medium
tags:
  - concurrency
  - isolation
  - outputs
  - drain
  - land-keeper
related:
  - "#893"
  - "#892"
  - "2026-11-21-a-closure-that-captures-only-actor-state-runs-off-the-actor"
---

# An off-actor writer whose output nobody reads is dropped, not locked

## Problem

`AfterFinalize` is async. Its `LandContext`'s output closures call the keeper's `OutputCollector` directly, and the collector has no lock. After an await inside the handler, the handler runs off the keeper's actor. Meanwhile the actor runs other calls that write the same collector: a join resumed from `CanJoin`'s resolvers emits, and a leave takes a sequence number. A probe held the actor inside `CanJoin`'s synchronous handler on a semaphore that only `AfterFinalize`'s emit released. The emit completed, and it took the sequence number between `CanJoin`'s two emits.

## Root cause

An async handler resumes on the global executor. Closures it holds reach actor state through a reference, so they run wherever the handler runs. Nothing in their type says so.

## Fix

The first fix that comes to mind is a lock on the collector. The better question is who reads what the writer writes. Here nobody does: `AfterFinalize`, like the other destroy handlers, runs after the drain began, and no tick, sync or input turn takes an event or a sync request after that. So the destroy handlers' contexts drop their outputs and count them (`destroyHandlerOutputsDropped`), and nothing reaches the collector off the actor.

A lock would also have been undone shortly after. The K1b-5 move puts the sequence counter in the keeper's model, where an off-actor caller can't reach it at all.

## Prevention

- When a writer runs off the actor, first find its readers. A write nobody reads is dropped at the source, like a send on a channel whose reader is gone, instead of guarded.
- Before adding a lock to actor-owned state, check whether a planned change moves that state somewhere a lock can't follow, such as into a value the actor holds `inout`.
- Show the race with a hold point that keeps the actor inside a synchronous segment while the other writer runs, not with timing. TSan doesn't catch this class.

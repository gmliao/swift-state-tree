---
title: "A guard against a stale input is tested mid-flow: after the flow ends, nothing is left to show the guard's absence"
module: SwiftStateTree
date: 2026-11-28
problem_type: testing_practice
component: keeper-turn-core
symptoms:
  - "removing a stale-epoch or stale-ticket check leaves every test green"
  - "a case delivers the stale input after the drain or flow has finished and asserts the model is unchanged"
  - "a hand mutant on a guard survives although a case is named for that guard"
root_cause: stale_input_delivered_after_the_flow_ended_where_the_unguarded_step_is_a_no_op_too
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutants
  - stale-input
  - epoch
  - drain
  - hold-points
related:
  - "#700"
  - "#969"
---

**Problem.** Plan §13.1 of `Notes/plans/2026-11-27-k2-2-cut-over-the-keeper-onto-the-core.md` gives the core a `loopEpoch`. The drain start bumps it, and a `.tickDue` or `.syncDue` carrying an older epoch is a no-op (`KeeperMachine.swift`, the `.tickDue` and `.syncDue` arms). The first case, `staleLoopInputsAfterDrainStart`, sent the stale inputs after `.shutdown` had returned and expected an unchanged digest. With either epoch check removed by hand, the case still passed.

**Root cause.** By then the drain had finished. The port was detached, the shape has no sync handler, and `tickStart` refuses a draining land. The stale step without its guard did nothing either, so "unchanged" held both ways. The input that the guard is for arrives while the flow is still in progress, and the case never put it there.

**Fix.** `staleTickDueAfterDrainStart` (#969) sends the stale inputs mid-drain:
- a tick is held at its record (`armedRecordGate`), so `ticksInFlight > 0`;
- the drain flag is set and `.drainStart` is sent, so the drain parks at `.waitingForTick` with the port still attached;
- then the stale `.syncDue` and `.tickDue` arrive, and the case checks the port trace is empty and the digest unchanged.

The sync guard's mutant now fails 5/5 at the trace check. The tick guard's mutant survives this case, because `tickStart`'s drain check also stops a stale tick on a draining tick land. That doesn't make it equivalent: review found two places where only the epoch stops it. One is an open tick land after `.startLoops` moved the epoch. The other is a draining tickless land, whose tick step never calls `tickStart`. `staleTickDueOnAnOpenLand` covers the first.

**Prevention.**
- A case for a guard against a stale or late input holds the flow at the point where the input can really arrive. Hold it with a hold point or a gate, while the effect the guard prevents can still happen. Here that effect is a port call, a counter, or a state write.
- Before naming a case for a guard, remove the guard by hand and run the case. A survivor means the case doesn't test the guard. Either move the case into the flow, or state why the mutant is equivalent. Equivalent means another check stops the input in every state where it can arrive, not only in the one the case builds.
- Related: [Force the interleaving with hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md), and [A flow moved onto the core needs a core case per exit](2026-11-27-a-flow-moved-onto-the-core-needs-a-core-case-per-exit.md).

---
module: SwiftStateTreeTransport
date: 2026-11-21
problem_type: bug_class
component: output-gate
symptoms:
  - "an action's reply reaches the client after its land failed"
  - "a join flips, or a sync plan reports its own failure, after an adapter closed the gate"
  - "the land's failure is syncPlan, not the responseEncode that closed the gate first"
root_cause: a_gate_checked_at_each_send_site_and_a_failure_known_only_through_an_awaited_submit
resolution_type: design_rule
severity: medium
tags:
  - transport
  - reentrancy
  - failure
  - output-gate
  - turns
related:
  - "#696"
  - "#704"
  - "#732"
---

# A gate checked per send site leaks at the next site; a failure found outside a turn needs a mailbox

## Problem

A land's output gate closes when the land fails. Two leaks came from the same shape (#696, #704):
- **Frames after the close.** Event sends and the sync commit read the gate, but an action's answer, error and join replies and the router's frames through the adapter didn't. Each of those sites had to remember the check, and the ones added later didn't.
- **Keeper work after the close.** An adapter that found a failure outside a turn closed the gate, then awaited `submitLandFailure`. The keeper learned of the failure only when a turn applied that queued input. Until then its turns ran as if the land were live: a sync phase flipped a waiting join, reported its own failure first, or ran through a rebound adapter whose gate was open.

## Root cause

- The gate was a property of the senders, not of the path every frame takes. A check repeated at each send site holds only for the sites that exist when it is written.
- The failure crossed actors only through an await. Every keeper step that ran during the hop, or before the queued input's turn, acted on the old view.

## Fix

- **Check where frames are enqueued.** `enqueueFrames`, the one door to the outbound writer, reads the gate in the same segment as the enqueue and counts the drops. The frames that must still go out after a failure (a session's final frame with its close, the 4016 closes) take a different door on purpose.
- **Note the failure where the keeper reads it.** The adapter writes the failure into a set-once, lock-protected mailbox on the keeper (`notePendingFailure`) in the segment that finds it. The keeper reads the mailbox at each step boundary: after an apply segment (`finishApply`), at the start of a sync-only turn, and at the start of a turn's output step. The awaited submit stays, but it only wakes a keeper with no step due.
- **One helper owns the close.** Every close outside a turn goes through `closeAndNoteOutsideTurn` or `failOutsideTurn`, and a census script in CI (`scripts/gate-close-census.sh`) fails on a close anywhere else.

## Prevention

- A rule that every send must obey belongs at the chokepoint every send passes, not at the sends. List the deliberate exceptions next to the chokepoint, with why they bypass it.
- A fact found outside an actor that its next step must act on goes into a set-once box the actor reads synchronously at its step boundaries. An awaited message alone leaves a window of as many steps as run before it lands.
- When a helper must be used for a whole class of call, pin it with a census that names the allowed sites, and a mutant that bypasses the helper so the census and a test both fail.
- A gate test must hold the interleaving at the await between the close and the submit (`.failureSubmit`), not race it.

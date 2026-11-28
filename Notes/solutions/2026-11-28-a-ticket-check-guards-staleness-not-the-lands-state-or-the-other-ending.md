---
title: "A ticket check proves the work is current, not that the land is alive or that its follow-up survives another ending"
module: SwiftStateTreeTransport
date: 2026-11-28
problem_type: bug_class
component: debug-freeze
symptoms:
  - "a debug freeze answers success for a land that failed or shut down while its settle waited to publish"
  - "events a debug freeze kept stay unsent after an auto-resume, on a land without periodic sync"
root_cause: publish_segment_checked_only_its_ticket
resolution_type: established_pattern
severity: low
tags:
  - ticket
  - segment
  - debug-freeze
  - ordering
related:
  - "#730"
  - "2026-11-05-await-resumes-on-stale-state"
  - "2026-11-26-a-close-decided-in-one-component-must-be-seen-by-the-others-in-its-segment"
---

# A ticket check proves the work is current, not that the land is alive or that its follow-up survives another ending

## Problem

The debug freeze's settle publishes its result in one segment after its last await, guarded by `debugFreezeTickets.ifCurrent(ticket)`. Two gaps (#730):

- A land that failed or shut down while the settle waited at the publish still got a success: the freeze's ticket was current, because nothing about the land's end touches the freeze's ticket.
- The publish was also where the settle recorded a follow-up: "events are still queued and nothing but the resume delivers them" (`deferredSyncNow`). An auto-resume that ran before the publish ended the ticket first, so the publish never ran, and the release read the flag as false. On a land without periodic sync the kept events stayed queued.

## Root cause

A generation ticket answers one question: is this work still the current one? The publish treated it as the whole precondition. The land's own state (failed, draining, output closed) is a second precondition with its own source. A follow-up recorded only on the success path is lost whenever another path ends the work first.

## Fix

- The publish segment reads `keeper.failure`, `outputGate.failure` and `keeper.isDraining` (all nonisolated, no await) next to the ticket, and throws the cause instead of publishing.
- The kept-events condition is one property (`debugFreezeKeepsEventsUnsent`) that both the publish segment and the release segment read. Whichever of the two runs, the resume runs the deferred sync.

## Prevention

- Where a ticket guards a publish after an await, list the other preconditions that can change across that await (the owner's failure or close), and read each one in the publish's segment.
- When a segment records a follow-up (a deferred sync, a cleanup) on its success path, list the other segments that can end the same work (a release, a timeout, a cancel). Each of them checks the same condition, or the follow-up is lost on that path.
- Test each with a hold at the publish: end the land there, or run the competing ending there, then open the hold.

---
title: "A phase one actor owns lags an event another actor sends: read a set-once mailbox"
module: SwiftStateTreeTransport
date: 2026-11-25
problem_type: bug_class
component: land-router
symptoms:
  - "a second join sent right after the JoinResponse gets JOIN_IN_PROGRESS instead of JOIN_ALREADY_JOINED"
root_cause: router_phase_learns_of_the_adapter_flip_in_a_task_of_its_own
resolution_type: code_fix
severity: low
tags:
  - join
  - router
  - hold-points
related:
  - "Tests/SwiftStateTreeTransportTests/HandshakeFrameLimitTests.swift"
  - "#867"
---

# A phase one actor owns lags an event another actor sends

## Problem

The adapter flips a join in its commit segment and enqueues the JoinResponse there. The router keeps its own handshake phase and learns of the flip later, when its flip wait resumes in a Task. A second join that arrives in between saw `.joining` and was answered `JOIN_IN_PROGRESS`, although the client already held the response.

## Root cause

Two actors each hold a view of one fact (the join is done). The sender's view changes first and the frame the client sees is written in that segment, so the receiver's view can be behind what the client saw.

## Fix

A set-once flag on the mailbox the router already hands to the adapter (`JoinAttemptEnd.markFlipped()`), written in the flip's segment before the response is enqueued. The router's join check reads it. The phase itself is still set only by the router's flip wait.

## Rule

A reader that must agree with what the client saw reads a set-once mailbox written in the sender's segment, before the frame goes out. It does not wait for its own phase, and the sender does not write the receiver's state.

Test it with the router's hold point (`.flipWaitResumed`), not timing.

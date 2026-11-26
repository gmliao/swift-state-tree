---
title: "A precedence test must stage a pair of decisions production can produce"
module: SwiftStateTreeTransport
date: 2026-11-26
problem_type: testing_practice
component: session-close
symptoms:
  - "a test pins which of two decisions wins, but the second decision can never select the target after the first"
  - "a staged pair passes, and the rule it claims to pin is never exercised in a real run"
root_cause: second_decision_staged_on_a_target_the_first_decision_s_bookkeeping_already_removed_from_its_selection
resolution_type: established_pattern
severity: low
tags:
  - testing
  - precedence
  - close
  - reachability
related:
  - "#911"
  - "2026-11-26-a-barrier-that-looks-up-live-state-skips-what-is-being-torn-down"
---

# A precedence test must stage a pair of decisions production can produce

## Problem

#911 states which close a connection gets when the server decides two: the first one decided, with at-once closes (a failed land's 4016, a sync-lag close) going ahead of a pending ordered one. Rev 1 of the plan pinned "at-once preempts" with this pair: a supersede's pending 4017, then a sync-lag close of the same session. Review found the pair can't happen. The supersede unregisters the old member and removes its `syncLag` entry in the same segment, and the sync-lag close reads `syncLag`. A land failure doesn't fit either: it iterates the membership the superseded session has left. The test would have passed while pinning a rule no run can reach.

## Root cause

A precedence test calls the two decisions directly, so it can stage any order. But in production, the first decision's bookkeeping changes which targets the second one selects. A pair the code never produces passes, or fails, for no reason that matters.

## Fix

The test stages a pair that production can produce: a member whose final frame's close is pending (the post-flip inbound overflow, which leaves the session a member), then `closeSessionsForLandFailure`, which closes every session the adapter holds. The test also checks that the staged first decision left the target selectable (`isJoined`). The plan's probe lists, for each ordered close, which at-once close can still select the session after it.

## Prevention

- Before staging "A, then B" in a test, read how B selects its targets (a table, a membership set, a map entry). Then check that A's bookkeeping leaves the target in B's selection. Write that check into the test as an expectation, so a later change to A's bookkeeping fails the test instead of quietly making it pin nothing.
- Stage the first decision the way its real caller makes it. A direct call that skips the caller's bookkeeping can create a state no run reaches.

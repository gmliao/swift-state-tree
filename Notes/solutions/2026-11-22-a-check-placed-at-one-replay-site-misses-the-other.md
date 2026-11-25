---
title: "A check placed at one replay site misses the other"
module: SwiftStateTree
date: 2026-11-22
problem_type: bug_class
component: reevaluation-initialize-check
symptoms:
  - "a replayed OnInitialize refusal is reported on a 2.1-or-later record but not on a record without an initialize record"
  - "the initialize verdict is `notRecorded` although OnInitialize's validate threw in replay"
  - "a verdict computed in prepare() doesn't see what tick 0 replays"
root_cause: one_handler_replays_at_two_sites_and_the_check_ran_before_the_later_one
resolution_type: design_rule
severity: medium
tags:
  - replay
  - reevaluation
  - initialize
  - verifier
related:
  - "#593"
---

# A check placed at one replay site misses the other

## Problem

#593 made OnInitialize two-phase. In replay, a `validate` that throws contradicts the record, so the plan had the initialize check report `.failed`. The keeper notes the refusal, and `verifyInitialize` reads the note first, "so an older record reports `.failed` too".

That held for a record with an initialize record (format 2.1 on). It didn't for a record without one: the verdict stayed `.notRecorded`.

## Cause

OnInitialize replays at two sites:
- before tick 0, from the initialize record (`replayInitializeBeforeTickZero`);
- inside tick 0, as a lifecycle item, for a record that has no initialize record.

Both the engine and the hosted runner compute the initialize verdict once, right after the keeper's initialization and before the first tick. The first site has run by then, the second hasn't. So the check read the note before the older path could write it.

The plan found both sites and changed both, but placed the check by the order of the code, not by when each site runs.

## Fix

The verdict is computed as before, and then once more after tick 0 (`ReevaluationEngine.initializeVerdict(_:afterTickZeroRefusal:)`), in the engine's loop and in the runner's `step()`. A refusal noted in tick 0 turns the verdict into `.failed`; a verdict that already failed keeps its reason. A test runs both sites through both the engine and the runner, and a mutant that drops the late check fails it.

## Rule

When a replay check judges one handler, list every site that replays that handler and when each runs relative to the check. A check that reads a site's result must run after that site. Test each site through each consumer of the verdict (here the engine and the runner).

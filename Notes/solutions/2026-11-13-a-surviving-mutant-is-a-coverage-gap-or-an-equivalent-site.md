---
module: SwiftStateTreeTransport
date: 2026-11-13
problem_type: testing_practice
component: sync-phase-plan
symptoms:
  - "a mutant survives although the scenario test injects that failure"
  - "an encode fault makes every attempt fail, so the fallback that sends part of an update never runs"
  - "a mutant at a failure branch changes nothing because the state it clears isn't staged yet"
root_cause: fault_fails_every_attempt_and_mutant_site_precedes_its_state
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutants
  - fault-injection
  - encode-failure
  - sync-tables
  - per-player
related:
  - "#514"
---

# A surviving mutant is a coverage gap or an equivalent site: find out which

## Problem

The per-player sync tables (#514) were checked with a mutant per rule in the plan. Two of them survived the scenario tests, which already inject plan failures, per-player encode failures and a failing opcode 107 merged broadcast frame.

## Root cause

**The fault failed every attempt.** A per-player update that fails to encode is re-encoded without the patches that can't be encoded, and the rest is sent and committed. The injected encode fault fails the re-encode too, so the tests only ever reached "nothing is sent". A mutant that discards the player's staging after a *successful* dropping re-encode changed no frame the tests produced.

**The mutant's site ran before the state it attacked existed.** The mutant for "per-player writes staged in the broadcast namespace" cleared the per-player staging where a failed merged broadcast frame clears the broadcast staging. That frame is planned before any per-player diff runs, so the per-player staging was still empty there. The mutant was equivalent; no test could kill it.

## Fix

- A per-player `Double` field set to NaN under JSON: the update drops that patch, sends the rest, and the next plans must match the run without the tables. It kills the first mutant.
- The second mutant moved to where the two stagings meet, the commit: per-player staging applied only when the broadcast staging was. The existing scenarios kill it.

## Prevention

- **For each fallback that can succeed partly, inject a fault that fails only part.** A fault that fails every attempt tests the all-failed branch alone. Use a real input that one path can't take (NaN under JSON, a throwing conversion for one player) next to inputs it can.
- **Before writing a test for a survivor, check that the mutant's site runs after the state it changes.** Read the order of the plan: if the site runs before the state is staged, the mutant is equivalent; move it to where the state is used (the commit, the next read), and record the move.

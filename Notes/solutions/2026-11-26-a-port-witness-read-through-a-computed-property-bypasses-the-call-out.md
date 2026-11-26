---
title: "A port witness read through a computed property or a held helper bypasses the turn body's call out"
module: SwiftStateTree
date: 2026-11-26
problem_type: gotcha
component: land-keeper
symptoms:
  - "a re-entry from a transport is applied by `withTurn`'s late backstop (`lateReentriesApplied` > 0)"
  - "a settle records `draft → endTurn → terminal` instead of `terminal → endTurn`"
  - "a consumed join's caller gets a success from a turn that then ended the land"
root_cause: port_call_outside_callout_through_an_indirect_member
resolution_type: established_pattern
severity: high
tags:
  - turns
  - reentrancy
  - sentinel
  - callout
  - transport
related:
  - "#700"
  - "#865"
  - "2026-11-26-a-hold-check-one-call-deep-misses-an-access-two-calls-down"
---

# A port witness read through a computed property or a held helper bypasses the turn body's call out

## Problem

A turn body (#700 K1b-5a) makes every call out of the keeper through `callOut`. `callOut` samples the re-entry count, makes the call, and ends the land in that call if the count grew, before the body reads the answer. The bodies' direct port calls (`transport.runSyncPhaseInTurn`, `port.runsSyncPhaseInTurn`) all went through it. Review still found five calls into the transport that didn't:
- the recording, `inTurnSyncRecording`, in the settle and in the input turn's output step;
- the input turn's `if syncsInTurn` check;
- `applyInputs` → `noteJoinInputsConsumed`.

A port that re-entered there was refused by the sentinel, but nothing ended the land in that call. The body went on to use the answer: it ran the phase, or stored a join's success. `withTurn`'s backstop ended the land only after the body returned. In the settle, the turn's end entry was then recorded before the terminal one.

## Root cause

The port calls were one or two members away from the body:
- `inTurnSyncRecording` reads `recordsSyncStream`;
- `recordsSyncStream` reads `syncsInTurn`;
- `syncsInTurn` calls `transport.runsSyncPhaseInTurn(of:)`.

A computed property reads like a field. And `applyInputs` is itself a holder (`_ m: inout`), so its port call sits in a function the body calls with `&m`, not in the body. A search of the bodies for `transport.` finds none of them.

## Fix

Route each one through `callOut`, as the sync-only body already did for the recording: `callOut(&m, &side, &outputs, { m in inTurnSyncRecording(m) })`. A refusal ends the land there, and the body skips the step. For the call inside `applyInputs`, the caller passes a hook (`reportJoins:`): in a body it reports through `callOut`, and outside one it calls the port directly. That keeps the report where it was, before the shutdown turn's completion and `failLand`. The one bare call left, `failLand`'s gate close, carries `// lint-allow: bare-port: <reason>`.

## Prevention

- Look for port calls transitively, as for model accesses: through computed properties and through holder-to-holder calls. A body's own text isn't enough.
- Test with a port that re-enters at the nth call it gets during a body, for every n until no call is left. Assert that the backstop applied nothing (`lateReentriesAppliedForTesting == 0`). That counts every site, including ones nobody listed. One case per known site misses the unknown ones.

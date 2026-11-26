---
title: "A new protocol requirement's default must forward to the older, more specific one it widens"
module: SwiftStateTreeTransport
date: 2026-11-26
problem_type: design_rule
component: transport-protocol
symptoms:
  - "after a protocol gains a wider overload, a conformer written before it loses a behavior it implemented"
  - "a custom transport closes at once again, dropping frames its ordered close used to deliver"
  - "the new call site compiles and passes with the built-in transport, and only a third-party conformer regresses"
root_cause: new_requirement_default_bypasses_the_existing_requirement_its_callers_used_to_reach
resolution_type: design_rule
severity: medium
tags:
  - swift
  - protocol-extension
  - default-implementation
  - transport
  - close
related:
  - "#909"
  - "2026-11-06-protocol-extension-default-wins-overload-resolution"
  - "2026-11-18-a-server-close-goes-around-the-send-queue"
---

# A new protocol requirement's default must forward to the older, more specific one it widens

## Problem

`Transport` had two ordered closes: `closeSessionAfterQueuedFrames(_:)` and `(_:generation:)`, whose default calls the first. #909 needed the ordered close to carry a code (a superseded session's 4017), so it added a third requirement, `closeSessionAfterQueuedFrames(_:generation:with:)`. It also moved the outbound writer's consumer to the new call, for every closing element: the supersede's 4017, and `sendFinalFrameAndClose`'s plain close too.

The first draft gave the new requirement the default "close at once with the code". That passes with `WebSocketTransport`, which implements the new method. But consider a transport written before #909 that implemented only `(_:generation:)`. The writer would now reach the new default, which closes at once. That transport would lose its ordered close for the final frames it used to deliver. Review found this in the plan, before any code.

## Root cause

When callers move from an old requirement to a new, wider one, a conformer of the old requirement is reached only through the new one's default. If that default doesn't call the old requirement, the conformer's implementation is never called again. Nothing warns: the conformer still compiles, and no test with the built-in conformer fails.

## Fix

Make the new default forward to the old requirement wherever the old one meant the same thing. With `.normal`, the new requirement asks exactly what `(_:generation:)` asked, so the default calls it. With any other code, the old requirement can't carry the code, so the default closes at once with it (`closeSession(_:with:generation:)`). That is what the supersede did before #909 on every transport. The chain is pinned in two places:
- `Notes/plans/2026-11-26-909-probe.swift` (P-909-1 rev 2): a conformer with only the two-argument close, called through `any Port`;
- `SupersedeCloseOrderTests.orderedCloseDispatch`: the same check against `Transport`.

## Prevention

- When you add a requirement that widens an existing one, and move callers to it, write its default as a forward to the existing requirement for the inputs it shares. Close at once, or do nothing, only for the inputs the old requirement can't express.
- Test the default with a conformer that implements only the old requirement, called through the existential (`any Protocol`), the way the real caller calls it.
- Check the whole default chain, not just the new method: list every requirement in the family and the default each one reaches.

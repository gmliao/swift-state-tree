---
title: "Inlined class state pays a dynamic exclusivity check on every use"
module: SwiftStateTurns
date: 2026-11-19
problem_type: gotcha
component: turn-core
symptoms:
  - "a generic core that is already specialized across modules still costs far more per call than the same work by hand"
  - "the disassembly of an inlined hot path is full of `swift_beginAccess` / `swift_endAccess` calls"
  - "a `read` of a value-type machine costs about twice a hand-written lookup"
root_cause: dynamic_exclusivity_checks_on_class_stored_properties
resolution_type: design_rule
severity: medium
tags:
  - performance
  - exclusivity
  - inlinable
  - class-state
  - release-build
related:
  - "#621"
  - "#608"
  - "2026-11-19-a-cross-module-generic-wrapper-runs-unspecialized"
---

# Inlined class state pays a dynamic exclusivity check on every use

## Problem

`TurnCore<M>` is a final class in its own module, used from the adopter's module. #608's instruction counts showed `read` (one dictionary lookup through the core) at about twice the hand-written lookup, and a step that emits one output at about seven times. The first suspect was cross-module specialization ([the wrapper entry](2026-11-19-a-cross-module-generic-wrapper-runs-unspecialized.md)). It wasn't the cause: every driver function on the path was already `@inlinable` and specialized on the bench's types.

## Root cause

The disassembly of the bench's hot loop, with the core inlined into it, held 66 `swift_beginAccess` and 17 `swift_endAccess` calls. These are Swift's dynamic exclusivity checks. The compiler can't prove statically that nothing else accesses a class's stored property during a use, so in every build, release included, each read or modify of `machine`, `rt`, `inStep` and the rest begins and ends a tracked access. Inlining the core doesn't remove them: it copies them into the caller. A per-input path that touches the core's state a dozen times pays a dozen pairs.

Grouping the hot state into one struct, with one access per step and per read, was tried as well. A read still needs at least one access, so it didn't go below the original cost. Holding the access across the read's body, which is what lets the check catch a step started from inside `read`, made it more expensive. A deferred send made inside a step then touched the same struct and was a fatal access conflict. Every path that can reenter during a held access needed its own route around it.

## Fix

- Every stored `var` of `TurnCore` carries `@exclusivity(unchecked)` under `#if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED`. Debug builds keep the checks, so the tests and the generated orders still run with them on. A release build with `-Xswiftc -DTURNS_EXCLUSIVITY_CHECKED` keeps them too.
- The core stops the process on the overlaps it can see, by one borrow state, `borrows`, modelled on Rust's `RefCell` flag (0 unused, n > 0 readers, -1 writing) and SE-0176's rule (reads nest; a read with a write, or two writes, don't). A step needs it unused, a read needs it not writing. The overlap only the runtime check caught before, a step started from inside `read`'s body, is one cell of that table. Each cell has an exit test, the nested read included.
- A first fix used a second flag, `inRead`, cleared in `read`'s `defer`. A read nested inside another read cleared it on return, so a send from the outer body stepped unguarded. Two booleans for one borrow state invite that. A count with one rule doesn't.
- The core can't stop adopter code it runs during its own accesses: the key type's `==` and `hash(into:)`, and the deinits of inputs and keys it drops. The docs make that a requirement on adopters (no call back into the actor from them), tested with the checked build.
- On the Mac, the turn side's `read1` went from 237 to 142 instructions per call (direct: 135) and `emit` from 2538 to 1629.
- `scripts/lint-turns.sh` (rule `unchecked-state`) fails when a stored var of `TurnCore` lacks the attribute under that exact condition.

## Prevention

- When a class's state sits on a per-input path inlined into another module, count `swift_beginAccess` in the caller's disassembly before looking for anything else. Specialization only removes the generic overhead. A class's dynamic exclusivity checks remain after it.
- `@exclusivity(unchecked)` is sound only where something else serializes every access (an actor, here) and the overlaps the check would catch are stopped by hand. List those overlaps, and test each one in a child process, nesting included. Keep the borrow state as a count (readers) or a writing mark, not a flag per kind: a flag cleared by an inner call's `defer` reopens the outer one.
- Also list the user code that runs inside the type's own accesses (`Hashable` conformances, deinits of values it drops). No guard sees it, so it becomes a documented requirement with a checked build to test it.
- Keep the checks in debug builds and behind a flag in release builds, so a suspected overlap can be checked in production code.

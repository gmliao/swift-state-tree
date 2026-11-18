---
module: SwiftStateTreeTransport
date: 2026-11-18
problem_type: bug_class
component: message-encoders
symptoms:
  - "Fatal error: Payload type 'Dictionary<String, Any>' must conform to PayloadCompression and use @Payload macro for compression support."
  - "one land's emitAnyServerEvent with a dictionary payload ends the whole server process"
  - "a replay with .projectedWithFallback on messagepack crashes every land on the host"
root_cause: fatalError_in_the_fallback_branch_of_a_cast_on_a_type_erased_value
resolution_type: design_rule
severity: high
tags:
  - encoding
  - crash
  - type-erasure
  - land-failure
  - replay
related:
  - "#544"
  - "#538"
  - "#535"
---

# A `fatalError` in a cast's fallback branch is reachable from type-erased data

## Problem

Both positional message encoders (`OpcodeTransportMessageEncoder`, `MessagePackTransportMessageEncoder`) unwrap a payload from its `AnyCodable` box and cast it, `base as? any PayloadCompression`. Their fallback branch, for a value that isn't a payload type, was a `fatalError`. Two paths reach it:
- a live land's `emitAnyServerEvent` with a dictionary, an array or a primitive payload (#544);
- the replay land's re-emit of a recorded event under `.projectedWithFallback` (#538). A record's payload is JSON-decoded into `AnyCodable`, so its base is `[String: Any]`.

On a compressed encoding (`messagepack`, the default, or `opcodeJsonArray`), either one ended the server process, and every land on it.

## Root cause

The cast's failure looked impossible: every registered event, action and response type is a `PayloadCompression`, and registration refuses one without `@Payload`. But the value being cast was type-erased (`Any` inside `AnyCodable`). A type-erased value can come from anywhere that builds the box: a caller of a public API that takes `AnyCodable`, or a decoder that fills it from JSON. The invariant held for the typed path only. The `fatalError` turned a per-land data fault into a process fault, which the failure rule forbids (`docs/core/failure-handling.md`: a failure ends the smallest unit it corrupted).

## Fix

The fallback branch throws `UntypedPayloadError` (the value's type name) instead of trapping. The adapter already treats an event that reaches no frame as lost and ends the land with `LandFailure.Kind.eventEncode` (#535 row 17), so the land that emitted the value ends, its sessions close with 4016, and the process and the other lands keep running. `UntypedEventPayloadTests` covers both paths on both compressed encodings, with exit tests that fail on a build that still traps.

## Prevention

- **No trap on a value that crossed a type erasure.** A `fatalError`, `precondition`, `!` or `as!` on a value that came out of `Any`, `AnyCodable` or another existential is reachable from whoever filled the box, not only from our typed callers. Throw a named error and let the caller's failure path decide its scope.
- **Find the public entry points that fill the box.** Before calling a cast's failure "impossible", list who constructs the erased value: public initializers (`AnyServerEvent(type:payload:)`), decoders (a record, a client frame), and test helpers.
- **Test it as a crash.** A test of such a site passes the untyped value through the public path. Run it as an exit test (`#expect(processExitsWith: .success)`), so a trapping build fails the test instead of ending the test run.

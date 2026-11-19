---
module: SwiftStateTree, SwiftStateTreeTransport
date: 2026-11-19
problem_type: performance
component: inbound-decode-chain
symptoms:
  - "a change that removes work on a hot path measures as an instruction REGRESSION"
  - "perf shows value witnesses (`Vwxx`, `Vwet`, `Vwst`) of a small generic struct, swift_release, getCache and conformance-cache lookups rising, while the removed work's symbols fall"
  - "a generic method of a wrapper type shows up as its own symbol in a profile, called from another module"
root_cause: cross_module_generic_without_inlinable_runs_unspecialized
resolution_type: design_rule
severity: medium
tags:
  - performance
  - generics
  - specialization
  - inlinable
  - existential
  - proof-type
related:
  - "#362"
  - "#616"
  - "2026-11-18-a-parsers-depth-limit-isnt-the-pipelines"
---

# A small generic wrapper used from another module runs unspecialized unless it's `@inlinable`

## Problem

#616 skips the payload's depth walk for a live input whose frame the decode already bounded. The proof is a small generic struct, `DepthBounded<Value>`, defined in SwiftStateTree and narrowed (`compactMap`) to the action or event in SwiftStateTreeTransport's adapter. The walk was gone as intended. Even so, the A/B measured `vis-act-mp` at +1.82 % `instructions:u` in the nonsync window, a REGRESSION, where a gain was expected.

## Root cause

A profile of base against head (`perf record -e instructions:u` in the same window) showed where the instructions went:
- The walk's symbols fell: `PayloadNesting.fits`, and the `tryCast` and `swift_dynamicCast` calls from its `as?` checks.
- Three things rose more:
  - **The cross-module generic.** `DepthBounded`'s members weren't `@inlinable`, so the adapter's `compactMap` ran unspecialized: the `TransportMessage` went through the struct's value witnesses, boxed existentials and a closure context on every action frame. `swift_release`, `getCache`, metadata cache lookups and `DepthBounded`'s own witnesses rose. Inside one module, the optimizer specializes such a generic; across modules it can't see the body.
  - **`is` casts on an existential per frame.** The pipeline checked `codec is MessagePackTransportCodec` and `codec is JSONTransportCodec` for every frame. Each is a dynamic cast of an existential, with a conformance-cache lookup.
  - **The value stored twice.** The pending items kept both the `AnyCodable` and a `DepthBounded<AnyCodable>?` of it: two retains and releases per item copy, and a larger item.

## Fix

- `DepthBounded`'s initializer, `map` and `compactMap` are `@inlinable` (still `package`), so a caller in another module specializes them.
- The pipeline makes the two codec checks once, in its initializer, as stored `Bool`s.
- A pending item stores its payload once, as `MaybeDepthBounded<Value>` (`.bounded` or `.unchecked`), and derives the plain value and the proof from it.

## Prevention

- A "zero-cost" wrapper on a hot path that is built or read in another module than the one defining it needs `@inlinable` members, or it isn't zero-cost. The same holds for a generic helper of any kind used across a module on a per-input path.
- Don't test an existential's concrete type (`x is T`) per input when the instance can't change: decide once where it's stored.
- When a change is meant to remove work, profile base against head by symbol before calling the A/B. Read the symbols that rose, not only the one meant to fall.

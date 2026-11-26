---
title: "An optional-chain or subscript assignment into a stored struct begins its access before the call on its right"
module: SwiftStateTree
date: 2026-11-26
problem_type: gotcha
component: land-keeper
symptoms:
  - "Simultaneous accesses to 0x…, but modification requires exclusive access"
  - "Fatal access conflict detected, in a function that only assigns one field"
  - "a crash after moving actor fields into one struct, in code that didn't change"
root_cause: lvalue_access_begins_before_rhs_call_that_writes_the_same_storage
resolution_type: code_fix
severity: high
tags:
  - exclusivity
  - keeper
  - model
  - inout
  - swift
related:
  - "#700"
  - "2026-11-19-inlined-class-state-pays-dynamic-exclusivity-checks"
---

# An optional-chain or subscript assignment into a stored struct begins its access before the call on its right

## Problem

K1b-4 (#700) moved the keeper's stored fields into one struct, `model`. Before the move these were separate actor properties, and this line was fine:

```swift
actionSlots[sequence]?.result = held(outcome)
```

`held` mints a failure ID, which writes `failureIDs`, another property. After the move both live in `model`, and the line became:

```swift
model.actionSlots[sequence]?.result = held(outcome)
```

Tests that filled a slot with a failure crashed the test process with "Simultaneous accesses … modification requires exclusive access".

## Root cause

For an assignment through an optional chain or a subscript, Swift evaluates the left side first: it begins the modify access to `model` and projects `actionSlots[sequence]?`, then evaluates the call on the right. The call writes `model.failureIDs`, a second access to `model` while the first is open. `model` is a stored property of an actor (class storage), so the overlap is checked at run time, in release builds too, and traps. Two separate actor properties never overlapped, which is why the same code was fine before.

## Fix

Run the call into a local first, then assign:

```swift
let result = held(outcome)
model.actionSlots[sequence]?.result = result
```

Three sites had this shape in K1b-4 (the slot fill, the input-turn result setter and the initialization failure).

## Prevention

- When fields that a function writes move into one struct with fields that its caller assigns, check every assignment into that struct whose right side calls a method: a call that touches the same struct goes into a local first.
- `removeAll(where:)`, `sort(by:)`, `inout` arguments and mutating methods have the same shape: their closure or callee must not read the struct.
- The compiler doesn't catch this (no static diagnostic for class or actor storage), and TSan doesn't either. A test that runs the path in a debug build does: the full debug suite found all three sites.

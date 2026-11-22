---
module: SwiftStateTree
date: 2026-11-21
problem_type: gotcha
component: snapshot-conversion
symptoms:
  - "a depth or hop guard in a conversion never runs: the stack overflows in swift_dynamicCast first"
  - "`value as? [String]` on an `[Any]` takes time or stack proportional to what its elements hold"
  - "a typed fast path (`as? [PlayerID: SnapshotValueConvertible]`) is replaced by an exact-type check, and every concrete map drops to the slow path"
root_cause: a_cast_to_a_collection_type_casts_each_element_and_an_element_cast_unwraps_optionals_recursively
resolution_type: design_rule
severity: high
tags:
  - casts
  - collections
  - conditional-conformance
  - nesting-budget
  - stack-overflow
related:
  - "#716"
  - "#735"
---

# A collection cast converts every element

## Problem

`SnapshotValue.make` had fast paths such as `value as? [SnapshotValue]`, `as? [String]` and `as? [PlayerID: SnapshotValueConvertible]`. #716 needs every `Optional` a conversion unwraps to spend a hop, so a deep chain is refused before it recurses. An `[Any]` holding a 100 000-deep `Optional<Any>` chain never reached the hop count: the first fast path's cast unwrapped the chain inside the runtime.

The first fix proposed matching only the exact dynamic type (rev 1 of the S1a-2 plan). Review found the cost: a concrete `[PlayerID: PlayerState]` never has the dynamic type `[PlayerID: SnapshotValueConvertible]`. Every such field would have dropped to the `[PlayerID: Any]` boxing cast on each sync.

## Root cause

A cast to a collection type is a cast of each element. An element cast to a concrete or existential type unwraps `Optional`s in the source as it goes, recursively. So the cast costs time and stack in proportion to what the elements hold, and no guard in the caller runs first. A cast whose element type is `Any` doesn't unwrap: boxing never looks inside.

## Fix

#716 S1a-2a, in `SnapshotValue.swift`:
- concrete element types match the exact dynamic type (`Swift.type(of: value) == [String].self`), then cast: a no-op for that type;
- typed maps match by conditional conformance, as Codable does with `extension Array: Encodable where Element: Encodable`. The package protocols `_StateNodeMap` and `_SnapshotConvertibleMap` sit on `Dictionary where Key: _SnapshotMapKey`, with the value a node or a convertible. `value as? any _StateNodeMap` checks the conformance once on the type's metadata and never touches an element. `[Any]` fails it at once, since `Any` doesn't conform.

A type can conform to one protocol under only one set of conditions, so each value kind needs its own protocol.

## Prevention

- Before an `as?` to `[T]`, `[K: V]` or `Set<T>` with `T` or `V` not `Any`, ask what the elements can hold. If it's unbounded (`Any`, hand-written values), match the exact type or a conditional conformance instead.
- Test a fast path for being taken (a DEBUG probe), not only for its output: a fallback with the same output hides a lost fast path.
- An exit test far past the limit, with its guard-removed mutant on Linux, shows whether a guard runs before the runtime recurses.

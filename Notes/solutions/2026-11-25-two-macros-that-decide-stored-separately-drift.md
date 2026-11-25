---
module: SwiftStateTreeMacros
date: 2026-11-25
problem_type: bug_class
component: payload-macro
symptoms:
  - "a @Payload property with didSet is checked by the PlainData witness but missing from getFieldMetadata and the wire"
root_cause: two_expansions_used_different_tests_for_a_stored_property
resolution_type: code_fix
severity: medium
tags:
  - macros
  - payload
  - plain-data
  - property-observer
related:
  - "Tests/SwiftStateTreeTests/PayloadObservedFieldTests.swift"
  - "#837"
---

# Two macros that decide "stored" separately drift

## Problem

`@Payload`'s field list skipped every property with an accessor block. The PlainData witness, written for the same type, uses `PlainDataWalk.isComputed`, which counts a property with only `willSet`/`didSet` as stored. An observed property was checked as a field but never written, so it was dropped from the metadata and the wire.

## Root cause

"Is this property stored?" was answered twice, by two hand-written tests. `accessorBlock != nil` is the short spelling, and it is wrong for observers.

## Fix

`PayloadMacro.collectStoredProperties` and `storedProperty(naming:)` call `PlainDataWalk.isComputed`.

## Prevention

- One syntactic question, one predicate: macros that expand over the same declaration share the helper for "stored", "static" and similar, instead of re-deriving it.
- Test the agreement, not just each side: an expansion test that the witness and the field list name the same properties, and a runtime round trip.

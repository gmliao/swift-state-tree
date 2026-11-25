---
title: "A generated local shadows a property of the same name"
module: SwiftStateTreeMacros
date: 2026-11-21
problem_type: bug_class
component: macros
symptoms:
  - "a @SnapshotConvertible field named `inner` is sent as an object of `containersLeft`, `hopsLeft` and the limits"
  - "a field's snapshot holds a value of another type than the field, with no compile error"
  - "ShapeMatrixRoundTripTests: the wire value of a struct case differs, and only that case"
root_cause: generated_code_referenced_properties_by_bare_name_next_to_a_generated_local
resolution_type: code_fix
severity: high
tags:
  - macros
  - shadowing
  - snapshot-convertible
  - nesting-budget
related:
  - "#716"
---

# A generated local shadows a property of the same name

## Problem

#716 S1a-2a made `@SnapshotConvertible` generate `toSnapshotValue(budget:)`. The new member declares `let inner = try budget.enteringContainer()` and passes `inner` to each property's conversion. The properties were referenced by bare name (`try SnapshotValue.make(from: \(name), budget: inner)`). `ShapeHolder` in the shape matrix has a property named `inner`, so its line read `make(from: inner, budget: inner)`, and the local won. The field went out as the `NestingBudget` struct, through `Mirror`: `{"containersLeft": 31, "hopsLeft": 32, ...}`. It compiled, since `make` takes `Any`. A property named `budget` would have read the parameter in the same way.

## Root cause

A macro's generated body shares its scope with the user's members. A bare identifier resolves to the innermost declaration, so any name the macro introduces (a parameter, a local, a loop variable) hides a user property spelled the same. Before S1a-2a the generated `toSnapshotValue()` had no parameter and no local, so bare names were safe. `toFullSnapshotValue()` already used `self.\(name)`.

## Fix

The generated conversions reference every property through `self.` (`SnapshotConvertibleMacro.generateToSnapshotValueMethod`). `@StateNodeBuilder` already reads its fields through `self._\(name).wrappedValue`. `GeneratedNestingBudgetTests.generatedNamesDontShadowProperties` converts a struct with properties named `inner` and `budget`.

## Prevention

- In generated code, reference user members through `self.`, never by bare name, as soon as the body declares anything of its own.
- When a macro adds a parameter or a local to a member, test it on a type with properties named like each one.
- A conversion that takes `Any` won't catch the mixup at compile time. A round-trip test over real shapes (the shape matrix) will.

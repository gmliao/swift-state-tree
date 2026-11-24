---
module: SwiftStateTreeMacros
date: 2026-11-24
problem_type: gotcha
component: payload-macro
symptoms:
  - "local type cannot have attached extension macro"
  - "a @Payload or @PlainData struct declared inside a test function stops compiling once the macro gains an extension role"
root_cause: swift_refuses_an_extension_macro_on_a_type_declared_inside_a_function
resolution_type: established_pattern
severity: low
tags:
  - swift
  - macros
  - extension-macro
  - testing
  - fixtures
related:
  - "scripts/must-not-compile/payload-local-type.swift"
---

# An extension macro can't attach to a local type

## Problem

`@Payload` gained an extension role, so that every payload is `PlainData` through the same builder `@PlainData` uses. About twenty test fixtures declared their payloads inside the test function. Each one stopped compiling.

## Root cause

Swift refuses the attachment itself: an attached extension macro needs a place at file scope to put the extension, and a type declared inside a function has none. The compiler reports `local type cannot have attached extension macro` at the attribute, before the macro runs, so the macro can't diagnose it or work around it. The member roles of the same macro were fine on local types, which is why the fixtures compiled before.

## Fix

The fixtures moved to file scope, each test's types in a `fileprivate enum <TestName>Fixtures` next to the test, and the test refers to them through that enum. A `private` holder enum failed to compile in this change; `fileprivate` works. A must-not-compile snippet (`scripts/must-not-compile/payload-local-type.swift`) pins the limit with the compiler's message, and the payload docs say a payload can't be declared inside a function.

## Prevention

- Adding an extension role to a macro that users already put on local types is a source break: grep for the attribute inside function bodies (tests, examples, docs samples) before adding it, and name the break in the PR.
- Declare macro-annotated fixtures at file scope from the start.

---
title: "An extension macro's role owns the conformances it declares"
module: SwiftStateTreeMacros
date: 2026-11-25
problem_type: gotcha
component: snapshot-convertible-macro
symptoms:
  - "type 'X' does not conform to protocol 'PlainData' on a @StateNodeBuilder @SnapshotConvertible struct"
  - "a conformance the type's protocol already implies goes missing once a macro's extension role declares it"
root_cause: the_compiler_leaves_a_conformance_named_in_an_extension_role_to_the_expansion_even_when_another_protocol_implies_it
resolution_type: code_fix
severity: medium
tags:
  - swift
  - macros
  - extension-macro
  - conformance
  - plain-data
related:
  - "scripts/must-not-compile/state-beside-snapshotconvertible-compiles.swift"
  - "Notes/solutions/2026-11-24-an-extension-macro-cannot-attach-to-a-local-type.md"
---

# An extension macro's role owns the conformances it declares

## Problem

`@SnapshotConvertible`'s extension role gained `PlainData`, so that a nested value type it marks can be stored in state. `StateNodeProtocol` refines `PlainData` in the same change, and `@StateNodeBuilder` writes the witness as a member. A type with both attributes (GameDemo's `PlayerState`) then failed to compile: it didn't conform to `PlainData`, though `StateNodeProtocol` implies it and the witness was there.

## Root cause

An extension role lists the conformances the macro may add. The compiler passes the macro those of them the type doesn't state in its own declaration, in `protocols`. A conformance implied by a refining protocol isn't stated, so `PlainData` arrived in `protocols`. Once it is there, the compiler leaves that conformance to the expansion: when the expansion writes no extension for it, the type doesn't get it, the implied one included. `@SnapshotConvertible` wrote nothing for `PlainData` beside `@StateNodeBuilder` (the member is the witness), so the conformance went missing. `swiftc -dump-macro-expansions` on a one-file probe showed the expansion without the extension. Seen with Apple Swift 6.4.2.

## Fix

Beside `@StateNodeBuilder`, `@SnapshotConvertible` writes an empty `extension T: SwiftStateTurns.PlainData {}` when `PlainData` is in `protocols`, and no checks of its own. A macro test pins the expansion (one `_plainDataCheck`, the member), and a must-not-compile snippet with `expect: compiles` builds the two-attribute type.

## Prevention

- When a macro's extension role names a conformance, the expansion must write it whenever it is in `protocols`, even if another attribute or a refining protocol would provide it. Write an empty extension when the witness lives elsewhere.
- Test every combination of attributes that adds the same conformance with a compiling type, not only with an expansion golden: the golden shows what the macro wrote, not what the compiler then accepts.

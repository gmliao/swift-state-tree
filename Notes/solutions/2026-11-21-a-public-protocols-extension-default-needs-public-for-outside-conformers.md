---
module: SwiftStateTree
date: 2026-11-21
problem_type: testing_practice
component: must-not-compile
symptoms:
  - "a mutant that restores a removed protocol default still leaves the must-not-compile case refused"
  - "does not conform to protocol even though the extension implements the requirement"
root_cause: non_public_extension_default_does_not_satisfy_an_external_conformer
resolution_type: design_rule
severity: low
tags:
  - testing
  - mutants
  - must-not-compile
  - swift
  - protocol-extension
  - access-control
related:
  - "#546"
---

# A default in a public protocol's extension satisfies outside conformers only when it is `public`

## Problem

L2d-3 (#546) removed three defaults from the public protocol `LandKeeperTransport` and added a
must-not-compile case for each (`scripts/must-not-compile/transport-without-*.swift`). The mutant
check put each default back into `extension LandKeeperTransport { … }` and expected its case to
compile. All three cases still failed with "does not conform to protocol 'LandKeeperTransport'",
so the mutant looked like it proved nothing.

## Root cause

A member of an extension without an access modifier is `internal`, even when the protocol is
`public` (only an extension marked `public extension` makes its members public by default). An
`internal` default is invisible to another module, so it can't satisfy the requirement for a type
that conforms there. The snippets are built as their own targets, so the restored default never
applied to them. Inside the module (the test fakes in `@testable` test targets) the same default
does satisfy the requirement, which hides the mistake there.

## Fix

The mutant writes the default as `public func …`, as the extension's other members are. With
that, each case's build succeeds and the script reports the case as compiling when it should not:
the cases are pinned.

## Prevention

- A mutant that restores a public API default copies the access modifier of its neighbours. A
  must-not-compile case that stays refused under its mutant is a mutant to check first, not a pass.
- When a library adds a default for a public requirement, it is `public`; a default left `internal`
  is a default only for the library's own conformers.

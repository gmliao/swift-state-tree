---
title: "Before a plan marks a type `@PlainData`, check each field type's own conformance"
module: SwiftStateTree
date: 2026-11-25
problem_type: gotcha
component: plain-data
symptoms:
  - "a plan says a new package type will be @PlainData and that there is no public API change"
  - "the macro's field check refuses a public leaf type that holds only plain fields but isn't marked"
root_cause: an_unmarked_public_leaf_type_is_not_plain_data_even_when_its_fields_are
resolution_type: design_rule
severity: low
tags:
  - plain-data
  - public-api
  - planning
related:
  - "Notes/plans/2026-11-25-k1b2-failure-ids.md"
  - "#700"
---

**Problem.** The K1b-2 plan (rev 1) made `FailureID` a `@PlainData` struct holding an `Epoch`, and made `ActionTicket` (`Epoch?`) plain, and said "Public API: none". `Epoch` (`Support/SingleFlight.swift`) is a public struct holding one `UInt64`, and it isn't marked `@PlainData`. So the macro's field check would refuse both types.

**Root cause.** `PlainData` is a conformance that the `@PlainData` macro checks field by field, not a structural property. A type whose fields are all plain is still not `PlainData` until it is marked. A public leaf type that needs the mark turns a plan with "no public API change" into one with a public addition.

**Fix.** K1b-2 rev 2 marks `Epoch` `@PlainData` and lists it under Public API as an additive conformance. Review found this in rev 1 before any code was written.

**Prevention.** Before a plan marks a type `@PlainData`, walk its fields down to the leaves, and check each leaf type's declaration for the mark, not just its fields. List every type that needs the mark. For a public one, add it to the plan's Public API section.

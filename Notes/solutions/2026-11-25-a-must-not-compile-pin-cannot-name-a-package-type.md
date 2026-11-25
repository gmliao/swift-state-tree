---
title: "A must-not-compile pin can't name a `package` type"
module: SwiftStateTree
date: 2026-11-25
problem_type: testing_practice
component: must-not-compile-harness
symptoms:
  - "a must-not-compile snippet that uses a package-level type fails to compile whatever the change under test does"
  - "the mutant that should make the snippet compile survives, because the snippet fails on access"
root_cause: the_harness_builds_an_external_package_that_sees_only_public_api
resolution_type: design_rule
severity: medium
tags:
  - testing
  - mutants
  - must-not-compile
  - access-control
related:
  - "Notes/plans/2026-11-25-k1b1-plain-forms.md"
  - "#700"
---

**Problem.** The K1b-1 plan (rev 1) pinned "`ActionHandlerIndex` is not `Codable`" with a must-not-compile snippet: a struct that holds the index and declares `Codable`. Its mutant added `Codable` to the index, and was expected to make the snippet compile.

**Root cause.** `scripts/check-must-not-compile.sh` builds each snippet in an external package against the library product (lines 44–68). An external package sees only the public API. `ActionHandlerIndex` is `package`, so the snippet fails on access before conformance is even checked. It fails with or without the mutant, so it pins nothing.

**Fix.** Pin a property of a `package` type inside the package, in a test target. For "not `Codable`": `#expect(!(ActionHandlerIndex.self is any Encodable.Type))` and the same check for `Decodable`, with a positive control that a `Codable` type in the same test passes the cast. Review found this before any code was written (K1b-1 plan rev 2, MF2).

**Prevention.**
- A must-not-compile snippet may name only public API. Before writing one, check the access level of every type it names.
- The snippet must compile once the mutant is applied. If it would still fail for another reason (access, a missing import), the pin is empty.

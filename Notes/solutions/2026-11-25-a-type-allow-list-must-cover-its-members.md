---
module: PlainDataMacroSupport
date: 2026-11-25
problem_type: bug_class
component: plain-data-attributes
symptoms:
  - "a peer macro on a method or computed property of a state type adds a stored property the PlainData witness doesn't check"
  - "a @PlainData or @Payload type takes another attached macro without a diagnostic"
root_cause: an_allow_list_read_only_the_type_attributes_while_member_macros_also_add_declarations_to_the_type
resolution_type: design_rule
severity: high
tags:
  - macros
  - plain-data
  - allow-list
  - peer-macro
  - soundness
related:
  - "scripts/must-not-compile/state-member-land-attribute.swift"
  - "scripts/must-not-compile/members-allowed-compiles.swift"
  - "#837"
---

# A type's attribute allow list must cover its members too

## Problem

`@StateNodeBuilder` and `@SnapshotConvertible` refused an unknown attached macro on the state type, because such a macro could add members that the PlainData witness never checks. They read only the type's own attributes. A peer macro on a method, an initializer or a computed or `static` property adds its declarations to the same type, and nothing looked there. `@PlainData` and `@Payload` types ran no allow list at all.

## Root cause

Swift attaches a member's peer macro's output to the enclosing type. So "which macros can add members to this type" includes every macro on any of its members, not only those on the type. The check was scoped to the place a reader looks first, the type's attribute list.

## Fix

`PlainDataAttributes` (`Sources/PlainDataMacroSupport/PlainDataAttributes.swift`) holds one rule per macro, and exactly one macro per type runs it. `diagnoseMembers` checks every member that could add declarations (functions, initializers, subscripts, computed and `static` properties, enum cases, typealiases, nested types), inside `#if` clauses too, against a list of built-ins that add none. Stored instance properties stay with the PlainData walk, which already refuses their non-neutral attributes.

## Prevention

- An allow list that guards "what can add members to T" walks every syntax position whose macros expand into T: the type, each member, each `#if` clause. Listing the positions is part of the design, before the names.
- Pin each position with a refusal test, and pin the allowed set with a compiles snippet built from a census of the repository's real attributes, so a new legitimate use fails in CI instead of in a user's build.

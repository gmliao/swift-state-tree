---
title: "A check keyed on an attribute's name must also check the attribute's storage"
module: PlainDataMacroSupport
date: 2026-11-25
problem_type: bug_class
component: plain-data-walk
symptoms:
  - "a state field with a wrapper of the user's own named Internal or Sync compiles while the wrapper holds a class"
  - "a macro trusts @Internal by its spelling and checks only the wrapped value"
root_cause: a_syntactic_check_matched_a_property_wrapper_by_name_and_skipped_its_storage
resolution_type: design_rule
severity: high
tags:
  - macros
  - plain-data
  - property-wrapper
  - spelling
  - soundness
related:
  - "scripts/must-not-compile/state-internal-namesake.swift"
  - "scripts/must-not-compile/state-internal-namesake-inferred.swift"
  - "scripts/must-not-compile/state-internal-namesake-alias.swift"
  - "#834"
---

# A check keyed on an attribute's name must also check the attribute's storage

## Problem

`@StateNodeBuilder` writes the state's `PlainData` witness. It read a field through its wrapper when the attribute's last name was `Sync` or `Internal`, and checked only the wrapped value, `value.x`. A wrapper of the user's own named `Internal` (an honest clash, or `typealias Internal = OtherWrapper`) passed as the library's:
- `@Internal var hits: Int = 0` checked an `Int`, while the wrapper's own storage held a class.
- With no annotation (`@Internal var ref = Ref()`), the walk wrote no line at all, because it relied on the library wrapper's `Value: PlainData` constraint, which a namesake doesn't have.

Nothing else caught it: registration skips `@Internal`, and the lint doesn't reserve the names.

## Root cause

A macro sees spellings, not declarations. The name `Internal` says nothing about which type the attribute resolves to. The walk used the name as proof of the wrapper's identity, then skipped the one value that would show it: the wrapper's storage, `_x`. This is the "read values, not spellings" rule the walk already follows for field types, missed for attributes.

## Fix

For every read-through field, annotated or not, the witness also checks the storage: `SwiftStateTurns.PlainDataCheck.field(value._x)`. The name is built from the identifier without backticks. The library's `Sync` and `Internal` are `@PlainData`, so the line compiles exactly when the storage is plain, and the name match only decides which fields are read through. Three must-not-compile snippets pin a namesake with an annotation, without one, and behind a typealias. The macro tests pin the two lines per field, a qualified spelling and an escaped name.

## Prevention

- When a macro treats an attribute (a wrapper, a macro, a type name) as a known library type, check a value the compiler resolves (the storage, a conformance, a member only the real type has), not only the spelling.
- A fallback that says "the type's own constraint checks the rest" holds only if the type is the one you think it is. Test it with a namesake and with a typealias.
- The same limit applies to the macros beside yours. A macro can't see the members another attached macro adds, so a check that must see every stored property lists the attributes it accepts (#100). Even then, a bare namesake of a listed macro passes, so document that gap where the other unchecked cases are documented.

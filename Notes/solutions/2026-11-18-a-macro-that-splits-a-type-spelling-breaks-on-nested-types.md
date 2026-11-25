---
title: "A macro that splits a type's spelling breaks on nested types"
module: SwiftStateTreeMacros
date: 2026-11-18
problem_type: bug_class
component: state-node-builder
symptoms:
  - "@StateNodeBuilder expansion fails with `expected ',' separator` on a field typed `[[String: Int]]`"
  - "generated helper reads `updateMaps(_ value: Int], forKey key: [String)`"
  - "a typealias for the inner type makes the error go away"
root_cause: type_classified_by_splitting_its_spelling
resolution_type: code_fix
severity: medium
tags:
  - macros
  - swift-syntax
  - type-spelling
  - container-helpers
  - goldens
related:
  - "#582"
  - "#535"
---

# A macro that splits a type's spelling breaks on nested types

## Problem

`@StateNodeBuilder` emits `append`/`update`/`insert` helpers for a container field, so it has to
know whether the field is a dictionary, an array or a set, and what its key and element types
are. It took the type's spelling as a string: "starts with `[`, ends with `]`, contains `:`" was a
dictionary, split at the first `:`; `Dictionary<…>` was split at the first `,`.

A field typed `[[String: Int]]` is an array, but its spelling contains the inner dictionary's
`:`. The macro classified it as a dictionary with key `[String` and value `Int]`, and the
expansion didn't parse. `[(a: Int, b: Int)]` (a tuple label) and
`Dictionary<Pair<Int, Int>, Int>` (a generic argument's own comma) broke the same way.

## Root cause

A type's spelling is a tree written flat. A separator character belongs to whichever node
encloses it, and string tests (`contains`, the first `:` or `,`) can't tell the outer node's
separator from an inner one. Every test-suite field used a flat element type, or a typealias,
so nothing exercised a nested one.

## Fix

`detectContainerType` parses the spelling into a `TypeSyntax` (SwiftSyntaxBuilder's string
initializer, no new dependency) and classifies the node: `DictionaryTypeSyntax`,
`ArrayTypeSyntax`, or an `IdentifierTypeSyntax` named `Dictionary`/`Array`/`Set` with the right
number of type arguments. Key and element types are the child nodes' `trimmedDescription`. An
unused string-based decodability check with the same flaw was deleted.

## Prevention

- In a macro, classify a type from its syntax node, never from its spelling. Keep the
  `TypeSyntax` when you have it; if only a string is at hand, parse it back.
- A macro test for a type-driven branch covers a nested spelling of each shape it matches: a
  container inside a container, a labeled tuple, a generic argument with its own comma. The
  expansion check (`expandCollectingDiagnostics`) fails on any expansion that doesn't parse.
- Add a compiled fixture next to the goldens. A golden proves the text; only compiling it proves
  the generated helpers type-check against the runtime (`Tests/SwiftStateTreeTests/NestedContainerFieldTests.swift`).
- When a mutant edits only the macro target, an incremental `swift build --build-tests` rebuilt
  the plugin but not the files that use it (Swift 6.2.4, Linux): a mutant that swapped key and
  value types still reported `Build complete!`. Touch the fixture file (or build into a fresh
  scratch path) before trusting a compiled fixture's verdict on a macro mutant.

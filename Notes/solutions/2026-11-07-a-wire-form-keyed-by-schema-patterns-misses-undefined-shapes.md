---
module: transport encoding, schema generation
date: 2026-11-07
problem_type: logic_error
component: AtomicLayoutTable, TypeToSchemaConverter
symptoms:
  - "An atomic value (Position2) in a [T]? or [String: [T]]? field is sent keyed while the same value in a [T] field is positional"
  - "The SDK leaves an atomic value as a plain array of numbers in a map of arrays"
  - "A schema definition for Optional<Dictionary<...>> has a 'some' property"
root_cause: wire_transform_driven_by_schema_paths_that_were_never_defined
resolution_type: code_fix
severity: medium
tags:
  - transport
  - atomic-values
  - schema
  - wire-format
  - optionals
related:
  - "Sources/SwiftStateTree/Sync/AtomicLayoutTable.swift"
  - "Sources/SwiftStateTree/SchemaGen/TypeToSchemaConverter.swift"
  - "Tests/SwiftStateTreeTests/AtomicArrayShapesTests.swift"
  - "sdk/ts/src/core/view.ts"
  - "https://github.com/gmliao/swift-state-tree/pull/271"
  - "https://github.com/gmliao/swift-state-tree/pull/278"
---

# A wire form keyed by schema patterns silently misses shapes the schema doesn't define

## Problem

Positional atomic values (#271) are driven by `AtomicLayoutTable`, built from the schema: a value is sent as `[x, y]` only at a path the table has a pattern for. Every in-repo land passed, and the hero-defense bytes test showed the saving. But `[Position2]?` was sent keyed (no pattern), `[String: [Position2]]?` got a wrong pattern (`maybePaths.some.*.*`), and the SDK left `[String: [Position2]]` elements as raw numbers. Nothing failed: a missing pattern means "not atomic", and keyed values still decode.

## Root cause

- SchemaGen converted a collection inside an optional inline and defined only `Optional<...>`, whose `innerType` named a definition that didn't exist. The table follows `innerType` through definitions, so it stopped there.
- SchemaGen took a Mirror sample of every Codable type decodable from `{}`. `Optional<[String: T]>` decodes from `{}` as `.some([:])`, and Mirror reported a `some` property.
- The SDK resolved item types through properties and `$ref`s, not through a definition that is itself an array or a map of inline arrays.

The tests checked the shapes the in-repo lands use; the transform's coverage was never asserted over shapes.

## Fix

- SchemaGen defines an optional collection's inner type under its `innerType` name, and takes no Mirror sample of an `Optional`.
- The SDK resolves item types through collection definitions and inline-array maps.
- `AtomicArrayShapesTests` covers every shape (`[T]`, `[T]?`, `[String: [T]]`, `[String: [T]]?`, `[T]` in an optional struct): the table's patterns, a walk of a populated state's wire form that finds no keyed atomic value, both encoders' round trips, and a fixture the SDK and the CLI read back.

## Prevention

- A transform that applies "where the schema says so" fails open. Assert its coverage over the type shapes, not over the lands that exist: populate every shape, encode, and walk the result for a value still in the old form.
- Share one fixture between the encoder and every decoder (Swift, SDK, CLI), so a shape one side handles and another doesn't fails a test instead of decoding as something else.

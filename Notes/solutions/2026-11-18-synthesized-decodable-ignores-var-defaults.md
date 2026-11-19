---
module: SwiftStateTree
date: 2026-11-18
problem_type: gotcha
component: schemagen
symptoms:
  - "SchemaGen lists a nested struct as an empty object, with no properties"
  - "a struct whose every field has a default doesn't decode from {}"
  - "the record schema fingerprint can't list the fields of <type>"
root_cause: synthesized_decodable_requires_every_key_even_for_var_properties_with_defaults
resolution_type: established_pattern
severity: medium
tags:
  - codable
  - schemagen
  - fingerprint
  - swift
related:
  - "#521"
---

# Synthesized `Decodable` ignores `var` defaults, so a `{}` sample fails

## Problem

SchemaGen reads a type without declared field metadata from a sample instance: it decodes `{}` (or an empty snapshot object) into it and walks the result with Mirror (`TypeToSchemaConverter`). For a plain `Codable` struct this fails even when every property is a `var` with a default value, so the type's schema is an empty object. SchemaGen's output looked fine, but it hid the fields. The record schema fingerprint (#521 D15) hashed such a type as if it had none, so a change to its fields went unseen.

## Root cause

Swift's synthesized `init(from:)` decodes every stored property's key and throws `keyNotFound` for a missing one. A `var`'s default value is used by the memberwise and the default `init()` only, not by the synthesized decoder. A `let` with a default is skipped by the decoder, but then the key is never read, which is a different trap.

## Fix

The converter reports its failed-sample branch to the fingerprint, which refuses the type by name (`SchemaFingerprintError.unbuildableType`), and a land that records is refused at registration. Types that list their fields don't need a sample: `@Payload` for payloads and server inputs, `@SnapshotConvertible` (or a `SnapshotValueDecodable` conformance) for a value inside one. Leaf types whose wire form isn't their stored fields (collections, raw-value types, Foundation scalars, values with their own snapshot conversion) aren't counted as failures.

## Prevention

- Don't rely on `var` defaults to make a `Codable` type decode from a partial object. Write `init(from:)` with `decodeIfPresent` or use a macro that lists the fields.
- A schema built from a sample must say when the sample couldn't be built, not emit an empty object that a field-less type would also produce.

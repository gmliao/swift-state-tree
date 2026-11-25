---
title: "A macro that names a property from `identifier.text` keeps its backticks"
module: SwiftStateTreeMacros
date: 2026-11-18
problem_type: bug_class
component: macros
symptoms:
  - "a keyword property (`` `default` ``) is listed by its macro as \"`default`\", backticks included"
  - "a `CodingKeys` rename of a backticked property isn't matched; the property's own name is used"
  - "SchemaGen, the TS client or a snapshot key names a field differently from its Codable key"
root_cause: swift_syntax_identifier_text_keeps_backticks_of_an_escaped_identifier
resolution_type: code_fix
severity: medium
tags:
  - macros
  - swift-syntax
  - codable
  - schemagen
  - fingerprint
related:
  - "#521"
  - "#604"
---

# A macro that names a property from `identifier.text` keeps its backticks

## Problem

`@Payload` listed a property declared as `` `default` `` in `getFieldMetadata()` under the name "`default`", backticks included. Its `CodingKeys` rename (`case `default` = "d"`) was looked up by that name and never matched. The record schema fingerprint then hashed the Swift name instead of the wire key, so a change to the key went unseen, and SchemaGen's property and `required` entries, which the TS client maps positional values to, carried the backticks. A runtime test of the wire keys (#604) found it. The macro expansion tests hadn't, since none declares a keyword property.

## Root cause

For an escaped identifier, swift-syntax's `IdentifierPatternSyntax.identifier.text` is the token's source text, backticks included. That's the right spelling for generated code (`self.\(name)`), and the wrong one for a string the macro emits as a name. A synthesized `Codable`'s key is the bare name.

## Fix

`PayloadMacro.PropertyInfo.wireName` drops the backticks. String literals use it: field metadata, the wire-key lookup and `_payloadFieldForms`. Generated code keeps `name`. `SnapshotConvertibleMacro` had the same bug in its field metadata, its leaf paths and its snapshot keys, and gets the same fix. A backticked property under `@StateNodeBuilder` doesn't compile: the macro builds identifiers from the name (`_\(name)`, `_syncPolicy_\(name)`), so it can't misname a field silently.

## Prevention

- In a macro, keep two spellings of a property: the source spelling for generated code, and the name without backticks for every string literal (metadata, keys, diagnostics).
- Test a macro with a keyword property (`` `default` ``, `` `case` ``), at runtime as well as by expansion: an expansion test only shows what was expected.

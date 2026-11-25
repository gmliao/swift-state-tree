---
title: "A visited set keyed by a lossy name merges distinct types"
module: SwiftStateTree
date: 2026-11-20
problem_type: bug_class
component: schema-generation
symptoms:
  - "two types named the same in different scopes share one schema definition"
  - "a generated client encodes one type with another type's fields"
  - "a second type is silently skipped as already visited"
root_cause: a_visited_set_and_a_definition_table_keyed_by_a_name_that_is_not_unique_per_type
resolution_type: design_rule
severity: medium
tags:
  - schema
  - type-names
  - visited-set
  - codegen
  - registration
related:
  - "#602"
  - "#689"
---

# A visited set keyed by a lossy name merges distinct types

## Problem

The schema walk keyed its definitions and its visited set by `String(describing: type)`, which drops the scopes a type is nested in: `A.Item` and `B.Item` are both `Item`. A second type with the name was skipped as already visited, and its `$ref` pointed at the first type. A payload replaced an earlier definition under its name. The multi-land merge kept the first land's definition "since they should be identical". `AtomicLayoutTable` runs the same walk for the live state, so the wrong could reach the positional encoding at run time, not only the generated files (#602).

## Root cause

A key that isn't unique per value stands for more than one value. A visited set built on such a key turns "seen this type" into "seen this name". The recursion guard then hides the second type instead of reporting it. Nothing failed, because each step did what its key said.

## Fix

#689 keeps the short names, since they are the generated artifacts' names. The walk notes each type it defines under its name before the visited check, in a task-local recorder that each entry point binds: `SchemaExtractor.extract`, `SchemaGenCLI.generateSchema` (once for all its lands), `AtomicLayoutTable.build` and a registration row for the state. Distinct types, by `ObjectIdentifier`, under one name throw an error that names both full names. The across-lands check compares type identity, not definitions: the same type reached through fields with different policies gets different definition metadata, and would be refused by a comparison of definitions.

## Prevention

- A dedup set, cache or table keyed by a derived name (a short type name, a path without its escapes, a wire name) needs the question "can two distinct values give one key?" answered. If they can, record the identity next to the key and check it where the key is first used. Do the check before any early return on "already seen".
- A merge that keeps the first entry "because they should be identical" is an unchecked assumption. Check it, by identity where there is one.
- Test it with two distinct values that give one key, and with one value reached through several paths (two fields, a collection, an optional, two lands), so the check refuses the first case and accepts the second. For the mutants: move the note after the visited check, and record per part instead of across the merge.

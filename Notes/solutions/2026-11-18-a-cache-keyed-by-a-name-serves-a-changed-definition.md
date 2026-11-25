---
title: "A cache keyed by a name serves a changed definition the old value"
module: SwiftStateTree
date: 2026-11-18
problem_type: bug_class
component: record-schema-fingerprint
symptoms:
  - "a replay against a changed land definition passes the schema fingerprint check"
  - "a test that replays against a land without one of its handlers passes a check it should fail"
  - "the fingerprint of a land is the same before and after a change to its types, in one process"
root_cause: cache_key_names_the_value_instead_of_capturing_its_inputs
resolution_type: design_rule
severity: high
tags:
  - caching
  - fingerprint
  - replay
  - testing
related:
  - "#521"
---

# A cache keyed by a name serves a changed definition the old value

## Problem

The record schema fingerprint (#521 D15) was first cached per process under a key of the land's state type and its `id` string. Two definitions with the same state type and `id` but different handlers (the live land, and a test's land without one server input) then got the same fingerprint, whichever was computed first. A replay against the changed land passed the check that exists to refuse it.

## Root cause

The value was computed from the whole definition: its state type, actions, events and server inputs. The key held only two of those inputs, the two that *name* the land. A name is stable across exactly the changes the value is meant to detect. Production rarely builds two definitions under one name in one process, which hid the gap, but tests do it all the time, and the cache made the result depend on which test ran first.

## Fix

The fingerprint is stored on the definition value (a reference held by `LandDefinition`, shared by its copies). Registration computes it once, and the land's keepers, built from the same value, read it there. A definition built again computes its own. The test that replays against the land without its server input now expects the mismatch.

## Prevention

- A cache key must capture every input the value is computed from, or the cache must live on the input itself. A name, an ID or a type identifier is a key only when the value depends on nothing else.
- When a check exists to tell two versions apart, test it with two versions that share every name: same type, same ID, one change. That test fails against a name-keyed cache, whatever the test order.

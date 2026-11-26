---
title: "A bridging cast can merge keys before your check: an NSDictionary keeps two spellings that [String: Any] equates"
module: SwiftStateTree
date: 2026-11-26
problem_type: logic_error
component: canonical-messagepack
symptoms:
  - "a duplicate-key check never fires for a map built by JSONSerialization or NSMutableDictionary"
  - "an encoded map has one entry fewer than the NSDictionary it came from, with no error"
root_cause: the_check_ran_on_the_swift_dictionary_after_the_bridging_cast_had_merged_equivalent_keys
resolution_type: code_fix
severity: medium
tags:
  - foundation
  - bridging
  - unicode
related:
  - "#805"
  - Notes/solutions/2026-11-26-a-check-inside-a-recursive-function-costs-stack-at-every-level.md
---

# A bridging cast can merge keys before your check: an NSDictionary keeps two spellings that [String: Any] equates

## Problem

#805 made canonical MessagePack refuse a map that holds two keys `String ==` equates (an NFC and an NFD "é", or "K" and U+212A). Review found that the `AnyCodable` paths cast their base `as [String: Any]` before the map reaches the check. A probe on macOS:

```text
JSONSerialization NSDictionary count: 2   (both spellings)
as [String: Any] count: 1                 (one value kept, no error)
NSMutableDictionary K/Kelvin count: 2, as [String: Any] count: 1
```

So a map from `JSONSerialization`, or one built by hand as an `NSMutableDictionary`, was written with one of its two values silently dropped.

## Root cause

`NSDictionary` compares `NSString` keys literally, by their UTF-16 code units, so the two spellings are two entries. Bridging to a Swift `Dictionary` re-keys by `String`, whose `==` and hash use canonical equivalence, so the second entry overwrites the first. The check only ever saw the merged Swift dictionary.

## Fix

Before trusting the cast, check whether the base is an `NSDictionary` (`type(of: base) is NSDictionary.Type`, one type check for a Swift dictionary). If the cast's count is lower than the `NSDictionary`'s, find the merged key from `allKeys` with the same equivalence check, and refuse it (`AnyCodable.keyMergedByBridging`). On the generic path, `AnyCodable.encode(to:)` does this only under the canonical encoder, which marks itself in `userInfo`. Other encoders, the JSON wire's among them, keep the cast's map as before.

## Prevention

- A check on "what the value holds" must run before any conversion that can change it: a bridging cast, a `Dictionary(uniqueKeysWithValues:)`, a decode into a type with a weaker equality.
- When keys can come from Foundation (`JSONSerialization`, `NSDictionary`, `UserDefaults`, plist decoding), test with a Foundation container, not only with a Swift literal.

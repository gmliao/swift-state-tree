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
  - "#479"
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

Review's second round found the type check itself behind a cast that unwraps: `as? [String: Any]` looks through `Optional` levels, `type(of:)` doesn't. An `NSDictionary?` in an outer map (`["x": opt as Any]`) reached the check as `Optional<NSDictionary>`, failed `is NSDictionary.Type`, and was written merged. The check now peels the `Optional` levels first (`NestingOptionalPayload`, as `SnapshotValue.unwrappingOptionals` does for #716). This is #479's class again: a `type(of:)` guard behind an `as?` cast that unwraps.

**Limits.** The check covers what the cast can hand it.
- On Darwin, `AnyHashable(ns)` of such an `NSDictionary` traps in the caller's code, before any value reaches `AnyCodable` (#927). `NSDictionary`'s `AnyHashable` form is `self as! [AnyHashable: AnyHashable]`. For a key type other than `String`, the stdlib's forced bridge inserts through `_DictionaryBuilder`, which traps on the duplicate: `Fatal error: Duplicate keys of type 'AnyHashable' were found in a Dictionary`. A `String`-keyed cast inserts by subscript and merges, which is the case this check catches. An exit-test probe on the macOS CI job (#970, run 46105418529) found the trap at `AnyHashable(ns)`, before the cast: its child printed the mark after building the dictionary, and none after `AnyHashable(ns)`. The cast `AnyCodable` runs, on the dictionary itself, gave one entry and no trap. The earlier note placed the trap in the cast, because a probe evaluated `AnyHashable(ns)` as the cast's argument.
- In swift-corelibs-foundation, an `NSMutableDictionary` stores its keys in a Swift dictionary whose `NSString` keys hash their UTF-16 literally but compare by `String ==`. Inserting the second spelling merges it, keeps both, or traps (`Duplicate keys of type 'NSObject'`), depending on the hash seed: a Linux mutant run trapped in about 1 process in 8.
- The corelibs bridge of an outer `NSDictionary` or `NSArray` also converts its children eagerly.

So the tests that build a two-spelling `NSDictionary` are enabled only on Darwin (`#if canImport(Darwin)` decides their `.enabled(if:)` predicates). A runtime probe of "does this platform keep both?" would itself do the insert that can trap.

## Prevention

- A check on "what the value holds" must run before any conversion that can change it: a bridging cast, a `Dictionary(uniqueKeysWithValues:)`, a decode into a type with a weaker equality.
- A guard on `type(of: x)` next to an `x as? T` sees a different value when the cast unwraps (`Optional`, and on Darwin bridging): unwrap first, then check the type of what the cast saw. Test the `Optional`-boxed shape.
- A test fixture that relies on platform Foundation behavior must not probe it at runtime when the probe can trap: decide it at compile time, and say why in a comment.
- When keys can come from Foundation (`JSONSerialization`, `NSDictionary`, `UserDefaults`, plist decoding), test with a Foundation container, not only with a Swift literal.

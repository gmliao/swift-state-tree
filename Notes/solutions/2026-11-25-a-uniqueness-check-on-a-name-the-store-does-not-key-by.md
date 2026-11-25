---
title: "A uniqueness check on a name the store doesn't key by"
module: SwiftStateTree
date: 2026-11-25
problem_type: bug_class
component: resolver-registration
symptoms:
  - "two resolvers in one declaration pass the duplicate check and write one output"
  - "a skipped (nil) resolver's handler slot reads another resolver's output"
  - "Price and PriceResolver both store their output as price"
root_cause: uniqueness_checked_on_a_name_the_store_derives_its_key_from
resolution_type: design_rule
severity: medium
tags:
  - resolver
  - registration
  - uniqueness
  - storage-key
  - naming
related:
  - "#769"
  - "#825"
---

## Problem

R1 of #769 refused two resolvers of one base type in one declaration, because the record names each output by its type. The check compared base type names (`Price`, `PriceResolver`). The store doesn't key by that name: an output is stored under `convertResolverTypeToPropertyName(name)`, which drops a `Resolver` suffix and lowercases the first letter. So `Price` and `PriceResolver` passed the check and both wrote `price`. Which one survived depended on completion order, and a slot whose own value was skipped (`nil`) read the other resolver's output: wrong data in the handler, with no error.

The `ContextResolver` groups (CanJoin, OnJoin, OnLeave) had the same hole before R1, without any check.

## Root cause

The check and the store used two different names for one thing, and the map from the first to the second isn't one-to-one. A uniqueness check is only as strong as the key it compares; two inputs that differ in the checked name can still collide in the stored one.

## Fix

The check compares the storage key (`ResolverExecutor.outputName(forBaseTypeName:)`), the same function the executors and the handler's lookup use, and the refusal names both types and the shared key (#825 round 1). The `ContextResolver` groups get the same check through `ResolverOutputNaming`.

## Prevention

- Check uniqueness on the exact key the store writes, computed by the same function. If the store normalizes (case, a suffix, a prefix, Unicode form), the check must normalize the same way.
- Regression test with two inputs that differ before the normalization and collide after it, one of them on the path that would read the other's value (here a skipped slot).

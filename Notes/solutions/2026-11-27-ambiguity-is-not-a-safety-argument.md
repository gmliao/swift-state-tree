---
title: "\"Ambiguity will reject it\" is not a safety argument: overload ranking resolves subtype-related candidates silently"
module: SwiftStateTreeTurns
date: 2026-11-27
problem_type: design_pattern
component: plain-data-macro
symptoms:
  - "a relaxed macro check is argued safe because the misuse \"fails to compile as ambiguous\""
  - "the misuse compiles in one declaration order and fails in the other"
root_cause: overload_ranking_picks_the_more_specialized_candidate_instead_of_reporting_ambiguity
resolution_type: design_decision
severity: medium
tags:
  - macros
  - plain-data
  - if-config
  - overload-resolution
  - soundness
related:
  - "#797"
  - "#933"
---

## Problem

`@PlainData` refuses an enum whose case name repeats, because its expansion checks each case's payload with one line per case, `if case let .name(v0) = value { … }`, and a repeated name can't tie a line to its case. #797 asked to allow a name repeated across separate `#if` blocks that are never active together. The macro can't evaluate the conditions, so #933 argued that the relaxation was sound or loud. If both blocks were active, the two declarations would make each per-case pattern ambiguous, and the expansion would fail to compile. The plan's probes (Int against String, a struct against a struct, a protocol a payload conforms to) all came out ambiguous or failed the check.

## Root cause

Ambiguity is only reported when overload resolution has no best candidate. With subtype-related payloads it has one:

```swift
protocol R {}                    // not PlainData
protocol P: R, PlainData {}
enum Mode { case fast(bad: any R); case fast(good: any P) }
if case let .fast(v0) = value { check(v0) }   // the line for `bad`
if case let .fast(v0) = value { check(v0) }   // the line for `good`
```

This compiles (`swiftc -typecheck`, Swift 6.4.2). Ranking prefers the more specialized `any P`, so both lines bind the `good` case, and `bad: any R`, which isn't plain data, is never checked. Declared in the other order, the pair binds `any R` and fails. So "fails to compile" depended on the ranking and on the declaration order, not on the misuse.

## Resolution

#933 was closed unmerged. Main's rule stays: a case name may not repeat anywhere in a `@PlainData` enum, `#if` blocks included, and #797 was closed as refused by design. The alternative was labelled per-case patterns (`if case let .fast(bad: v0)`), which tie a line to its case. That only works when every declaration carries distinguishing labels, it changes the expansion, and it needs its own probes. It wasn't worth it for #797's convenience.

## Prevention

- Before you rest a safety argument on "the compiler rejects it as ambiguous", probe the shapes that overload ranking resolves:
  - subtype-related existentials (`any R` against `any P` with `P: R`);
  - a class against its subclass;
  - generic against concrete;
  - an optional against its wrapped type.
- Probe each pair in both declaration orders.
- A probe table that only holds unrelated types (Int and String) shows that ambiguity can happen. It doesn't show that ambiguity always happens.
- Prefer a check that fails by name (a macro diagnostic) to one that relies on the type checker happening to fail.

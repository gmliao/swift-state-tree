---
title: "A depth limit checked after the tree is built bounds nothing"
module: SwiftStateTree
date: 2026-11-24
problem_type: bug_class
component: canonical-messagepack-codec
symptoms:
  - "SIGBUS (stack overflow) while encoding or decoding a value that is within the depth limit"
  - "a replay or a server input apply crashes on a deep payload in a debug build on macOS"
  - "the backtrace repeats AnyCodable.encode / CanonicalNodeEncoder.encode / Array.encode"
root_cause: depth_limit_checked_after_recursion_and_type_erased_codable_costs_kilobytes_per_level
resolution_type: code_fix
severity: high
tags:
  - stack-overflow
  - depth-limit
  - recursion
  - anycodable
  - codable
  - debug-build
  - darwin
related:
  - "#936"
  - "#802"
  - "#803"
  - "#716"
  - "#362"
---

## Problem

`CanonicalMessagePack` refuses a value nested deeper than `maxDepth` (128). The encoder first built the whole node tree, recursing through each value's `Encodable` conformance, and only the writer counted the depth. So the limit bounded what was written, not how deep the encoder recursed.

A replay test with a server input 129 levels deep killed the test process with SIGBUS on macOS. A record whose input was within the limit could crash replay too.

## Symptoms

- In a debug build, on Darwin's 524 KiB cooperative-pool thread, encoding an `AnyCodable` tree of nested maps took about 4.3 KB of stack per level. At 128 levels that is 601 KB, more than the whole thread. Its decode took 551 KB.
- Every server input decode goes through this path. `ServerInputCodec.decode` encodes the recorded `AnyCodable` and decodes it back, at a live apply and in replay. So a live input near the limit had the same exposure.

## Root cause

Two things combine:

1. **The limit was checked after the recursion it was meant to bound.** A check in the writer or after parsing protects only the stages after it. Every recursive stage before the check is unbounded. That includes a value whose own `encode(to:)` recurses, which never reaches the check at all. `Notes/solutions/2026-11-18-a-parsers-depth-limit-isnt-the-pipelines.md` is the same shape on the read side.
2. **A type-erased `Codable` wrapper costs several frames per level.** Each `AnyCodable` level runs a long chain of calls:
   - `AnyCodable.encode(to:)`;
   - a single-value container;
   - the encoder's generic entry, with its type checks;
   - `Array.encode(to:)` or `Dictionary.encode(to:)`;
   - an unkeyed or keyed container;
   - the next `AnyCodable`.

   In a debug build, each of those frames is large. A limit that looks generous in levels can still overflow the stack.

## Fix

**The bound is checked on the way down** (serde_json's `recursion_limit` and Go's `encoding/json` work the same way):
- `CanonicalNodeEncoder.encode` refuses a value under more than `maxDepth` coding-path keys before it recurses. That value would sit inside more than `maxDepth` containers, which the writer refuses anyway, so no accepted value changes.
- `nestedContainer`, `nestedUnkeyedContainer` and `superEncoder` check the same bound. They can't throw, so past it they record the error for the end of the encode and hand out a container over a detached slot. A value that descends through nested containers alone, never through `encode(_:)`, can't build a tree past the bound either.
- An `AnyCodable` holding an `AnyCodable` is unwrapped in one loop: such a chain recursed at one coding path, where no depth count sees it.
- A 1000-level value now stops at level 129 and never reaches its bottom.

**`AnyCodable` takes direct paths:**
- On encode, `encodeAnyCodable` with `AnyCodableShape`, which takes `AnyCodable.encode(to:)`'s cases in its order. On decode, `anyCodableBase`, which takes `AnyCodable.init(from:)`'s attempts in its order.
- The casts live in non-recursive `@inline(never)` helpers, so the recursive frames hold containers only.
- At 128 levels, encode takes 194 KB and decode 285 KB. Most of the decode is the reader, which both paths share.
- A differential test checks that the bytes, values and error texts equal the generic path's.

## Prevention

- **A depth limit must be checked by every stage that recurses**, at the point where it descends. When a review sees a limit, it asks: which stages run before the check, and do they recurse?
- **Every way down passes the same counter**, as a recursive-descent parser counts on every descent. In a `Codable` encoder, the ways down are `encode(_:)` and also the nested-container and super-encoder calls, which don't throw. A check on `encode(_:)` alone left a value that descends by nested containers unbounded.
- **Measure the stack per level for every recursive stage at the limit,** on the smallest supported stack: Darwin, debug, a 524 KiB pool thread. Measure on an 8 MiB thread, with a probe that notes the deepest stack address (`CanonicalMessagePack.stackProbeForTesting`). Never measure by letting the pool thread overflow.
- **Pin the result with a stack-budget test** (`CanonicalAnyCodablePathTests.stackBudgetAtTheLimit`), plus a relative check against the generic path, so that a regression fails a test instead of crashing the process.
- **A fast path that replaces a generic `Codable` path needs a differential test against it**, over fixtures that reach every case and its order: `NSNumber` kinds, `Bool` before `Int`, `Int` before `Double`, the `Encodable` fallback, and errors. Keep a debug-only switch to the generic path for that test (`anyCodableGenericForTesting`).
- **A non-throwing refusal must still advance the progress the caller observes.** A refused nested container in an unkeyed container is detached, but it must still count, in `count` and in the next position's key. Otherwise an `encode(to:)` that loops until `count` reaches a target never returns, and the recorded error is never thrown (#809).
- **On the Mac, run deep cases only on an 8 MiB Foundation thread or a task executor on one**, behind a check that the work runs there. Hand-made stacks and unbounded recursion probes go to a Linux worker first.
- **A test helper that hands work to a `Thread` must be `Sendable`-clean for Linux.** In swift-corelibs-foundation the thread's block is `@Sendable`, but the Mac's Foundation doesn't mark it. So capturing a non-`Sendable` closure compiles on the Mac and fails in every Linux CI job. Capture a box (`@unchecked Sendable`) that holds the work and its result, and let the caller wait on a semaphore, so nothing is shared at once. Neither the Mac test run nor pre-push catches this; only a Linux build does.
- The decode differential found an older nondeterminism. A map holding two keys that `String` equates (an NFC and an NFD spelling) decodes into a dictionary with either value, depending on the map's iteration order. Neither path fixes that order (#805). Such a map has no place in a differential, which compares two decodes, so it has its own test. A related replay divergence on payload keys is #806.

**Correction (#936).** This entry first quoted the pool thread's stack as 544 KiB, the size of its VM region as a crash report names it. `pthread_get_stacksize_np` reports 524 KiB (536,576 bytes) down to the guard page. A VM-region query on a pool thread in #936 shows the 544 KiB region also holding 20 KiB above the stack's top. The measurements here were taken on that thread and stand; only the figure changed.

---
title: "A Foundation class cast bridges a Swift collection eagerly on Linux"
module: SwiftStateTree
date: 2026-11-21
problem_type: gotcha
component: state-conversion
symptoms:
  - "an exit test passes on macOS and its child crashes (SIGSEGV) on Linux CI"
  - "a nesting limit refuses a deep value, yet the process still overflows its stack on Linux"
  - "a conversion is quadratic in depth on Linux only"
root_cause: foundation_class_cast_bridges_collections_eagerly_on_linux
resolution_type: code_fix
severity: high
tags:
  - linux
  - cross-platform
  - foundation
  - bridging
  - dynamic-cast
  - stack-overflow
  - nesting
related:
  - "#936"
  - "#716"
  - "#735"
---

## Problem

#735's exit test converts 100 000 nested `[Any]`, and the nesting budget refuses it at 33 containers. On macOS the child exits cleanly. On Linux CI the child crashed (SIGSEGV), although the conversion itself recursed only 33 levels.

## Root cause

`SnapshotValue.make` checked `value is NSNull` on every value that no earlier cast matched, and a nested `[Any]` reached that check at each level. The two platforms run this cast differently:

- **Linux:** swift-corelibs-foundation answers a cast of a Swift `Array` to a Foundation class by bridging the array to `NSArray`, element by element. A nested `[Any]` is bridged all the way down, so the cast recursed through the whole value before it answered "no".
- **macOS:** the Array-to-NSArray bridge is lazy, so the same cast is O(1).

The recursion sits in Foundation, which is prebuilt. So debug and release crash at the same depth: 384 levels on a 524 KiB thread, 6144 on 8 MiB (#716, S0 diagnostic run s0-716c). Each level bridged the rest of the value again, so the time was quadratic too.

## Fix

The check became a metatype test, `Swift.type(of: value) is NSNull.Type`, which never touches the value. A real `NSNull` still matches. A Swift `nil` never reaches the test, because `make` unwraps `Optional`s first.

## Prevention

- In code that receives arbitrary values (`Any`) and may see deep or attacker-shaped data, don't cast a value to a Foundation class (`is NSNull`, `as? NSNumber`, `as? NSString`, and so on). Test the dynamic type through its metatype instead.
- A cast that fails can still do work proportional to the value: Optional unwrapping in the runtime (#735's unwrap loop) and collection bridging on Linux both do. Treat every failing cast on an `Any` as possibly deep.
- Depth tests need Linux runs. macOS passing says nothing about bridging, and the Mac never runs overflow cases (`2026-11-21-an-in-process-depth-test-sized-from-linux-overflows-the-mac.md`).

**Correction (#936).** This entry first quoted the pool thread's stack as 544 KiB, the size of its VM region as a crash report names it. `pthread_get_stacksize_np` reports 524 KiB (536,576 bytes) down to the guard page. A VM-region query on a pool thread in #936 shows the 544 KiB region also holding 20 KiB above the stack's top. The measurements here were taken on that thread and stand; only the figure changed.

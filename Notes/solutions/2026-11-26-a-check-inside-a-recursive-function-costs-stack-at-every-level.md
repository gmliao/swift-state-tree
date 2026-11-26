---
title: "A check added inside a recursive function costs stack at every level: put it out of line"
module: SwiftStateTree
date: 2026-11-26
problem_type: test_failure
component: canonical-messagepack
symptoms:
  - "stackBudgetAtTheLimit: decode reached 332112 bytes (budget 320 KiB) after a small check was added to readMap"
root_cause: the_check_s_locals_lived_in_every_recursive_frame_in_debug_builds
resolution_type: code_fix
severity: medium
tags:
  - stack
  - recursion
  - debug-build
related:
  - "#805"
  - "#802"
  - Notes/solutions/2026-11-24-a-depth-limit-checked-after-the-tree-is-built-bounds-nothing.md
---

# A check added inside a recursive function costs stack at every level: put it out of line

## Problem

#805 added an equivalent-key check to `CanonicalReader.readMap`, which recurses once per nesting level. The check ran after the map's entries were read, inline, with an optional `String` result and a generic call. At the depth limit (128 levels) the decode's stack reach went from 315,728 B to 332,112 B. That is over the test's 320 KiB budget (`stackBudgetAtTheLimit`), even though the check itself runs only once per map, after its children return.

## Root cause

A debug build gives each local and temporary its own stack slot, for the whole frame. The check's locals sat in every `readMap` frame, all 128 of them, not only in the frame that ran the check: about 130 B more per level.

## Fix

Move the check into its own `@inline(never)` function (`CanonicalKey.refuseEquivalentDuplicates(in:)`), so the recursive frame makes one throwing call and holds none of the check's locals. The reach went to 321,872 B: +6 KB in all, 48 B per level.

## Prevention

- Before adding code to a function that recurses per level of input (a reader, a writer, a tree walk), check the stack-budget test for that path. Put new work in an out-of-line helper.
- A budget test's doc comment records measured numbers. Re-measure them when they're touched: here the comment said 285 KB, while main measured 316 KB, leaving less margin than it claimed.

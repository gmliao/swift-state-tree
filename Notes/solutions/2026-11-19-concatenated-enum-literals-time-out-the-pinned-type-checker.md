---
title: "Array literals of enum cases joined with `+` time out the pinned type checker"
module: Tests, toolchain
date: 2026-11-19
problem_type: build_failure
component: differential-harness-scenarios
symptoms:
  - "the test target builds locally and fails on CI's pinned toolchain"
  - "error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions"
root_cause: pinned_type_checker_times_out_on_concatenated_array_literals_of_enum_cases
resolution_type: established_pattern
severity: medium
tags:
  - toolchain
  - type-checking
  - ci
related:
  - "#555"
  - "#654"
---

# Array literals of enum cases joined with `+` time out the pinned type checker

## Problem

The differential harness builds a scenario's steps as `[DiffStep]`: enum cases with implicit-member syntax (`.join("A", player: "pa")`), some with trailing closures. `syncCycleRow` joined the shared steps and its parameters as one expression: `[...] + beforeBump + [...] + underHold + [...]`. Adding one more `+ [...]` term was enough. macOS with Swift 6.3 compiled it. CI on the pinned toolchain (Swift 6.2.4, Linux) failed in every build job:

```
DiffScenarios.swift:66:5: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
```

## Root cause

In each `[...]` term, every `.case(...)` element and every closure is resolved against the overloads of `+`: `Array + Array`, `Array + Sequence`, `Sequence + Array`, and others. The search grows with the number of terms and elements, and implicit members give it no type to start from. The 6.2.4 type checker gives up where 6.3 doesn't. This is the reverse of [a test-argument literal that the pinned toolchain type-checks and a newer one times out on](2026-11-17-pinned-toolchain-type-checks-what-local-times-out-on.md).

## Fix

Build the list one step at a time from a typed variable: `var steps: [DiffStep] = [...]`, then `steps += beforeBump`, `steps.append(bump)`, and so on. A step that takes a predicate gets a named `@Sendable` function (`isMessagePackCell`) instead of an inline closure (#654).

## Prevention

- Never join more than two array literals of implicit-member enum cases with `+`. Use a typed `var` and `+=` or `append`.
- Give a closure that sits inside a long literal a name, or an explicit parameter type.
- A green local build doesn't show that the pinned toolchain will type-check the file. When you add terms to a long literal expression, watch the PR's CI build jobs, not just the test results.

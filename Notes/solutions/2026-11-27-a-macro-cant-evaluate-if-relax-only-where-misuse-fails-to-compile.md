---
title: "A macro can't evaluate `#if`: relax a refusal only where the misuse still fails to compile"
module: SwiftStateTurnsMacros
date: 2026-11-27
problem_type: design_rule
component: plain-data-macro
symptoms:
  - "@PlainData refuses enum cases that share a base name although they are in separate #if blocks that never compile together"
  - "a macro rule over #if clauses that is either too strict or leaves a build unchecked"
root_cause: syntactic_check_cannot_tell_which_if_blocks_are_active_together
resolution_type: design_rule
severity: low
tags:
  - macros
  - plain-data
  - if-config
  - conditional-compilation
  - soundness
related:
  - "Sources/PlainDataMacroSupport/PlainDataExtension.swift"
  - "#797"
---

# A macro can't evaluate `#if`: relax a refusal only where the misuse still fails to compile

## Problem

`@PlainData` (and `@Payload`, which shares the code) refuses enum cases that share a base name, because the expansion's `if case let .item(v0) = value` can't pick one of them. Clauses of one `#if` were allowed to repeat a name, since only one clause is active in a build. A name repeated across two separate blocks (`#if FLAG … #endif` then `#if !FLAG … #endif`) was refused, though the user wrote them to exclude each other.

## Root cause

A macro sees syntax, not the build's conditions. It knows that the clauses of one block exclude each other, but not whether two separate blocks do: `#if FLAG` and `#if !FLAG` never compile together, `#if compiler(>=5.0)` twice always does. Any rule over separate blocks is a guess about the conditions.

## Fix

The rule was relaxed only after probes showed that the guess can't go wrong silently. Every shape of two active cases with one name fails to compile: in Swift's own redeclaration check (identical signatures, or a case without a payload beside one with a payload), or in the expansion's per-case lines (an ambiguous use, or a one-value pattern that binds a two-value case as a tuple that isn't plain data). So the walk keeps per-list `direct` and `inIf` names, never compares names from separate blocks, and the misuse is loud, only with a less clear message. A must-not-compile snippet pins the loud failure.

## Prevention

- When a syntactic check can't evaluate a condition, relaxing a refusal must be sound or loud: show, with probes over every shape, that the case the check now lets through can't compile in a build where the guess is wrong. Otherwise keep the refusal.
- Write the argument down next to the check, with what it rests on (here, one `if case let` line per case), so a later change to the expansion revisits the rule.
- Pin the loud failure with a must-not-compile snippet, not only the accepted case.

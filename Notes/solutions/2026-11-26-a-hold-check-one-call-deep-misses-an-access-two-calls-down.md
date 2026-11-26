---
title: "A check one call deep misses a model access two calls down a held `inout`"
module: SwiftStateTree
date: 2026-11-26
problem_type: gotcha
component: land-keeper
symptoms:
  - "Simultaneous accesses to 0x…, but modification requires exclusive access"
  - "a function converted to take `inout` model traps in a helper it calls through another helper"
  - "a leftover-access check reports 0, then the debug test suite traps"
root_cause: transitive_access_to_the_held_stored_property_through_an_unconverted_callee
resolution_type: established_pattern
severity: high
tags:
  - exclusivity
  - keeper
  - model
  - inout
  - turns
  - conversion
related:
  - "#700"
  - "2026-11-26-assignment-into-a-struct-field-begins-its-access-before-the-call-on-the-right"
  - "2026-11-19-inlined-class-state-pays-dynamic-exclusivity-checks"
---

# A check one call deep misses a model access two calls down a held `inout`

## Problem

K1b-5a (#700) makes a turn body hold the keeper's model for the whole body: `withTurn` passes `&model` to the body as `m`, and every function the body calls takes `_ m: inout KeeperModel<State>` instead of reading `self.model`. `failLand` was converted this way, with the helpers it calls.

A check looked through each converted function for `model` and for calls to functions whose bodies name `model`. It reported nothing. The full debug test suite then trapped with "Simultaneous accesses … modification requires exclusive access" in tests that end a land through a transport failure.

## Root cause

The trap's chain was `failLand(&model, …)` → `releaseHeldInputsForDrain()` → `dropServerInputsHeldWhileFrozen()`, which reads `self.model`. `releaseHeldInputsForDrain` names no `model` itself, so a check one call deep passed it. While `failLand`'s `inout` access is open, any access to `self.model`, at any depth, overlaps it. `model` is a stored property of an actor (class storage), so the overlap is checked at run time and traps, in release builds too.

## Fix

Convert the whole chain: `releaseHeldInputsForDrain(_ m: inout …)` and `dropServerInputsHeldWhileFrozen(_ m: inout …)`, with callers outside a hold passing `&model`. Make the check transitive over the call graph: a function reaches the model if it names `model` or calls (or reads, for a computed property) a function that does.

## Prevention

- When a function starts holding the model, convert everything it reaches, not only what it calls directly. Find the set with a transitive walk; the model-holds rule does it on SwiftSyntax's tree, by name and argument labels, in `swift test` (`Tests/SwiftStateTurnsMacrosTests/ModelHoldsLintTests.swift`, #881).
- A check keyed by name alone reports false paths. Keep a property and a function of the same name apart (`failure` and `failure(for:)`), and overloads by their argument labels (`currentPlayerServices(of:)` and `currentPlayerServices(of:entry:)`). Skip string text (`reason: "forceShutdown"` named a function), but not its interpolations. Count a bare name as a function value only in an argument position (`map(held)`), not when it is a parameter that shares a member's name. A use after `await` runs after the hold.
- A closure that runs later (`Task { … }`) is outside the hold; a closure called during it (`forEach`, `removeAll(where:)`, `map(held)`) is inside.
- The debug test suite is the proof only for the paths it runs. List the converted functions no test executes, and add a witness for each one where a missed access would trap.

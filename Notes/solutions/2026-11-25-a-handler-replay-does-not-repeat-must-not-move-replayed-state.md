---
title: "A handler replay doesn't repeat must not move replayed state; list each mode's path as its own row"
module: SwiftStateTree
date: 2026-11-25
problem_type: bug_class
component: record-replay
symptoms:
  - "replay diverges after a resolver, CanJoin or the sync handler draws from ctx.random"
  - "a replayed tick handler traps with no RNG in a keeper whose live tick works"
  - "a call-site census finds N handler calls and misses one spelled with optional chaining"
root_cause: shared_state_was_moved_by_code_paths_that_replay_does_not_run
resolution_type: design_rule
severity: high
tags:
  - replay
  - determinism
  - rng
  - census
related:
  - "#700"
  - "#765"
---

## Problem

The land's RNG was a locked class in `services`. Every context and every resolver held the same instance. A draw from anywhere moved it: a resolver (#765), CanJoin, the sync handler. Replay runs none of those, so every later handler draw was shifted, and the state hash diverged.

K1b-3 made the generator keeper state, bound per handler call. Its first call-site census grepped `handler(` and missed `tickHandler?(&state, ctx)`: the reevaluation keeper's tick runs inline in `runTick`, not through `runTickTurn`, the live path. Left unwrapped, a replayed tick's draw would find no generator and trap.

## Root cause

- State that replay reproduces was reachable from code that replay doesn't run.
- One function can take a different path per mode (`runTick` sends a live tick to `runTickTurn` and runs a reevaluation keeper's tick inline), so a census by function name counts one site where there are two.

## Fix

- The generator is keeper state (`landRandom`). Handlers that replay repeats from the record get a service built from it and written back when they return (`withHandlerStep`).
- Handlers that replay doesn't repeat (CanJoin, the sync handler, the drain's three handlers) get a copy that isn't written back.
- `makeContext` removes `DeterministicRngService` from every context's services, so resolvers can't reach one.
- Tests: `LandRandomStepTests`.

## Prevention

- For every piece of state that replay reproduces, list who writes it and check each writer is a handler that replay repeats. A writer outside that list gets a copy or no access.
- A call-site census greps every spelling of the call: `name(`, `name?(`, `try name(`, and the bound form (`if let name { name(...) }`), and lists each mode's path as its own row.

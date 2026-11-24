---
module: SwiftStateTree
date: 2026-11-24
problem_type: bug_class
component: land-dsl-builder
symptoms:
  - "a helper written for another State splices into a land, compiles, and its handlers never run"
  - "registration passes a land whose OnJoin or HandleAction is missing"
  - "a result builder typed by State accepts an array of nodes from anywhere"
root_cause: a_type_erased_builder_input_skips_the_typed_overloads_and_the_consumer_drops_unknown_nodes
resolution_type: design_change
severity: high
tags:
  - result-builder
  - type-erasure
  - land-dsl
  - registration
  - mutant
related:
  - "#771"
  - "#794"
---

# An erased-array builder input reopens the type check

## Problem

#771 typed the land builder by the land's State: `LandDSL<State, Services>` has one `buildExpression` per node type, so a node built for another State doesn't compile. To splice a helper's nodes into a land (and `@Land`'s `body`), D1 added `buildExpression(_ nodes: [LandNode])`. Review found that a helper written under `@LandDSL<LobbyState, NoServices>` and returning `[LandNode]` spliced into `Land("game", using: GameState.self)` and compiled. `LandBuilder` matched `OnJoinNode<GameState>`, `AnyActionHandler<GameState>` and so on, found none of the helper's nodes, and dropped each one at `default: continue`. Registration and the keeper passed. The land ran without those handlers.

## Root cause

Two things combined:
- **The builder input:** `[LandNode]` is an existential array. It carries no State, so the overload that takes it accepts nodes built for any State. The check that the typed overloads give is skipped for exactly the values that came from another builder.
- **The consumer:** `LandBuilder` switched over the node types it knew and ignored the rest. A node of the right kind for the wrong State is a different type, so it fell to `default` with no trace.

## Fix

Both layers (#794):
- **Keep the type across the boundary.** A second `buildFinalResult` returns `LandRules<State, Services>`, a value typed by the builder's State and Services. A helper or an `@Land` body declares that type, and the existing typed `buildExpression(LandRules<State, Services>)` splices it, so another State's helper is a compile error at the splice. `buildExpression([LandNode])` is `@available(*, unavailable, message:)` and names the typed form, so the old spelling gets a pointed diagnostic.
- **Refuse what isn't recognized.** `LandBuilder`'s `default` records `String(reflecting: type(of: node))` in `LandDefinition.unrecognizedNodes`. Registration refuses the land with `LandRegistrationError.unrecognizedNodes`, and a keeper built without registration fails its initialization with it, so any erased path left over can't drop handlers silently.

## Prevention

- A builder typed by a generic parameter takes no input that has lost that parameter: no existential arrays, no `any P`. When values must cross a function boundary, give them a type that carries the parameter (here `LandRules<State, Services>`), and splice it through the typed overload.
- A consumer that switches over node types refuses the ones it doesn't recognize. `default: continue` is the drop site that made the erased path silent.
- Pinned by must-not-compile snippets (`helper-wrong-state.swift`, `land-macro-wrong-state-body.swift`, `helper-services-mismatch.swift`, and `helper-node-array.swift`, which fails to refuse when the `[LandNode]` overload is made available again), and by `ClientEventRegistrationTests.unrecognizedNodesAreRefused`, which fails when `default` goes back to `continue`.
- Same family as [a visited set keyed by a lossy name merges distinct types](2026-11-20-a-visited-set-keyed-by-a-lossy-name-merges-distinct-types.md): an erased key or value loses the identity that the check needs.

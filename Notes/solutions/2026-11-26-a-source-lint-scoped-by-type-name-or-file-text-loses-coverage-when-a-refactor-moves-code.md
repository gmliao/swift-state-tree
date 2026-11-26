---
title: "A source lint scoped by a type name or a file's text loses coverage when a refactor moves code to another type or file"
module: SwiftStateTree
date: 2026-11-26
problem_type: testing_practice
component: land-keeper
symptoms:
  - "a source lint stays green while a refactor moves the code it checks"
  - "a rule's repository test passes with fewer holders or members than before the move"
  - "a new file with the moved code is never read by the lint"
root_cause: lint_scope_by_type_name_and_file_substring
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - lint
  - exclusivity
  - swift-syntax
  - refactor
  - turns
  - callout
related:
  - "#700"
---

# A source lint scoped by a type name or a file's text loses coverage when a refactor moves code to another type or file

## Problem

`ModelHoldsLint` (`Tests/SwiftStateTurnsMacrosTests/ModelHoldsLintTests.swift`) checks the keeper's turn bodies for two rules: a body that holds the model doesn't name the keeper's `model`, and it doesn't call a port outside `callOut`. #700 K1b-5's move takes those bodies off the `LandKeeper` actor and puts them on `extension KeeperModel`, with the side's state on `KeeperTurnSide`. The lint read only:

- `LandKeeper`'s own members (`actor LandKeeper`, `extension LandKeeper`), and
- files under `Runtime/` whose text contains `LandKeeper`.

Every body the move converted dropped out of both rules, and the repository test stayed green. A model extension in a new file that never says `LandKeeper` would not have been read at all. A side method that calls a port, called from a body, wasn't followed either, since side members weren't collected.

## Root cause

The lint's scope named the code's current home, a type name and a word in a file, not what the rules are about: every place that holds the model, and every member such a place reaches. A refactor that moves code keeps the code's meaning but changes its home, so the scope shrinks without any finding.

## Fix

K1b-5 plan §6 C5:

- **Scope by declaration.** A file is read when it declares or extends `LandKeeper`, `KeeperModel` or `KeeperTurnSide` (parsed, not matched as text), anywhere under `Sources/`.
- **Each member has an owner.** A `KeeperModel` method is a holder with `self` as the hold. A `KeeperTurnSide` member is reached from a hold through the side (`side.f()`). A bare name resolves on the body's own type.
- **Ports follow the move.** The port tracker reads `side.attachedTransport`, `….sharedBoundRequester.port`, and a local bound with `??` from one.
- **The call-out on the hold counts** (`m.callOut(…)`, `self.callOut(…)`).

Each rule has a table row in `modelAndSideMembers` and `scopeByDeclaration`. Each row failed with its collection stripped: the model's `self` hold, the side's members, the scope by declaration, the qualified port names, and the coalescing binding.

## A second instance: the values a hold borrows

The rule was written for one borrowed value, the keeper's `model`. `withTurn` also passes the keeper's `turnSide` `inout`, beside the model. When the move put the handler's step scope on the side, the keeper kept a small wrapper, `openStepScope`, that read `turnSide`. `joinDecide`, a body, still called that wrapper under the turn's hold. The lint didn't flag it, since it watched only `model`. The full debug test stopped on a run-time exclusivity conflict instead ("Simultaneous accesses … modification requires exclusive access", in `openStepScope` called from `joinDecide`).

The lint now treats `turnSide` as it treats `model`: a keeper member that names it, or reaches a member that does, under a hold is a finding (`turnSideIsHeld`). The bad call put back in `joinDecide` is caught by the repository test.

## Prevention

- When a refactor moves code that a source lint checks, the same change moves the lint's scope with it. Scope a lint by what the code declares or holds, not by the name of the type or file it lives in today.
- A hold lint watches every value the hold borrows (here `model` and `turnSide`), not only the one it was written for. When a refactor adds a value to what a hold passes `inout`, the lint gets it in the same change.
- A repository test that only asserts "no findings" can't see coverage loss. Pair it with a mutant row per rule on the code's new home: put the violation where the moved code now lives and expect the finding.

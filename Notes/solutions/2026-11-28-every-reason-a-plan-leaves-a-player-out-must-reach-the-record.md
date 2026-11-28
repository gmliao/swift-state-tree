---
title: "Every reason a live plan leaves a player out must reach the record, or replay plans that player anyway"
module: SwiftStateTreeTransport
date: 2026-11-28
problem_type: logic_error
component: sync-output-replay
symptoms:
  - "sync output mismatch at tick 1, output 0 (tick, sequence 2), check: hash, scope: per-player (combined)"
  - "a replay fails only when a player was paused by sync lag"
  - "the recorded perPlayerHashes lack a player that perPlayerUnverified doesn't list either"
root_cause: a_plan_step_dropped_recipients_without_recording_why
resolution_type: code_fix
severity: medium
tags:
  - replay
  - sync-output
  - sync-lag
  - record
related:
  - "#572"
  - "#553"
  - "#531"
---

**Problem.** A replay of a record in which sync lag paused a player (`resyncPending`) failed with a per-player hash mismatch at the first paused round. Live was right: the paused client got no frame, and a resync when its acks came back.

**Root cause.** The live plan drops recipients in more than one place. `classifySyncLag` removes a pending or closing session before anything is planned, so the plan has no per-player entry for a player all of whose sessions are paused. The record listed a player it didn't address in `perPlayerUnverified` only for one reason, the leave's own turn after the sessions ended (#553). The verifier plans every seeded player that the output doesn't list, so it planned the paused player's update and hashed it, and the recorded hash didn't have it.

**Fix.** The plan's digest carries `withheldPlayers`, the players none of whose sessions sync lag kept. The output lists them in `perPlayerUnverified`, the same list the leave case uses. The verifier is unchanged: a player listed there with a verifiable view is neither compared nor staged, and the pause ends in a resync's clear and seed or in a leave's clear. The record format is unchanged too. The result's `perPlayer.unverifiable` counts each skipped scope, so the verdict reads `partial`, not `passed`.

**Prevention.**
- When the replay skips what the server didn't do, list every step of the live plan that removes a recipient, and record each one's effect. A filter added to the plan later is a new reason the record has to carry.
- Test a skip by its count. Assert that the unverifiable count equals the outputs that list the player, and that a control run without the condition passes with nothing listed, so a fix can't pass by skipping everything.
- Records made before such a fix still fail. They hold nothing that says the player was left out, and the replay can't infer it.

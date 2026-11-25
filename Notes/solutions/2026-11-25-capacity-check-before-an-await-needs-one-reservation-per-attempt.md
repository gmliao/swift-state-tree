---
title: "A capacity check before an await needs one reservation per pending attempt, not per key"
module: SwiftStateTree
date: 2026-11-25
problem_type: bug_class
component: land-keeper-join
symptoms:
  - "players.count exceeds maxPlayers after a duplicate login"
  - "a newcomer is admitted while a returning player's old session is being kicked"
  - "a hold or reservation cleared by one login frees the place another login still waits for"
root_cause: capacity_check_not_held_across_await
resolution_type: design_rule
severity: medium
tags:
  - reentrancy
  - reservation
  - max-players
  - duplicate-login
related:
  - "#852"
  - "#862"
---

## Problem

A duplicate login (the same player, a new client) skips the `maxPlayers` check as a reconnection, kicks its old session with `await leave(...)`, and inserts its new entry afterwards. `leave` removes the entry at once and then suspends in the OnLeave resolvers. In that window a newcomer passes the cap, and the returning player inserts without a re-check: `players.count == maxPlayers + 1`.

## Root cause

The capacity check reads `players.count` before an `await`, and the place the returning player is about to take isn't counted while its entry is gone. A first fix held one place per player (a `GenerationTable<PlayerID>`, one epoch per key). Overlapping logins of one player then shared a hold owned by the newest. When the newer login inserted and its entry went away (a disconnect, an OnJoin rollback, a failed kick) while the older one was still in OnLeave, the place freed, a newcomer got in, and the older login inserted: count 3.

## Fix

One reservation per pending attempt: `rejoinReservations: [PlayerID: Set<Epoch>]`, each attempt minting its own epoch from an `EpochCounter`. The cap counts every player with a non-empty set and no entry. An attempt removes only its own epoch, at the insert and on every other exit (`defer`); teardown clears them all, and a draining land refuses a join before the cap check, so a late newcomer gets `landShuttingDown`, not `roomIsFull`.

## Prevention

When a check guards a resource that is taken after an `await`, reserve per attempt, not per key. A per-key table (or a flag) answers "is this key pending" but can't tell whose end it is; a reservation must belong to the attempt that made it, as Colyseus' `_reservedSeats` does for pending joins. Pin the rule with a gated test for each ending order (older first, newer first), a control where the attempt fails, and mutants that clear by key or drop the `defer`: see `Tests/SwiftStateTreeTests/RejoinHoldsPlaceTests.swift`.

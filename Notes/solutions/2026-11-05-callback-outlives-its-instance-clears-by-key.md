---
module: SwiftStateTreeTransport
date: 2026-11-05
problem_type: bug_class
component: session-lifecycle
symptoms:
  - "A reconnected player loses its sync cache, firstSync mark or player slot when the old connection's disconnect is processed"
  - "A newer session gets a diff before its firstSync"
  - "A freed slot is handed to another player while the newer session still encodes with it"
root_cause: keyed_cleanup_from_a_callback_that_outlives_its_instance
resolution_type: design_rule
severity: high
tags:
  - reentrancy
  - reconnect
  - session
  - generation
  - cleanup
related:
  - "#86"
  - "#137"
  - "#146"
  - "#531"
---

# A callback that outlives its instance clears state by key alone

## Problem

`handleDisconnectQueued` cleared per-player state after `await keeper.leave`, keyed by the player alone: the sync cache and firstSync mark, the sync-stream clear marker, `initialSyncingPlayers`, and the player slot (`releasePlayerSlot`). When the player already had another session, for example a re-join admitted while the old connection's disconnect was still queued, the old session's disconnect wiped the state the new session was using (#137).

## Symptoms

- A sync cycle sends the newer session a diff before its firstSync.
- The slot is freed and can be handed to another player while the newer session still encodes with it.

## Root cause

The key (a player ID, a session ID that can be reused on reconnect) names a slot, not an instance. A callback from an earlier instance (a disconnect, a timer, a completion) that arrives after a newer instance took the key acts on the newer one.

## Fix

- #137: clear the state only when no other session of the player remains (`membershipCoordinator.sessionIDs(for:)` is empty), checked after the `keeper.leave` await in the same synchronous segment as the clearing.
- The general tool since #146: a `GenerationTable` (`Sources/SwiftStateTree/Support/Generations.swift`). `issue` starts a new generation of a key, the callback carries the `Ticket` captured when its instance started, and `ifCurrent` runs the act only if that ticket is still current. A ticket from an earlier generation is never current again, also after the key was ended and issued anew.
- The same idea on the transport side (#86): each connection gets a generation, frames are stamped with it, and frames for an ended connection are dropped, so a reconnect that reuses the `SessionID` never gets them.
- A close is an act too (#531): a close decided about one connection and run later (from a Task, behind queued frames, after a join timeout) closed whatever connection held the session ID by then. Each delayed close now carries the generation of the connection it was decided for (`closeSession(_:with:generation:)`, `closeSessionAfterQueuedFrames(_:generation:)`), and the transport drops it when the session's connection is another one.

## Prevention

- Never remove or overwrite keyed state by key alone from a callback that can outlive its instance (`CLAUDE.md` § Reentrancy). Carry a ticket, or check that the instance is still the current one in the same segment as the act.
- A delayed close is a callback that can outlive its instance: pass the connection generation captured when the close was decided, never the session ID alone.
- Test: start instance 1, hold its callback, start instance 2 on the same key, release the callback, and assert instance 2's state is intact.

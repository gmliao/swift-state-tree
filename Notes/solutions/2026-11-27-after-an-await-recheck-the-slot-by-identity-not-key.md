---
title: "After an await, re-check the slot you act on by its identity (a generation), never by its key: the key can hold a different entry"
module: SwiftStateTree
date: 2026-11-27
problem_type: bug_class
component: land-keeper-join-leave
symptoms:
  - "a live player entry whose OnJoin never ran and never will"
  - "a third login during a kick's OnLeave resolvers is taken over as a rejoin"
  - "a pending flag or other per-entry state inherited by the join that replaced the entry"
root_cause: the_segment_after_the_await_looked_the_slot_up_by_key_and_treated_what_it_found_as_the_slot_it_had_checked
resolution_type: code_fix
severity: high
tags:
  - reentrancy
  - aba
  - generation
  - join
  - kick
  - fencing
related:
  - "#860"
  - "2026-11-05-callback-outlives-its-instance-clears-by-key"
  - "2026-11-27-an-input-issued-after-an-await-and-its-undo-drop-as-a-pair"
---

## Problem

A join that finds the player's entry held by another session kicks it: it awaits the old session's leave, whose OnLeave resolvers or input turn can suspend. When it resumes, its insert read `players[playerID] ?? fresh entry` and, finding an entry, took it over as a reconnect (no OnJoin). During the kick's await a third login could find the slot empty and insert its own entry, its OnJoin still pending. The kicking join then took over that entry:
- it kept the pending flag and appended no OnJoin;
- the third join's jobs weren't cancelled;
- the third join, finding its generation gone, dropped its OnJoin as superseded.

The result was a live entry with no OnJoin, and an OnLeave that its own leave would skip.

## Root cause

ABA. The segment before the await checked one entry, and the segment after it acted on whatever the key held. The key was the same, the entry was not.

## Fix

Two identities, each checked where it belongs:
- **The attempt's arrival**, a fencing token. Every join attempt takes a monotonic token at its decision (J2) and records it as the player's latest (`latestJoinArrivals`). The segment after the kick checks it first: a later token means a later attempt arrived, and this join throws `JoinError.superseded`. So the last join to arrive keeps the player, whichever kick returns first. Each attempt removes its own token on every exit if no later one replaced it.
- **The slot's entry**, by generation. The kick request and the kick's leave carry the kicked entry's generation; the leave removes only that entry, so a newer one with the kicked entry's client and session IDs (a reconnect) is left alone. With the token still this join's latest, a different entry in the slot was inserted by an attempt that arrived earlier: it is kicked too, which is bounded, since only attempts that reached J2 earlier can insert then.

This is Martin Kleppmann's fencing token ("How to do distributed locking", 2016; ZooKeeper's zxid epochs play the same part): a stale token is refused, not retried. Two earlier forms were wrong:
- Kicking any newer entry was correct for three joins but unbounded for joins that keep arriving: each kick awaits, so each can be overtaken.
- Using the slot's entry as the token missed slots the newer attempt hadn't filled yet. B kicks A, C takes the empty slot, D kicks C; A's leave returns first, so B finds an empty slot and inserts, and D is then fenced out by B's entry: the oldest of the three won. The token has to be the attempt's, taken when it arrives.

The insert also never carries the pending mark over: an entry whose OnJoin is still pending counts as never joined.

## Prevention

- Whatever a segment checked before an await, it re-checks after it by identity (a generation or ticket captured before the await), in the same segment as the act. A key lookup that finds something is not that check.
- When the re-check finds a newer identity, refuse the stale actor (a fencing check) instead of acting again: a retry that can itself be overtaken has no bound, and the newer actor already carries the intent.
- The fencing token is per attempt, taken when the attempt arrives, not read from the shared state the attempts fight over: that state can be empty, or hold an older attempt's write, while a newer attempt is still on its way.
- An act that removes state names it by identity too, not by the IDs it carries: a newer entry can carry the same ones.
- A test for it holds the first actor in the await and lets a second one change the slot (here, three joins: one held in the kick's OnLeave, one held in its own OnJoin; a kick held before its leave, while a reconnect with the kicked IDs replaces the entry; and four joins whose two kicks return oldest first).
- See [A callback that outlives its instance clears state by key alone](2026-11-05-callback-outlives-its-instance-clears-by-key.md) for the removal side of the same rule.

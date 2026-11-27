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

The kick request carries the kicked entry's generation. The segment after the kick compares it with the slot's:
- the same entry, or no entry: insert, as before;
- a different entry: run the kick check again, which kicks that one too.

The insert also never carries the pending mark over: an entry whose OnJoin is still pending counts as never joined.

## Prevention

- Whatever a segment checked before an await, it re-checks after it by identity (a generation or ticket captured before the await), in the same segment as the act. A key lookup that finds something is not that check.
- A test for it holds the first actor in the await and lets a second one change the slot (here, three joins: one held in the kick's OnLeave, one held in its own OnJoin).
- See [A callback that outlives its instance clears state by key alone](2026-11-05-callback-outlives-its-instance-clears-by-key.md) for the removal side of the same rule.

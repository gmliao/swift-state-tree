---
title: "An input issued after an await and the input that undoes it are dropped as a pair: mark the entry pending, so the undo skips too"
module: SwiftStateTree
date: 2026-11-27
problem_type: bug_class
component: land-keeper-join-leave
symptoms:
  - "a player's lifecycle applies out of order: [leave A, join B, join A] on a tickless land"
  - "on a tick land the kicked join's OnJoin still applies after its OnLeave: [join A, leave A, join B]"
  - "a second login while the first join's OnJoin resolvers run"
root_cause: the_undo_input_was_appended_for_an_entry_whose_do_input_had_not_been_appended_yet
resolution_type: code_fix
severity: high
tags:
  - reentrancy
  - join
  - leave
  - lifecycle
  - generation
related:
  - "#860"
  - "#588"
---

## Problem

A join with OnJoin resolvers inserts its entry in one segment and appends its OnJoin input in a later one, after the resolvers' await. A leave of that entry in between could be the session's own leave, or a newer login's kick. That leave removed the entry and appended an OnLeave. The join then appended its OnJoin anyway, so OnLeave applied before OnJoin, or OnJoin applied for a player who had already left.

## Root cause

The two inputs that bracket an entry's life, OnJoin and OnLeave, were issued independently. The undo didn't know its do was still on the way. A generation re-check in the join's append alone isn't enough: it drops the OnJoin, but the leave has already appended its OnLeave for an OnJoin that will never apply.

## Fix

The entry carries `onJoinPending`:
- set in the insert's segment, only when an await follows;
- cleared in the append's segment.

A leave that finds it set removes the entry and appends no OnLeave, and it decides this before taking a sequence, so the skip leaves no gap. The join's append re-checks the entry's generation in its own segment. On a mismatch it drops the OnJoin, a one-number gap that replay steps over, and throws `JoinError.superseded`. Each removal of an entry was swept for the flag.

## Prevention

- When a do and its undo are issued in different segments, with an await between the entry's creation and the do, both sides need to know: the do re-checks its ticket, and the undo checks a pending mark. Dropping only one side leaves the other unpaired.
- Decide the skip before taking anything shared (a sequence number, a slot), so a skipped input leaves no trace.
- A test should pin the order of what applied, on tick and tickless lands, and the sequences recorded, not only the final state.

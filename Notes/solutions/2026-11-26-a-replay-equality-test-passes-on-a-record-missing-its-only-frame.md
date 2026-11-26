---
title: "A replay-equality test passes on a record that lacks the frame it is about: assert the record carries it"
module: SwiftStateTree
date: 2026-11-26
problem_type: testing_practice
component: reevaluation
symptoms:
  - "a record-and-replay test of a failure stays green with the failure's terminal entry removed"
  - "`serverEventMismatches` is empty and `serverEventVerification` is `.passed` for a replay that stepped no tick"
root_cause: equality_check_over_an_empty_or_shortened_replay
resolution_type: established_pattern
severity: medium
tags:
  - replay
  - record
  - testing
  - failure
related:
  - "#901"
  - "#902"
  - "2026-11-26-a-failure-default-right-inside-a-turn-is-wrong-before-the-first-tick"
---

# A replay-equality test passes on a record that lacks the frame it is about: assert the record carries it

## Problem

#902's tests recorded a tick land that failed before its first tick, replayed the record, and expected no server-event mismatch and `.passed`. Review found that they would pass with the failure's terminal entry missing. That entry is the record's only frame. Without it, replay finds no tick to step and compares nothing. After a first tick the same tests compared only tick 0's events, which the failure doesn't touch.

## Root cause

A replay-equality check says that every frame replay stepped matched. It says nothing about which frames the record holds. When the change under test is the content of one frame, and losing that frame shortens the replay, "no mismatch" holds vacuously.

## Fix

The helper also asserts what the test is about:
- the replay's `liveFailure` equals the failure live reported, kind and position;
- the record's land failure (`getLandFailure()`) sits in the expected frame.

Dropping the terminal entry now fails both.

## Prevention

- A record-and-replay test asserts, besides equality, that the record carries the entry or frame under test, and that replay reached it.
- Ask of every equality test: would it pass if the thing it checks were missing?

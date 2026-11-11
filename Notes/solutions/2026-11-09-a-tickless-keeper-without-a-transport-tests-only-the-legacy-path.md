---
module: SwiftStateTree
date: 2026-11-09
problem_type: testing_practice
component: land-keeper-tests
symptoms:
  - "a mutant that breaks the in-turn path of a tickless land survives every test"
  - "tickless tests pass the same with in-turn sync on or off"
root_cause: tickless_test_keeper_without_transport_takes_legacy_path
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - keeper
  - tickless
  - in-turn-sync
  - mutants
related:
  - "#387"
---

# A tickless keeper built without a transport only tests the legacy path

## Problem

A tickless land applies an input one of two ways: in an input turn whose sync phase runs inside the turn (`awaitInputTurn`, when `usesInTurnSync`), or in a legacy pass (`processPendingActions`). The server input tests (#387) built their keepers without a transport. A mutant that disabled the in-turn branch survived: no test took that branch.

## Root cause

`usesInTurnSync` asks the transport (`runsSyncPhaseInTurn(of:)`). With no transport it is false, whatever `IN_TURN_SYNC` says, so a keeper built with `transport: nil` always takes the legacy path. Both paths apply the input, so a test that checks only the state can't tell which one ran.

## Fix

- Run tickless tests with `arguments: [false, true]`. The `true` case attaches a transport that reports in-turn sync (`runsSyncPhaseInTurn` returns true), as `TicklessReplayPassTests` does.
- Check the path as well as the state. The test transport counts the server events delivered in a turn's sync phase (`runSyncPhaseInTurn(events:)`) apart from those sent through the legacy `sendEventToTransport`. In-turn, every event arrives through the sync phase and none through the legacy send.

## Prevention

A test of a tickless keeper's input handling runs both paths, and the in-turn case checks how the events were delivered. A mutant that sends the in-turn branch to the legacy pass must fail a test.

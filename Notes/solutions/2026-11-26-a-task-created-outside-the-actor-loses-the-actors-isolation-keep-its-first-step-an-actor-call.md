---
title: "A Task moved from an actor method into a nonisolated helper or a staged closure loses the actor's isolation; keep its first step an actor call"
module: SwiftStateTree
date: 2026-11-26
problem_type: bug_class
component: land-keeper
symptoms:
  - "the transport hears landDidFail before the failing turn's last port call"
  - "a task's body runs while the actor that started it is still inside the same synchronous segment"
  - "a refactor that moves code off an actor changes the order of callbacks without changing any line of the task's body"
root_cause: task_isolation_inherited_from_its_creation_context
resolution_type: code_fix
severity: high
tags:
  - concurrency
  - isolation
  - task
  - actor
  - refactor
  - turns
related:
  - "#700"
  - "#914"
---

# A Task moved from an actor method into a nonisolated helper or a staged closure loses the actor's isolation; keep its first step an actor call

## Problem

Before #700 K1b-5's move, `failLand` was a `LandKeeper` method and started the failed land's teardown as `drainTask = Task { await holds.at(.landFailedTeardown); if let transport { await transport.landDidFail(failure) }; await self.drainAfterIdleCheck() }`. The move turned `failLand` into a `KeeperModel` method and staged the task's start (`outputs.stage { … Task { … } }`), which the turn's flush runs. The task's body was copied unchanged.

Review of #914 found the order had changed. In an input turn that applies a join and then a queued failure, the join report's `callOut` flushes the staged start before it calls `noteJoinInputsConsumed`. The task then ran at once on the global executor, and an off-executor transport could hear `landDidFail` before the failing turn's join report.

## Root cause

A `Task { … }` closure inherits the isolation of the context it is written in (SE-0420). Written in an actor method and capturing `self`, its body runs on the actor: it can't start until the actor's current synchronous segment ends. Written in a nonisolated function or closure, as the model's methods and the staged closure are, its body is nonisolated and starts on the global executor right away. The body's text is the same, so a diff of the move shows nothing.

## Fix

The task's first step is a keeper-isolated call: `Task { await keeper.runFailureTeardown(failure, transport: transport) }`, where `runFailureTeardown` is a `LandKeeper` method that does what the old body did. The hop to the keeper waits for the failing turn's segment to end, as before the move. `KeeperTurnSkeletonTests.teardownWaitsForTheFailingTurn` pins the order: its transport's join report waits up to half a second for `landDidFail` to start, so a teardown that can run during the turn does so first; the test expects the report first. It failed before the fix.

The move's other staged starts were already in this shape (`[weak keeper]`, then a keeper method as the first await), so they kept their order.

## Rule

When a refactor moves code that creates a `Task` out of an actor method, into a nonisolated helper, a model method or a staged closure, check what the task's body does before its first actor call. If that work relied on running after the actor's current segment (a port call, a callback, a hold), make the first step a call to an actor method that does it. Reviewing the moved lines is not enough: the isolation comes from where the `Task` is written, not from its body.

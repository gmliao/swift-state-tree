---
title: "A reevaluation keeper drain runs destroy handlers"
module: SwiftStateTree
date: 2026-11-25
problem_type: bug_class
component: reevaluation-drain
symptoms:
  - "OnFinalize resolver is called when a reevaluation keeper is shut down"
  - "AfterFinalize runs in replay, reaching outside services"
  - "DestroyWhenEmpty handler body runs in a reevaluation keeper's drain"
root_cause: drainAfterIdleCheck_did_not_guard_against_reevaluation_mode
resolution_type: design_rule
severity: high
tags:
  - reevaluation
  - replay
  - drain
  - destroy-handlers
  - turns
related:
  - "#826"
---

# A reevaluation keeper drain runs destroy handlers

## Problem

A reevaluation keeper replays recorded inputs to verify that the land's
code reproduces the same behavior as the original run. When shut down,
its `drainAfterIdleCheck` ran `DestroyWhenEmpty`, `OnFinalize`, and
`AfterFinalize` as if the keeper were live.

This is wrong for two reasons:
1. The record holds no finalize event: there is nothing to verify these
   handlers against, so they always run unchecked.
2. `OnFinalize` resolvers and `AfterFinalize` can reach outside services
   (databases, analytics). Running them in every replay multiplies those
   side effects.

## Cause

`drainAfterIdleCheck` is the shared final path for every keeper mode
(live, reevaluation). It guards against an initialization failure but
not against reevaluation mode. The reevaluation path in `runForceShutdown`
(line 2927) calls `shutdownIfIdle` for `mode != .live`, which calls
`drainAfterIdleCheck` — the same function that live keepers use.

## Fix

One guard after the `initializationFailure` guard in `drainAfterIdleCheck`:

```swift
guard mode == .live else {
    await notifyTransportDestroyedAndRelease()
    return
}
```

The transport still receives `onLandDestroyed`: that cleanup is not land
code and must fire for every keeper mode.

## Rule

**A path shared by live and reevaluation keepers that runs land code
with no recorded input behind it** — teardown hooks and their resolvers
(DestroyWhenEmpty, OnFinalize, AfterFinalize) — must skip that code in
reevaluation mode; add the guard at the first point where the unrecorded
code begins, as the initialization-failure guard does.

Replaying recorded actions, events and lifecycle (join/leave) inputs is
what reevaluation is for; those paths must run. Teardown has no matching
record entry: there is nothing to verify those handlers against, and
their resolvers and AfterFinalize can reach outside services.

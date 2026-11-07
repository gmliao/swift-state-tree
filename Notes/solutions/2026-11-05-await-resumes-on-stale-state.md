---
module: SwiftStateTree, SwiftStateTreeTransport
date: 2026-11-05
problem_type: bug_class
component: actor-reentrancy
symptoms:
  - "A check made before an `await` (a lookup, `isEmpty`, `isRunning`, \"already joined\", \"session still connected\") no longer holds when the function resumes"
  - "A player stays half-joined, or a cleanup removes state that a newer session is using"
  - "Bugs appear only under load or on Linux CI, never in a single-threaded debug run"
root_cause: actor_reentrancy_check_then_act_across_await
resolution_type: design_rule
severity: high
tags:
  - reentrancy
  - actor
  - concurrency
  - keeper
  - turns
related:
  - "#97"
  - "#114"
  - "#137"
  - "#139"
  - "#141"
  - "#146"
---

# Check, await, act: the function resumes on stale state

## Problem

Every `await` inside an actor lets other calls to that actor run. A function that checks keeper or adapter state, suspends, and then acts on the result of the check acts on a state that may have changed. The same bug was fixed one site at a time: #137 (an older session's disconnect cleared a newer session's state after `keeper.leave`), #139 (the initial-sync handover), #141 (the sender re-check before an action's append). A sweep for the reentrancy helpers plan found 22 more sites.

## Symptoms

- A join that outlives its session's disconnect leaves a permanent player in the keeper (#97).
- A sync cycle sends a newer session a diff before its firstSync, because an older session's cleanup cleared the firstSync mark (#137).
- Tests pass on the Mac and fail intermittently on the Linux runners, where the executor is multi-threaded.

## Root cause

Actor isolation serializes the *segments* between suspension points, not whole functions. Re-checking by hand after each `await` misses sites, and nothing in the type system says which state a check depends on.

## Fix

The rule in `CLAUDE.md` / `AGENTS.md` § Reentrancy, from [the reentrancy helpers plan](../plans/2026-11-05-reentrancy-helpers.md) (#146):

- **Keeper state is mutated only inside synchronous turns.** Async work is a request that goes out; its result comes back as a turn input whose handler re-reads the current state and validates a ticket captured when the request went out. This is Elm's `Cmd`/`Msg` split and Erlang/OTP's `gen_server`. The sync phase runs inside the keeper's turns since #114.
- **Outside turns** (adapter, transport, router, host, NIO, admin), use the helpers in `Sources/SwiftStateTree/Support/`: a `GenerationTable` ticket captured before the `await` and checked with `ifCurrent` (whose closure can't await) in the same segment as the act; `SingleFlight` for create/destroy once; `Lifecycle` for start/stop.

## Prevention

- Before writing `await` in an actor, list the state read before it that the code after it depends on. If there is any, either move the act into a turn input or capture a ticket.
- Pin each fix with a test that holds the code at the `await` and runs the competing call there (see [hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md)). TSan doesn't catch this class.

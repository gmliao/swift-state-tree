---
module: SwiftStateTreeTransport
date: 2026-11-09
problem_type: bug_class
component: land-teardown
symptoms:
  - "Memory grows with room churn; destroyed lands are never freed"
  - "A recorder's spool file is never discarded, because the recorder is never released"
  - "A weak reference to a destroyed land's keeper or adapter stays non-nil"
root_cause: two_strong_reference_cycles_never_broken_at_teardown
resolution_type: code_fix
severity: high
tags:
  - memory
  - reference-cycle
  - teardown
  - lifecycle
  - testing
related:
  - "#346"
  - "#347"
---

# A destroyed land kept alive by its own links

## Problem

A land that LandManager destroyed was never released: its keeper, adapter, state and per-land transport stayed for the rest of the process. That was true for every destroy path. Recorders in test fixtures were never released either, so their spool files were never discarded (#347).

## Root cause

There were two strong cycles, and no teardown step broke either one:
- the keeper's `transport` is the adapter, and the adapter's `keeper` is the keeper;
- a land's own `WebSocketTransport` has the adapter as its `delegate`, and the adapter holds the transport.

A probe found that each part alone is released, and the wired set is released only once both links are cleared. Reading the code didn't show this. Destroying the land through the manager and checking weak references did.

## Fix

Each instance breaks its own links at the end of its own teardown. Nothing is cleared by land ID from a callback.
- **Keeper:** after the destruction's last call, `transport?.onLandDestroyed()`, it drops its transport. A keeper whose destruction has finished refuses a transport attached later, as in a land whose initialization failed before it was wired.
- **Adapter:** at the end of its `onLandDestroyed`, it clears its own transport's delegate, only if that delegate is still this adapter. A shared transport's delegate is the router, and it stays.
- **LandManager:** when a built instance turns out to be torn down before publication, the manager releases that exact instance's transport delegate.

`LandReleaseTests` creates lands through `getOrCreateLand` and destroys them on each path, in both sync modes:
- the empty-room timer;
- `shutdownAllLands`;
- removal by ID;
- a failed initialization after publication;
- a teardown finished before the wiring (`.wiring` hold);
- a replay land;
- a shared transport with a second land that keeps working.

A keeper test holds inside `onLandDestroyed` and checks that the transport is still attached during that last call.

## Prevention

- When two objects hold each other, name the step that breaks the link and the instance that owns it. Then test the release with weak references through the real teardown, on every destroy path, including a failed creation and a half-wired instance.
- "The manager removed it" doesn't mean "it was freed". Check the weak references.
- A resource that a deinit cleans up (a spool file, a socket) leaks with its owner. A leftover file can point to a leaked object.

---
title: "A hang guard that acts when cancelled races the check it guards"
module: SwiftStateTreeTransport
date: 2026-11-28
problem_type: test_flake
component: test-hang-guard
symptoms:
  - "Expectation failed: (writer.syncCycleDrainWaitEntriesForTesting → 1) == 0"
  - "a released or timed-out debug settle seems to leave its writer drain-wait entry, on some CI runs only"
root_cause: hang_guard_side_effect_ran_on_cancel
resolution_type: code_fix
severity: low
tags:
  - testing
  - flaky
  - cancellation
  - debug-freeze
related:
  - "#807"
  - "2026-11-17-a-hang-guard-in-a-task-group-waits-for-the-hang"
---

**Problem.** Two back-pressure tests checked that a debug settle behind a blocked writer, once released or timed out, leaves no drain-wait entry in the writer: `syncCycleDrainWaitEntriesForTesting == 0`. They failed now and then on CI, reading 1 (#807), on Linux and macOS.

**Root cause.** The 1 wasn't the settle's entry. The settle removes its own entry in the wait's cancellation handler before it returns. The entry belonged to the keeper: the fixture's second action is deferred behind the writer's element, and the keeper starts a writer-drain retry whose wait registers from a task of its own. A probe showed that entry present, 60 times in 60, whenever the writer stayed blocked. The tests read 0 because their hang guard, a task-group child, ran `transport.release()` after its sleep even when the sleep ended by cancellation. So on every run the group released the transport, the writer drained asynchronously, and that drain resumed the retry's wait. The count was read while that drain was still running. Usually the drain had finished. On a slow runner it hadn't.

The retry's registration time also varies: during the block step or the next action. The released test waited for "the settle registered" with a hook it installed after that action. So a late retry registration could satisfy the hook first, and the release would then come before the settle waited at all.

**Fix.** The hang guard releases the transport only when its sleep ran to the end: `guard (try? await safeTaskSleep(for: testHangBound)) != nil else { return nil }`. A fixture helper installs the registration hook before the block step, waits for the keeper retry's one registration, and returns the count then (1). Each test then checks that the count after the settle equals that baseline, with the writer still blocked. In the released test, the hook's first arrival is now always the settle's.

**Prevention.**
- A hang guard's side effect (a release, an open, a drain) runs only when the bound ran out, never on the cancel that ends it after a success. Otherwise every run takes the side effect, and whatever it starts runs alongside the checks that follow.
- A test that counts entries in a shared table first names every owner the table can have at that point, and checks against a baseline it waited for. It doesn't assume the count is zero.
- A registration hook that two parties can trigger is installed before either can, and the test waits for each arrival in order.

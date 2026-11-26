# #901: a tick land's failure before its first tick ends frame 0's inputs

Rev 1. Issue #901. Plan and probe only; code after Review's GO.

## Problem

`failLand` writes the terminal entry into frame `max(nextTickId - 1, 0)` on a tick land. Replay applies that frame's recorded inputs. It skips the frame's tick handler only when the failure's position says `endsInputs == true` (`ReevaluationEngine`, `replayEndsHere`; `ReevaluationRunnerImpl` the same).

A failure inside a tick turn passes `endsInputs` itself: `true` before the handler, the default after it (#891). A failure outside any tick turn takes the default. Between ticks the default is right: the frame is the last committed tick, whose handler ran.

Before the first tick it is wrong. The frame is 0, and no handler ran in it. Replay runs tick 0's handler, which live never ran, and its events show up as a mismatch at tick 0. #896 fixed one site by hand (J2, the stale-join refusal). The probe below shows the same result at the other sites.

Consulted: `Notes/solutions/2026-11-26-a-refusal-before-a-handler-must-record-that-it-ended-the-inputs.md`. Its fix is per site, for a site inside a turn that knows where it sits. Here no site knows: the answer depends on whether any tick has run, which is keeper state.

## The rule

In `failLand`, on a tick land, a failure whose frame hasn't committed ends that frame's inputs:

```swift
let frame = isTickless ? 0 : max(m.nextTickId - 1, 0)   // the terminal entry's frame, as now
let frameUncommitted = !isTickless && m.lastCommittedTickId < frame
let ended = (endsInputs || frameUncommitted) && (!isTickless || appliedInputs)
```

The terminal entry's frame, the position's `tickId` and the pass stay as they are. Only `endsInputs` changes.

### What it reads, and why that read

Replay skips a frame's handler when the failure says the inputs ended. That is right exactly when live never ran the frame's handler. A tick turn commits its tick (`m.lastCommittedTickId = tickId`) right after the handler step, and before its outputs. So "the frame's handler hasn't run" is "the frame hasn't committed": `m.lastCommittedTickId < frame`. It reads the two values `failLand` already reads for the frame and the position.

Where a failure can sit on a live tick land:
1. **Outside any turn, before the first tick:** `nextTickId == 0`, frame 0, nothing committed. The rule ends the inputs. This is the hole.
2. **Inside tick N's turn, before its commit:** the fold report, the inputs and the join report. Each already passes `endsInputs: true`, so the rule changes nothing there.
3. **Inside tick N's turn, after its commit:** the joins read, the join-sync calls and the sync phase. Frame N is committed, so the defaults hold. The probe's tick-0 joins-read case shows `tickId 0`: it sits after tick 0's commit.
4. **Outside any turn, after a tick:** the frame is the last committed tick, so the defaults hold.

The increment of `nextTickId` and the tick turn share one synchronous segment in live mode. The only await between them is the test-only `inTurnYieldForTesting`. The shutdown turn between ticks increments and commits inside its own body. The input drain's `executingTickIdForPendingItems` runs on tickless lands only, and `failLand` returns before the record in re-evaluation. So outside a turn the frame is either committed, or it is frame 0 before any tick.

The other candidate reads give the same answer at every site today:
- **`m.nextTickId == 0`** differs inside any tick turn, before its commit. Every site there passes `true` itself. It would be wrong for a future site there that took the defaults, because that tick's handler hadn't run yet.
- **`m.lastCommittedTickId < 0`** (J2's hand fix in #896) differs only inside tick N's turn, for N > 0, before its commit. The same sites, the same reasoning.
- **A tick-in-progress marker or the recorder's open turn** would add keeper state, or depend on a recorder being attached. The failure's position is reported with or without a recorder.

I chose `lastCommittedTickId < frame` because it is replay's own condition, written in the keeper's terms. It stays right for a future site anywhere in a tick turn.

### J2 folds in

J2 runs in the join's own turn, never inside a tick turn. There the frame is committed, or it is frame 0 before any tick, so J2's `m.lastCommittedTickId < 0` equals the rule. With the rule, J2's `endsInputs: beforeFirstTick` goes. Its `enqueueTicklessTurnEnd` stays: that one is about tickless lands' turn records, not the frame. `recordedStaleRefusalReplays(afterFirstTick:)` stays as it is and now pins the rule at J2.

### Out of scope

- Records made before the fix still have `endsInputs` nil at these failures and still replay with the mismatch. Replay reads the flag from the record, so there is no record-version change.
- A shutdown turn before the first tick takes frame 0 too. It isn't a failure, and the probe shows its record replays clean, before and after the first tick.

## Sites

Every failure outside a tick turn on a tick land reaches `failLand` with the default flags, apart from J2 since #896. The probe runs each before and after the first tick, records it and replays it.

| Site | How it reaches `failLand` | Before the first tick | After the first tick |
|---|---|---|---|
| `failLand` with the defaults (`failLandForTesting`) | directly | `tickId nil`, `endsInputs nil`; replay: mismatch at tick 0, `failed(ticks: [0])` | `tickId 0`, `endsInputs nil`; replay passes |
| a body's `callOut` refusal (`runTestBodyForTesting(callingOut:)`): initialization's and the settle's call outs take this path | `callOut` → `applyReentryFailure` | mismatch at tick 0 | passes |
| the late backstop (`runTestBodyForTesting(observe:)`): the intakes and any body's re-entry outside a call out | `applyLateReentry` | mismatch at tick 0 | passes |
| the mailbox, applied by a sync-only turn (`notePendingFailure`) | `applyPendingTransportFailure` | mismatch at tick 0 | passes |
| the sync-only turn, a re-entry at its 1st port call | `callOut` | mismatch at tick 0 (also at its 2nd call, in #896 round 1's probe) | passes |
| control: the first tick's fold report (tick 0, or tick 1 after a first tick) | `callOut(endsInputs: true)` | `endsInputs true`; passes | passes |
| control: the first tick's joins read, after its commit | `callOut` | `tickId 0`, `endsInputs nil`; passes | passes |

Not probed:
- **Initialization's call outs** (`initializeTurnBody`: `recordsSyncStream`, `syncsInTurn`): the keeper starts initialization at construction with its transport, so a fake can't be armed with the keeper before the first call. They pass the defaults, like the rows above. The implementation adds a fake that is armed at construction.
- **The settle** (`settleBody`): its call outs and the mailbox take the defaults. The recorded fold land's fake isn't a settle port; the implementation's test gives it one.
- **`submitSyncStream(outsideTurn:)`**: its re-entry is applied with the defaults, as the late backstop's.

## Tests

One suite, `TickLandFailureBeforeFirstTickTests`, each case recorded and replayed with `serverEventVerification == .passed` and no server-event mismatch, before and after the first tick. The position assert is `endsInputs == true` before the first tick and nil after.
- the sync-only turn, a re-entry at its 1st and its 2nd port call;
- the mailbox, applied by a sync-only turn;
- the settle, a re-entry at its first call out;
- initialization, a re-entry at its first call out (before the first tick only);
- the late backstop, through `runTestBodyForTesting(observe:)`;
- J2 stays in `recordedStaleRefusalReplays`.

Controls, inside tick 0 with no tick before it: the fold report (`endsInputs == true`, as the site passes) and the joins read (nil: it sits after tick 0's commit). Both replay clean.

## Mutants (cloud)

1. The rule removed: the before-the-first-tick cases fail on the position and on replay.
2. The rule reads `m.lastCommittedTickId <= frame`: the after-the-first-tick cases and the joins-read control fail. They would claim the inputs ended in a committed frame.
3. The rule without `!isTickless`: the tickless refusal tests that pin `endsInputs` nil on a pass that applied inputs fail. If none does, the implementation adds one.
4. J2's hand fix restored and the rule removed: J2 passes and the other sites fail. This shows the sites need the rule, not more hand fixes.

`m.nextTickId == 0` and `m.lastCommittedTickId < 0` are equivalent mutants today, as the section above explains. No test separates them, and none should be written for a site that doesn't exist.

## Where it goes

A PR of its own, stacked on #896, before the K1b-5 move. Not a D-row in the move:
- The move is meant to change no behavior. This changes what a record says at a failure, and needs its own record-and-replay tests and mutants.
- The fix is two lines in `failLand`, plus J2's flag removed. Landing it first leaves the move a plain move of `failLand`.
- J2's hand fix is in #896, so the PR needs #896 below it.

Before the PR: check whether any of #895's golden records holds a failure before the first tick. A golden that does changes with the rule.

## Probes

The probe is `2026-11-26-tick-land-failure-before-first-tick-probe.swift`, next to this plan. It ran as an extension of `InTurnSyncFoldReportTests` at #896's round 1 head (on #895 round 1), macOS, debug. Each case records a fold land whose tick emits an event, fails the land at the site, saves the record and replays it with `ReevaluationEngine.run`. The output, one line per case:

```text
site=failLandDefault after=false kind=syncPlan tickId=nil endsInputs=nil ticks=0 mismatches=[0] verification=failed(ticks: [0])
site=failLandDefault after=true kind=syncPlan tickId=Optional(0) endsInputs=nil ticks=1 mismatches=[] verification=passed
site=lateBackstop after=false kind=keeperReentry tickId=nil endsInputs=nil ticks=0 mismatches=[0] verification=failed(ticks: [0])
site=lateBackstop after=true kind=keeperReentry tickId=Optional(0) endsInputs=nil ticks=1 mismatches=[] verification=passed
site=mailboxThenSyncOnly after=false kind=syncPlan tickId=nil endsInputs=nil ticks=0 mismatches=[0] verification=failed(ticks: [0])
site=mailboxThenSyncOnly after=true kind=syncPlan tickId=Optional(0) endsInputs=nil ticks=1 mismatches=[] verification=passed
site=shutdown after=false ticks=0 mismatches=[] verification=passed
site=shutdown after=true ticks=1 mismatches=[] verification=passed
site=syncOnlyFirstCall after=false kind=keeperReentry tickId=nil endsInputs=nil ticks=0 mismatches=[0] verification=failed(ticks: [0])
site=syncOnlyFirstCall after=true kind=keeperReentry tickId=Optional(0) endsInputs=nil ticks=1 mismatches=[] verification=passed
site=testBodyCallOut after=false kind=keeperReentry tickId=nil endsInputs=nil ticks=0 mismatches=[0] verification=failed(ticks: [0])
site=testBodyCallOut after=true kind=keeperReentry tickId=Optional(0) endsInputs=nil ticks=1 mismatches=[] verification=passed
site=tick0FoldNote after=false kind=keeperReentry tickId=nil endsInputs=Optional(true) ticks=0 mismatches=[] verification=passed
site=tick0FoldNote after=true kind=keeperReentry tickId=Optional(0) endsInputs=Optional(true) ticks=1 mismatches=[] verification=passed
site=tick0JoinsRead after=false kind=keeperReentry tickId=Optional(0) endsInputs=nil ticks=1 mismatches=[] verification=passed
site=tick0JoinsRead after=true kind=keeperReentry tickId=Optional(1) endsInputs=nil ticks=2 mismatches=[] verification=passed
```

What it shows:
- Before the first tick, every site outside a tick turn records `endsInputs nil` into frame 0, and replay fails at tick 0.
- After the first tick, the same sites replay clean.
- Both tick-0 controls replay clean: inside a tick turn the sites' own flags are right.
- A shutdown before the first tick replays clean.

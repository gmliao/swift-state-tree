# K1b-5: turn bodies on the model, and the named segments (#700)

**Status:** draft 1, prep only. It was read at #835's head 6657fce4, without the LSP. It is not for Review yet: K1b-5 needs K1b-4, whose plan (rev 1.1) settles the types this one builds on. Rev 1 is written once K1b-1 to K1b-4 have their GO, and its line numbers are re-taken on K1b-5's base.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md` rev 5.8: A.6's F6 to F8 and A.8, folded in from census draft 3, read at 32a220e9;
- K1b-4's plan rev 1.1: `KeeperModel`, `KeeperBehavior`, one `inout` access of the model per step, and D1 (the collector stays a class until K2);
- the K2 prep survey (1ebd7ddb), §7's three requests.

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, at 6657fce4.

## 1. Goal

After K1b-5:
- **Every turn is a body.** A body is a `mutating` method on `KeeperModel` that takes the behavior (`mutating func applyInputTurn(_:behavior:…) -> …`), as the survey's §1 asks. K2's `handle` then switches on its input and calls the body, unchanged.
- **Every async flow is a chain of named synchronous segments.** The awaits sit between the segments, in the actor's code. A segment takes what its flow captured before the await plus the await's result, re-reads the model, and validates. This is the CLAUDE.md rule's target shape, and K2 turns each await into a `run` effect whose result is an input.
- **Replay calls the same bodies** on its own model (A.6, "Replay path"; K2 moves them into `ReplayLandOwner`).

K1b-5 changes no behavior. Each move is a refactor pinned by the existing suites. The re-checks that today's code does by hand move into the segment after the await, as they are. A flow that lacks a re-check keeps lacking it (#852 below), and a new check is its own change.

## 2. The turn bodies (F6 plus §2's four)

| Body | Today (LK at 6657fce4) | Its awaits after it |
|---|---|---|
| the tick turn | `runTickTurn` (:4978), synchronous | `finishTickTurn`'s record submit (:5084) |
| the input turn | `runInputTurn` (:5975), synchronous | `runInputDrain`'s record submit (:5937), then `resumeInputTurnWaiters` |
| the sync-only turn | `runSyncOnlyTurn` (:5355), synchronous | none |
| the settle | `settleTurn` (:1830), synchronous | none |
| the shutdown between ticks | `applyShutdownTurnBetweenTicks` (:3032): its apply runs before its one await | the record submit (:3046) |
| the requested sync | `syncTurnNow` (:5548), synchronous | none |
| the drain's turn end | `runInputDrain` (:5929): `readyPendingItemsInOrder` and `enqueueTicklessTurnEnd` | — |
| initialization's outputs | `performInitialization` (:1421): its output segment (`runTurnOutputs`, `takeSyncRequest`, `takeSyncStreamIndex`, `takeEmittedEvents`) | K5 owns the flow; K1b-5 only makes this segment a body |

**Staged outputs (survey §3, for Review to agree).**
- Each body returns a `TurnOutputs` value instead of handing them on in place: the emitted events, the sync request, and the record draft.
- K1b-4's D1 keeps the collector a class, and the handler's context closures still write it during the handler. So the body drains the collector at its end (as `takeEmittedEvents` and `takeSyncRequest` do today) and returns what it took. The actor's driver hands that to the transport and the recorder.
- The bodies then have K2's shape, while the collector stays as the sink until K2 stages outputs in the step.
- **The one exception: the in-turn sync phase.** It calls the transport port synchronously inside the turn (§3.7), and stays inside the body.

## 3. The named segments (F7), re-checked at 6657fce4

For each flow:
- **the awaits** that split it;
- **the segments** after each await, which become named synchronous functions;
- **what crosses each await.** A value marked **not plain** is a K2 finding: K2 must carry it in an effect, not in the model or an input.

`holds.at(…)` is not an await that splits a flow: with no hook installed it returns without suspending (HoldPoints.swift:29–36). It stays as a test point at the start of its segment.

### 3.1 Join (`joinReportingAdmission`, :2067; the public `join`, :1921)

| Await | The segment after it | What crosses |
|---|---|---|
| `ensureInitializedForJoin` (:2074) | **J1, the CanJoin admission:** build the CanJoin context, run the resolvers (an await), run the handler | `session: PlayerSession`, `clientID`, `sessionID`, `services: LandServices` (**not plain**), `admitThroughTransport` |
| CanJoin resolvers (:2094) | **J2, the decision:** `canJoin(state, session, ctx)`, the stale-join refusal (#234), the cap check, then the duplicate login's kick | the resolved context (`LandContext`, **not plain**: it carries the outputs and the collector's closures) |
| the kick, `await leave(…)` (:2138) | **J3, the insert:** build or update the player's entry, the `isDraining` check, the entry generation, `players[playerID] = …`, the admission or the OnJoin sequence and its resolver context | `decision: JoinDecision` (plain fields, not marked), `playerID`, `isReconnection` (**stale after the await, see #852**) |
| OnJoin resolvers (:2203, via `executeOnJoinResolvers` :6139) | **J4, the OnJoin input:** the `isDraining` and generation re-checks, the append, the admission, and the drain schedule or the input-turn wait | `sequence`, `entryGeneration` (`Epoch`), `resolvedAtTick`, the outputs (`[String: HeldResolverOutput]`, plain after K1b-1), the session's fields |
| `awaitInputTurn` (:2253) | none: the outcome returns | — |

**#852 (filed from this survey).** J2's cap check skips a reconnecting player, and J3 inserts after the kick's await without checking the cap again. A new join in that window takes the land past `maxPlayers`.
- K1b-5's split puts the check in J2 and the insert in J3, as today, so it **doesn't close #852** by itself.
- The fix belongs in J3, the segment after the await, as a re-check of the current model: which join the cap then refuses is #852's choice.
- In K2, J3 becomes the kick's completion input, which is where that re-check runs in a turn.

### 3.2 Leave (`leave`, :2812)

| Await | The segment after it | What crosses |
|---|---|---|
| `ensureInitialized` (:2813) | **L1, the removal:** find the entry, check the client and the session, remove it, cancel its jobs, take the OnLeave sequence, build the OnLeave context | `playerID`, `clientID`, `sessionID` |
| OnLeave resolvers (:2881) | **L2, the OnLeave input:** on failure, the drop metric and `scheduleDestroyIfNeeded`. Otherwise the `isDraining` check and the append | the removed entry's `services` (**not plain**), `deviceID`, `isGuest`, `metadata`, `sequence`, `resolvedAtTick`, the context (**not plain**) |
| `awaitInputTurn` (:2930) | **L3:** `scheduleDestroyIfNeeded()`, a model write after an await | `sequence` |

L3 is today's write after an await on the leave path. K1b-5 names it, and K2 makes it part of the turn that applies the leave, or its completion input.

### 3.3 Actions (`submit`, :3105; `startActionJob`, :2490; `completeAction`, :2529; `awaitActionResult`, :2661)

| Await | The segment after it | What crosses |
|---|---|---|
| `ensureInitialized` (:3112) | the freeze wait | the envelope, the identities |
| `debugWaitWhileFrozen` (:3125) | **A1, the intake:** the handler lookup, the decode, the sender check, the resolvers' build, the sequence, the ticket, then the job start or the delivery | the envelope (its payload source: not plain, but consumed in A1) |
| the job's task: resolvers (:2511), then `holds.at(.actionComplete)` (:2533) | **A2, the completion:** re-read the job, the caller's cancellation, the delivery check against the ticket, the deliver or the fill | `sequence`, `resolved` (the outputs, or an error: K1b-2's `FailureID` once stored) |
| `awaitInputTurn` (:3265), tickless without a job | none: the outcome returns | — |
| `awaitActionResult`'s continuation | none | — |

The job's task, the abandonment and the caller's cancellation flag stay in K1b-2's side table. K2's `JobCancellation` replaces the flag, and K5 replaces the task.

### 3.4 Client events (`handleClientEvent`, :3301) and server inputs (`submitServerInputErased`, :3431; `kickServerInputTurn`, :3510)

- **Client event.** `ensureInitialized` (:3307) and the freeze wait (:3316) come first. Then **C1, the intake**: the descriptor, the decode, the bytes, the sender check, the sequence, the append. Then `awaitInputTurn` (:3405). C1's captures are consumed in C1.
- **Server input.** `ensureInitialized` (:3433), then **S1, the intake**. Then the kick task: `holds.at(.serverInputKick)`, `awaitInputTurn`, and `debugEndWork` (:3515–3517). The kick's `debugEndWork` is the freeze accounting the CLAUDE.md rule names, a write after an await, until K2.

### 3.5 The turn drivers

- **The input drain** (`runInputDrain`, :5929). The input turn's body, then `submitTurnRecord` (:5937), then **D1, the resume**: `resumeInputTurnWaiters`. What crosses the submit is `InputTurnOutcome`:
  - `appliedItems` (plain after K1b-1) and `syncBroadcastOnly`;
  - `record: ReevaluationTickRecord`, which is **not plain**: `ReevaluationRecordedResolverOutput.value` is an `AnyCodable` tree (ActionRecorder.swift:10). K2's `.awaitRecordTaken` carries the draft in the effect, not in the model. #769 R2 makes those outputs bytes.
- **The live tick** (`runTick`, :4484). Its live part: the tick turn's body, then `finishTickTurn`'s submit (:5084). The replay part keeps its source awaits between bodies (A.6's replay path).
- **The sync loop** (`runSync`, :6076). Its fold decision writes the model outside a turn (S3's exception), then awaits `syncNowFromTransport` (:6129). Unchanged until K2's `.syncDue` step.

### 3.6 Out of K1b-5's scope, named for the census

These flows are named in F7, and other slices own them:
- `performInitialization` (14 awaits): K5;
- the force shutdown and the drain (`runForceShutdown` :2973, `shutdownIfIdle` :6176, `drainAfterIdleCheck` :6199): K7, and the land-stop drain's exception (#522);
- the destroy handlers (`runDestroyHandler` :6291, `notifyTransportDestroyedAndRelease` :6275): K7.

K1b-5 only makes their synchronous apply segments call the bodies.

## 4. What isn't plain across an await (survey §7.3)

| Value | Where | K2's carrier |
|---|---|---|
| `LandServices` | the join's `services`, the leave's removed entry | the resolver effect captures it. K1b-4 already moves `services` off the model's player entry (A.1) |
| `LandContext` | J1→J2, J3→J4, L1→L2, A1→A2 | built in the step, carried by the effect. Only its outputs come back, as `[String: HeldResolverOutput]` |
| `ReevaluationTickRecord` | the record submit, in both drivers | the `.awaitRecordTaken` effect, until #769 R2 |
| `PlayerSession`, `JoinDecision` | J1→J4 | plain fields, but not marked. Each gains `@PlainData`, a public addition, if K2 puts it in an input |
| `isReconnection` | J2→J3 | plain, but stale after the kick: #852 |

## 5. Commits (a sketch, for rev 1)

One commit per flow, in this order:
1. the bodies of §2;
2. the input drain and the tick driver;
3. the action segments;
4. the client-event and server-input intakes;
5. the join;
6. the leave;
7. the replay path calling the bodies.

Each commit:
- is a pure move: the same statements, in a named function;
- keeps every existing HoldPoints test green, because the holds stay at the start of their segments;
- has a mutant that swaps two segments' order, caught by that flow's existing interleaving test.

The flows whose interleaving no test pins get one in the same commit, shaped like #852's (hold at the await, run the competing input, release).

## 6. Open, for rev 1

- **Review agrees to `TurnOutputs` (§2).** If not, the bodies keep writing in place, and K2 changes them.
- **Whether `PlayerSession` and `JoinDecision` gain `@PlainData` in K1b-5 or in K2.** They are public additions.
- **K1b-3's `withHandlerStep`** is the one place every body calls the handler. It becomes a `mutating` method on the model (survey §1). K1b-5 takes it as K1b-4 leaves it.
- **The A/B.** A refactor into named functions should inline. The plan's small A/B tier applies if Review sees a hot path change shape.

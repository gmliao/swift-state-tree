# Server-originated turn inputs (#387)

Status: PR 1 in progress. All four decisions made (see Decisions).

## Problem

Work that a land requests runs outside its turns (I/O, a verification run, another service), and its result has to come back as a turn input. The keeper has inputs only from clients (actions, client events) and lifecycle (initialize, join, leave). #385's reevaluation monitor works around that: its tick reads the runner service's status and results under a lock, a mailbox read outside "apply depends only on inputs" (named in CLAUDE.md and `2026-11-05-reentrancy-helpers.md`).

## Shape (public API approved 2026-11-09; see #387)

```swift
public protocol ServerInputPayload: Codable, Sendable {}

public enum ServerInputOutcome: Sendable, Equatable {
    case accepted(sequence: Int64)
    case refused(ServerInputRefusal)
}
public enum ServerInputRefusal: Sendable, Equatable {
    case draining, overCap, unknownType, notLive, unencodable
}

extension LandKeeper {
    public func submitServerInput<I: ServerInputPayload>(_ input: I) async -> ServerInputOutcome
}

// DSL, inside Rules { }
HandleServerInput(RunProgress.self) { (state: inout State, input: RunProgress, ctx: LandContext) in ... }
```

## Live path (mirrors the client event path)

`submitServerInput`, in one synchronous segment after `ensureInitialized()`:
1. `mode != .live` → refused. A replaying keeper takes its server inputs from the record only. This needs a fifth refusal, `.notLive`, which is an addition to the approved enum (see Decisions).
2. Unknown type: no `HandleServerInput` for `I`, matched by the type itself (a same-named type from another module or scope doesn't match) → `.unknownType`. No record form → `.unencodable`; the depth limit is checked with the payload inside its turn record, so an accepted input can't stop the recorder.
3. `isDraining` → `.draining`.
4. A debug freeze doesn't refuse. The input takes its sequence at submit and waits outside the queue (`serverInputsHeldWhileFrozen`) until the resume, which queues it and starts its turn. In the queue, a tickless drain or legacy pass already running would apply it during the freeze: they apply every ready input and don't stop for one. A land that drains while frozen drops the held inputs. Joins and leaves still run during a freeze (the freeze's existing contract), so on a tickless land one that arrives after a held input is applied before it, with a higher sequence. The record keeps the applied order (the passes list it) and replay follows it; holding joins too would change the freeze contract for every land.
5. In-flight cap → `.overCap`, counted. The cap is server inputs submitted but not yet applied, per land.
6. `sequence = outputCollector.takeNextSequence()`: the same counter as actions, client events and server events, taken at submit. `resolvedAtTick = lastCommittedTickId`.
7. Append `PendingItem.serverInput(PendingServerInputItem(sequence, typeIdentifier, payload: AnyCodable, resolvedAtTick))`.
8. A tickless land kicks its input turn as a client event does (`awaitInputTurn`, or `processPendingActions` off in-turn sync).

It returns `.accepted(sequence:)` without waiting for the turn. Applying it is the land's job, and its outcome isn't the submitter's.

**Order:** `readyPendingItemsInOrder` sorts by `(resolvedAtTick, sequence)` across all kinds. A server input and client inputs submitted in the same tick are applied in submission order, interleaved, and the record keeps that order.

**The cap:** a new key, `EnvKeys.Runtime.serverInputInFlightMaxPerLand` (`SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND`), default 64, where 0 means no cap. It is parsed next to `ActionJobLimits`. The count goes up at append and down when the item is applied, skipped or dropped by a drain. A refusal is counted (`serverInputCapRejections`, reported with the other limits in the profiler) and logged at debug.

## Apply

`applyPendingItem` gets a `.serverInput` case:
- the handlers come from the server input registry by type identifier;
- the context is the system identity (`systemPlayerID`, `systemClientID`, `systemSessionID`), with the executing tick ID;
- the input is recorded before its handlers run, like a client event;
- a throwing handler fails that input alone (`applyInputs`' rule).

## Declared types, not in the client schema

`HandleServerInput(T.self)` declares `T` in a new `serverInputRegistry` on `LandDefinition`. The type identifier is `String(describing: T.self)`, the rule recorded actions use. `LandBuilder` collects the node. `SchemaExtractor` doesn't read the registry, so neither SchemaGen nor `/schema` sees it.

Test: a land with a server input has the same extracted schema, byte for byte, as the same land without it.

## Record and replay

- **Entry:** `ReevaluationRecordedServerInput` (`kind: "serverInput"`, `sequence`, `typeIdentifier`, `payload`, `resolvedAtTick`).
- **Collection:** `AppliedInputs` gets a fourth list, and `appliedOrder` includes it.
- **Frames:** `ReevaluationTickFrame` and `ReevaluationLogRecord` get an optional `serverInputs`. A record without the key reads as none.
- **Passes:** tickless passes list server input sequences in `inputs`, like the others.
- **Format:** minor bump, 3.1 → 3.2 (`ReevaluationRecordLog.formatVersion`, `ReevaluationRecordVersion.current`).
  - A 3.1 reader ignores the new key, so it would replay a 3.2 record without its server inputs (a record made by a newer server, replayed by an older tool). Readers from 3.2 on refuse a newer minor; see Reader compatibility below.
  - Shared with #382 (`forceShutdown` as a `.shutdown` lifecycle input): if both are unreleased on `exp/next`, whichever lands second reuses the bump.
- **Replay on tick lands:** `runTick` reads `source.getServerInputs(for:)` and rebuilds `PendingItem.serverInput`, next to the client events.
- **Replay on tickless lands:** `replayRecordedPasses` covers it through the pass's `inputs`.
- **Payload form:** live applies the record form. At submit the input is encoded with the canonical record encoding and decoded back (`ServerInputCodec`), and the handler decodes `I` from it with the record codec, live and in replay. A `Date` therefore arrives at whole seconds both ways. A payload the canonical encoding refuses is refused (`.unencodable`).
- **Decoding:** by the registry at apply time. A recorded type the land doesn't declare fails the replay's tick (`takeRecordedPassMismatch`).
- **Reader compatibility (decided 2026-11-10: option (c)):** from 3.2 on, a reader refuses a record whose minor is newer than its own (`ReevaluationRecordLogError.newerMinor`, `ReevaluationRecordVersion.isReadable`). A 3.1 build can't refuse: it reads a 3.2 record and ignores its server inputs.

## How work outside the turns reaches the keeper

A turn that requests work has to give that work a way back. `LandContext` gets one more member: `serverInputs: ServerInputSubmitter`, a Sendable value bound to the land's keeper (weakly) that wraps `submitServerInput`. The turn passes it with its request, along with the ticket it took. This is a second API addition beyond the approved three (see Decisions).

## The monitor migrates (second PR)

- The ticket moves into the land's state (`state.runTicket`).
- `OnJoin` and the restart action take a new ticket in the turn, and call `requestVerification(..., ticket:, deliver: ctx.serverInputs)`.
- The driver submits `RunProgress { ticket, phase, totals, results }` as server inputs.
- `HandleServerInput(RunProgress.self)` drops a stale ticket and copies the rest into the state and events.
- The tick no longer reads the service.
- The exception goes from the land's doc comment, the reentrancy plan and CLAUDE.md (#387 scope item 3).

## Tests (first PR)

- A server input is applied in a turn, with the system context, and recorded.
- Refusals, each with its outcome and nothing appended: draining, over the cap (counted), unknown type, not live.
- Frozen (hold): freeze, submit → accepted and not applied; resume → applied once at the expected `(resolvedAtTick, sequence)`.
- Interleaving: client and server inputs submitted in one tick are applied in submission order.
- A throwing handler fails that input alone.
- Record and replay round trip: a tick land, and a tickless land through passes. The replay state hash equals live, and the replay needs no outside work.
- A 3.1 record still reads and replays. A frame without server inputs encodes exactly as before, with no `serverInputs` key.
- The client schema is unchanged by a declared server input.
- Mutants:
  - sequence taken at apply instead of submit;
  - cap not decremented;
  - refuse while frozen;
  - not recorded;
  - replay skips server inputs.

## PRs

1. Keeper, DSL, registry, record/replay, `ServerInputSubmitter`, with the tests above.
2. The monitor migration, and removing the exception lines.

Both on `exp/next`, before `exp/next` → `main`.

## Decisions (2026-11-09)

1. `ServerInputRefusal.notLive` and `LandContext.serverInputs` (`ServerInputSubmitter`): approved as additive API.
2. `LandKeeper.PendingItem` becomes `package` in PR 1 (nothing public takes or returns it).
3. Frozen: queue, as client events are; `.frozen` is not a refusal.
4. Reader compatibility: (c), decided 2026-11-10. Readers refuse a newer minor from 3.2 on (in its own commit); 3.1's silent drop of server inputs is documented (`docs/core/reevaluation.md` § Server Inputs (3.2)).

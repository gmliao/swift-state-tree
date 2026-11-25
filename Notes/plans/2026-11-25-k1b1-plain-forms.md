# K1b-1: the plain forms of the keeper's queued items (#700)

**Status:** rev 1, plan only, for Review. Read at #835's head 6657fce4, without the LSP. K1b-1 starts after #835 merges (K1b-Q3), and re-runs this census with the LSP on its base.

**What Review is asked to agree to:**
- **A deviation from the parent plan's A.7 F11 (a)** (§2, F11). (a) doesn't work for a live MessagePack land, and this plan replaces it.
- **One open check** (§2, K1-Q7 (d)): who reads a replay's own recorded resolver outputs. It is settled before that commit, and a test pins it.
- **Two open public questions,** K1b-Q4 and K1b-Q5 (§3), now with the maintainer. This plan is written against the recommended answers ("remove" and (a)) until they come.
- **Whether K1b-1 needs an A/B** (§5).

**Parent plan:** `Notes/plans/2026-11-22-keeper-on-turncore.md` rev 5.7. This plan covers Appendix A.7's K1b-1 row: F9, F10, F11, F3, `LandFailure`'s `@PlainData` and K1-Q7 (d). Each queued item type and `PendingItem` become `@PlainData`, and no field moves.

## 1. What is not plain today, at 6657fce4

Code pointers: `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`.

| Type (LK line) | Field | Why the walk refuses it | Finding |
|---|---|---|---|
| `PendingActionItem` (:227) | `actionType: any ActionPayload.Type` | a metatype | F9 |
| `PendingActionItem` | `decoded: Result<any ActionPayload, RecordedPayloadDecodeFailure>` | an existential inside `Result` | F10 |
| `PendingServerInputItem` (:139) | `decoded: Result<any ServerInputPayload, …>` | the same | F10 |
| `PendingClientEventPayload` (:310) | `.undecoded(AnyClientEvent)` | `AnyClientEvent.source` is `any PayloadDecodingSource`, a tree | F11 |
| `HeldResolverOutput` (LandContext.swift:310) | `.recorded(RecordedResolverOutput)`, whose `value` is `AnyCodable` | a tree | K1-Q7 |
| `PendingLandFailureItem` (:131) | `failure: LandFailure` | not `PlainData` yet | `LandFailure` |
| `PendingActionItem`, `PendingClientEventItem` | `recorded: RecordedPayloadBytes?` | not marked; `RecordPayloadEncoding` (public) isn't either | census addition |
| `PendingLifecycleItem` (:168) | `kind: LifecycleKind` | public enum, not marked | census addition |
| actor fields | `syncOutputIndexCursor` (:530), `pendingFold` (:841), `replayFailureEnd` (:4385) | tuples | F3 |

**Two census additions** beyond A.7: `RecordPayloadEncoding` and `LifecycleKind` are public enums that need `@PlainData`. Both are additions, so §8's K1b row lists them next to `LandFailure`.

Already plain: `PlayerID`, `ClientID`, `SessionID`, `RecordedPayloadDecodeFailure`, the payload protocols (`ActionPayload`, `ClientEventPayload`, `ServerInputPayload`, `ResolverOutput` refine `PlainData`). `Data`, `[String: String]`, `Int64` and `Bool` are plain.

The legacy public `PendingAction<ID>` (LK:351) also holds a metatype and a tree. It isn't a queued item, and nothing in Sources, Tests or Examples uses it. It is out of K1b-1's scope. Its removal would be a separate break, not proposed here.

## 2. Each change

### F9: the handler's index (K1b-Q1 (a))

- **A new package type,** `ActionHandlerIndex`. It is `@PlainData`, `Hashable` and `Sendable`, and it is **not `Codable`**. It holds `position: Int`. Its doc comment: "A position in this land's `definition.actionHandlers`. Valid only in this process; never persisted, sent or compared across runs." The type enforces the condition: a containing type's synthesized `Codable` fails to compile. A must-not-compile case pins that (CI only).
- **`PendingActionItem.handlerIndex: ActionHandlerIndex?`** replaces the stored `actionType`.
  - Live intake (LK:3150–3170) finds the handler with `firstIndex(where:)`, using today's `canHandle` match, and stores the index.
  - The replay build (LK:4590) finds it with today's `String(describing:)` match and its last-component fallback, and stores the index. It still knows the handler when the payload didn't decode.
  - The public init stores `nil`. It holds a decoded value.
- **Apply** (LK:3810) takes `definition.actionHandlers[index.position]` when there is an index. Otherwise it looks up `canHandle(type(of: value))`, as today for that init. A debug assertion checks the bound. `definition` is fixed at init, so the index can't go stale within the keeper.
- **The record's `typeIdentifier`** (LK:3846) becomes `String(describing: handler.getActionType())`. That is the same string: the handler was found by `canHandle(actionType)`, so the two types are equal.
- **Public `actionType`:** rev 5.7 §8 leaves "removed, or an optional computed" open. **Recommended: remove it.** Nothing in Sources, Tests, Examples or docs reads it. An optional computed form would be a break too, and its `nil` (a replayed item whose payload didn't decode) would be a trap. This is K1b-Q4 below.

### F10: a package enum per kind

- **`DecodedAction`**: `case value(any ActionPayload)`, `case failed(RecordedPayloadDecodeFailure)`.
- **`DecodedServerInput`**: the same shape, with `any ServerInputPayload`. `PendingClientEventPayload` and `InputOutcome` have that shape and compile under the walk.
- Each enum gets a `get() throws` helper with `Result.get`'s meaning. Apply's two switches (LK:3825, :3966) keep their shape, and the existing test that reads `item.decoded.get()` (RecordedPayloadReplayTests.swift:336) compiles unchanged.
- **Sites:** LK:260 (the public init), :3227, :3247, :3487, :3825, :3966, and the replay builds (around :4640 and :4703).
- **Not chosen:** teaching the walk `Result` (A.7's (b)). That is a SwiftStateTurns macro change and belongs to the PlainData plan.

### F11: decode at intake with the descriptor's type, keep the drop (a deviation from A.7 F11 (a))

A.7 recommended holding bytes and rebuilding the `AnyClientEvent` at apply. **That doesn't work for a live MessagePack land.** A live keeper has `RecordPayloadDecoders.jsonOnly`: the default, and nothing in Transport or NIO passes another (`payloadDecoders:` is passed only by `ReevaluationEngine` and the runner). Its apply step couldn't rebuild a MessagePack source from bytes. This plan replaces it.

**Today:** a descriptor from the public init has no `decodeClientEvent`. Intake queues the `AnyClientEvent` (LK:3358). Apply finds the one handler with `canHandle(descriptor.type)` (LK:3877) and calls `handler.invoke`. That runs `validateRecordable()` and `decode(E.self)`, and **drops** the event on failure. A too-deep payload is also counted (`noteDroppedClientEvent`). The handler's `E` is `descriptor.type`, because `canHandle` compares the two types for equality.

**Change:**
- **Intake and the replay build** (LK:3350, :4660): a descriptor without a decode is decoded with `AnyEventDescriptor.clientEventDecoder(for: descriptor.type)`, after `validateRecordable()`. That is the same decode the handler ran.
  - A success is held as `.decoded`.
  - A failure is held as `.failed(RecordedPayloadDecodeFailure(error))`, and **not refused**. Apply's `.failed` case already drops it and counts a too-deep one. So the client sees what it sees today: no error, and the event is recorded and then dropped. A descriptor with a decode keeps #537's refusal.
  - A `descriptor.type` that isn't a `ClientEventPayload` has no decoder. No handler can match it (every handler's `E` is a `ClientEventPayload`), so apply skips it at the handler lookup, as today. Its item is held as `.failed`.
- **`.undecoded` is removed** once the public item init (K1b-Q5) stops making it.
- **Cost:** the decode moves from apply to intake, and no extra encode is added. No DSL-built land has such a descriptor: the DSL and the `EventRegistry` paths use `clientEventDecoder`.

### K1-Q7 (d): a recorded resolver output as bytes

- **`RecordedResolverOutput`** holds `typeIdentifier`, `integralFloats` and its encoded tree as a package `@PlainData` enum: `case bytes([UInt8])` or `case failed(RecordedPayloadDecodeFailure)`. `value: AnyCodable` goes.
- **`replayedResolverOutputs`** (LK:1352) encodes each tree once with `CanonicalMessagePack.encode`. A failure (past the canonical depth) is held as `.recordTooDeep` (#817).
- **The read,** `LandContext.resolverOutput(_:named:)` (LandContext.swift:282), decodes with `CanonicalMessagePack.decode(_:from:integralFloats:)`. A failed output reads `nil` with today's warning.
- **The open check: the replay's own record entries.** `recordedEntries` (LandContext.swift:336) projects a `.recorded` output back to a tree, and replay records its applied inputs: `recordsInputs` is true when `mode != .live`, at LK:3842, :4021 and :1582. With bytes, that projection decodes them to an `AnyCodable` tree. Before the K1-Q7 commit, K1b-1 finds every reader of the replay's recorded resolver outputs (the export and the per-tick comparison). The test below pins that each reader sees the record's tree. If one compares trees exactly and the canonical round trip changes a tree (an `Int` that comes back as a `Double`), it gets fixed in K1b-1 rather than worked around.

### `LandFailure`, and the other public enums

`@PlainData` on `LandFailure`, `LandFailure.Kind`, `LandFailurePosition`, `LandFailurePosition.Stage`, `RecordPayloadEncoding` and `LifecycleKind`. All are additions. `RecordedPayloadBytes` (package) gets it too.

### F3: three tuples become structs

| Field | Struct | `@PlainData` |
|---|---|---|
| `syncOutputIndexCursor` | `SyncOutputIndexCursor { observedTickId: Int64?, count: Int }` | yes |
| `replayFailureEnd` | `ReplayFailureEnd { tickId: Int64, pass: Int64? }` | yes (a replay field; K2 moves it) |
| `pendingFold` | `PendingFold { deadline: ContinuousClock.Instant, overdueAtFold: Bool }` | no: F4's `Instant` exception, until K2 |

These are field renames inside the actor, with no behavior change.

### The items and `PendingItem`

`@PlainData` on:
- `PendingItem`;
- `PendingActionItem`, `PendingClientEventItem`, `PendingLifecycleItem`, `PendingServerInputItem`, `PendingShutdownItem` and `PendingLandFailureItem`;
- `PendingClientEventPayload`, `HeldResolverOutput` and `RecordedResolverOutput`.

They are nested in the generic actor `LandKeeper<State>`. The first implementation commit checks that the macro expands there, with the LSP. If it doesn't, the items move out to file scope under the same names, as package types with `LandKeeper` typealiases.

## 3. Open public questions (with the maintainer)

Both are open. This plan is written against the recommended answers until they come.

**K1b-Q4. `PendingActionItem.actionType`: remove it, or keep an optional computed one?** Recommended: remove (see F9). Either way it is K1b's one break on that type.

**K1b-Q5. `PendingClientEventItem`'s public init.** It takes an `AnyClientEvent`, which is a tree, and makes `.undecoded`. Nothing public consumes an item: `PendingItem` is package, and no public function takes one. Options:
- **(a), recommended:** it takes the typed event (`some ClientEventPayload`), as K1a's action init does (K1-Q8 (a)). It encodes the event once as canonical JSON and holds the value those bytes decode to. A break on the init's signature, symmetric with K1a.
- (b) Remove both public item inits. That is a larger break, with no user to weigh against.
- (c) Keep the signature. The item holds the event's bytes in a new case, decoded at apply with the keeper's decoders and the descriptor's type. This adds a decode-at-apply path only this init reaches, and a MessagePack event built by package code can't be read on a live keeper (`.jsonOnly`).

## 4. Commits

1. **Tests only, green on #835's merge** (A.7: "the first commit is tests only and green on K1a"):
   - `recordedScalarResolverOutputReadsAsBefore`: K1-Q7's pin, as rev 5.7 describes it (a retroactive `extension Int: ResolverOutput` in the test target).
   - `recordHoldsOnlyTheActionTypeName` (F9, the decision's condition): a land with two action handlers records an action of the second. The action entry's JSON has exactly today's key set, and `typeIdentifier` is the type's name.
   - `replayFindsTheHandlerAfterTheHandlersAreReordered` (F9): record on a land, replay on the same land with its action handlers in the other order. The replay completes with no mismatch.
   - `publicDescriptorEventRunsAndDropsAsBefore` (F11): an event registered through the public descriptor init, on the json and messagepack presets (Transport tests), recording on and off. A decodable payload runs the handler with the value. An undecodable one gets no error to the client, is recorded, and is dropped. A too-deep one is dropped and counted once. The same events replay the same way.
   - `replayRecordsTheRecordedResolverOutputs` (K1-Q7's open item): a replay's own recorded resolver outputs equal the record's, for an output with a `Data` field, from a 3.x record and from its JSON view (`integralFloats`).
   - The existing K1a tests already cover F10's behavior (a replayed payload that doesn't decode throws at apply, for actions and server inputs). The PR names them rather than duplicating them.
2. The public enums and `LandFailure`: `@PlainData` (additions).
3. F10: `DecodedAction` and `DecodedServerInput`.
4. F9: `ActionHandlerIndex`, plus the must-not-compile case (CI).
5. F11, with K1b-Q5's answer.
6. K1-Q7 (d).
7. F3.
8. `@PlainData` on the items and `PendingItem`, plus a compile pin: a test that calls a `requirePlain<T: PlainData>(_:)` helper for each item type and `PendingItem`.

`Sources/` and `Tests/` only; there's no Examples change.

## 5. Verification and mutants

- **Mac:** the build, the touched suites, and the full debug `swift test` before the push. E2E, release and must-not-compile run on CI.
- **Mutants (cloud):**
  1. Apply ignores `handlerIndex` and takes the first handler. Expected to fail the reorder test.
  2. Write the record's `typeIdentifier` from the index (`"\(position)"`). Expected to fail `recordHoldsOnlyTheActionTypeName`.
  3. Refuse an undecodable public-descriptor event at intake. Expected to fail `publicDescriptorEventRunsAndDropsAsBefore`.
  4. Drop the too-deep count in `.failed`. Expected to fail the same test's count.
  5. K1-Q7: decode with `integralFloats: false` always. Expected to fail the JSON-view case of `replayRecordsTheRecordedResolverOutputs`.
  6. The must-not-compile case: add `Codable` to `ActionHandlerIndex`. The case then compiles, and the check fails.
- **Measurement: none proposed; Review judges.** What moves on the live path:
  - an action item stores an optional index instead of a metatype, and apply indexes the handler array instead of scanning it with `canHandle`;
  - `DecodedAction` and `DecodedServerInput` replace `Result`, with the same payloads;
  - F11 moves an existing decode from apply to intake, only for events whose descriptor came from the public init. No DSL-built land has one, and no benchmark land does;
  - K1-Q7 and the replay builds are replay only.

  If Review sees a hot path moving, K1b-1 gets the small A/B.

## 6. Boundary with K1b-3 (the RNG)

Agreed with K1b-3's author, against `2026-11-25-k1b-3-land-rng-into-model.md` rev 2.1. K1b-3 reads and changes none of these: `PendingItem`, the item types, live intake, the replay builds, `replayedResolverOutputs`, `resolverOutput`, `RecordedResolverOutput`, `recordedEntries`, or F3's three fields.

**The one overlap: the handler-call wrappers in apply.** K1b-3 rewraps every handler call that takes a context: `withMutableStateSync { … }` becomes `withHandlerStep(ctx) { state, ctx in … }`. Four of those calls are in the apply cases K1b-1 reshapes:
- the action at LK:3861;
- the client event at LK:3917 and LK:3919 (`.decoded` and `.undecoded`; F11 removes the second);
- the server input at LK:3969.

The lines are at 5baa1887. The rule: K1b-1 keeps each handler call in its own statement, and whichever PR lands second redoes the wrapper by hand. The lifecycle cases (LK:4061, :4084, :4107) follow the same rule if K1b-1 touches them. K1-Q7 doesn't change their handler calls.

**Not shared:**
- `LandContext.swift`: K1b-1 doesn't touch `LandContext`'s memberwise init or its stored-field block, where K1b-3 adds `stepRandom`, or `random`.
- `LK`: K1b-1 doesn't touch `makeContext`, the RNG registration in the init, `getRngSeed`, `replayInitializeBeforeTickZero`, the tick, sync, drain or destroy paths.

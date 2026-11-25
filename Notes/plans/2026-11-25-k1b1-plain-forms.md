# K1b-1: the plain forms of the keeper's queued items (#700)

**Status:** rev 2.1, plan only. Review: GO on rev 2 (0 must-fix, 5 shoulds, 1 nit; 2026-11-25), and rev 2.1 takes the shoulds without a further round. K1b-Q4 and K1b-Q5 are decided (§3). Read at #835's head 6657fce4, without the LSP. K1b-1 starts after #835 merges (K1b-Q3), and re-runs this census with the LSP on its base. Line numbers are 6657fce4's.

**Parent plan:** `Notes/plans/2026-11-22-keeper-on-turncore.md` rev 5.7. This plan covers Appendix A.7's K1b-1 row: F9, F10, F11, F3, `LandFailure`'s `@PlainData` and K1-Q7 (d). Each queued item type and `PendingItem` become `@PlainData`, and no field moves.

**Rev 2.1** takes Review's shoulds on rev 2 and the two decisions:
- **S1:** F11 carries step 1's bytes, and the second encode goes. A keeper can't start recording after an item was queued.
- **S2:** `LifecycleKind` is already nested in the actor, so the compile pin starts in commit 2. The fallback keeps it nested.
- **S3:** K1-Q7 states the shortcut it removes, and maps every eager-encode failure, not only depth. It also says what the projection does when bytes don't project back.
- **S4:** F11's depth case is the recording-off direct-source one.
- **S5:** mutant 7 gets a named seam. A `.failed` server input stays out of the handler wrapper too, and the Q5 identifier default is `_payloadWireName`.
- **Nit:** the A/B's cells are named, and the layout line is corrected.
- **K1b-Q4 decided (a), remove, and K1b-Q5 decided (d)** by the maintainer: the two item types and their inits become `package` (§3).

**Rev 2** answers Review's NOT GO on rev 1 (3 must-fix, 6 shoulds, 2 nits, all taken):
- **MF1:** K1-Q7's readers are named, and the replay projection's contract is stated (§2, K1-Q7). Rev 1's test 5 and mutant 5 observed nothing: a reevaluation keeper has no recorder. They are replaced by the typed reader's existing test.
- **MF2:** F9's "not `Codable`" is pinned inside the package, by a runtime check with a positive control. The must-not-compile harness builds an external package, which can't name a `package` type.
- **MF3:** rev 1's F11 test is split into three cases, each matching today's gates before the one under test (§4).
- **S1:** F11 states what moves: user decode code runs at intake, before the drop. A failed item keeps its bytes. The replay build doesn't decode for a descriptor that apply would skip.
- **S2:** F9 uses live intake's real 4-way name match, carries the index through the job copy, and skips an out-of-range index with a log.
- **S3:** the file-scope fallback keeps the public item types public. The compile pin moves to the first commit that needs it.
- **S4:** the small A/B runs (§5).
- **S5:** Q4 and Q5 dependencies, and the public additions, are listed (§3).
- **S6:** the boundary with K1b-3 adds F3's two sites, and `.failed` leaves the handler wrapper (§6).
- **Nits:** F10's existing pins are named.

Review agreed to rev 1's F11 replacement: "same decode, same drop, same count" holds for an event that gets past intake.

## 1. What is not plain today, at 6657fce4

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`.

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

**Already plain:**
- `PlayerID`, `ClientID`, `SessionID`;
- `RecordedPayloadDecodeFailure` and `InputOutcome`;
- the payload protocols, which refine `PlainData`;
- `Data`, `[String: String]`, `Int64` and `Bool`.

`LandFailure`'s fields are all plain (a `String?`, case-only enums, optional integers). `RecordPayloadEncoding` and `LifecycleKind` are case-only enums.

**Out of scope:** the legacy public `PendingAction<ID>` (LK:351) also holds a metatype and a tree. It isn't a queued item, and nothing in Sources, Tests or Examples uses it. Removing it would be a separate break, not proposed here.

## 2. Each change

### F9: the handler's index (K1b-Q1 (a))

- **`ActionHandlerIndex`**, a new package type. It is `@PlainData`, `Hashable` and `Sendable`, and **not `Codable`**. It holds `position: Int`.
  - Its doc comment: "A position in this land's `definition.actionHandlers`. Valid only in this process; never persisted, sent or compared across runs."
  - `PlainData` requires only `_plainDataCheck` (SwiftStateTurns/PlainData.swift:16). It doesn't refine or synthesize `Codable`, so the type stays non-`Codable` unless someone adds the conformance.
  - **The pin (MF2)** is a test in the package. It checks `!(ActionHandlerIndex.self is any Encodable.Type)` and `!(ActionHandlerIndex.self is any Decodable.Type)`. A positive control checks that a `Codable` type in the same test does pass the cast. `scripts/check-must-not-compile.sh` builds an external package against the library product (:44–68), and that package can't name a `package` type, so a snippet there would fail on access whatever the conformance.
- **`PendingActionItem.handlerIndex: ActionHandlerIndex?`** replaces the stored `actionType`.
  - **Live intake** finds the handler with `firstIndex(where:)` over the same predicate as today (S2). That predicate is a 4-way name match against the envelope's type identifier, LK:3136–3165: the full name, the last component, the schema name, and the schema name case-insensitively. The intake then still casts `getActionType()` to `any ActionPayload.Type` to decode, as today.
  - **The resolver job** carries the index: `with(heldResolverOutputs:resolvedAtTick:)` copies it with the other fields.
  - **The replay build** (LK:4590) finds the handler with today's `String(describing:)` match and its last-component fallback, and stores the index. It still knows the handler when the payload didn't decode.
  - **The public init** stores `nil`, and holds a decoded value.
- **Apply** (LK:3810) has three cases:
  - **With an index:** it uses the handler at that position. An index outside `definition.actionHandlers.indices` is logged and skipped (`.skipped`), as a missing handler is at :3815–3818. `definition` is fixed at init, so this can't happen within one keeper, but it isn't left to an assertion.
  - **Without an index:** the item holds a value, so apply looks up `canHandle(type(of: value))`, as today for that init.
  - **Without an index and with `.failed`:** that can't be built (only replay builds `.failed`, and it always sets the index). If it ever reached apply, it throws `failure.error` after the handler lookup, as a failed item does today.
- **The record's `typeIdentifier`** (LK:3846) becomes `String(describing: handler.getActionType())`. That is the same string as today: apply found the handler by `canHandle(actionType)`, so the two types are equal.
- **An invariant this relies on, stated (S2).** A hand-built definition can hold two action handlers whose types share a last component. Replay's last-component fallback then takes the first match, as it does today. The DSL refuses that collision (`LandBuilder`, #599's shared-name check), so only a definition built without the DSL can reach it. K1b-1 doesn't change that.
- **Public `actionType`:** removed (K1b-Q4, decided; §3).

### F10: a package enum per kind

- **`DecodedAction`**: `case value(any ActionPayload)` or `case failed(RecordedPayloadDecodeFailure)`.
- **`DecodedServerInput`**: the same shape, with `any ServerInputPayload`. `InputOutcome` has that shape and compiles under the walk.
- Each enum gets a `get() throws` helper, with `Result.get`'s meaning. Apply's two switches (LK:3825, :3966) keep their shape. The Transport test that reads `item.decoded.get()` (`RecordedPayloadReplayTests.swift:328–337`) compiles unchanged.
- **Sites:** LK:260 (the public init), :3227, :3247, :3487, :3825, :3966, and the replay builds (about :4640 and :4703).
- **Existing pins of F10's behavior:**
  - `ReplayPayloadDecodeFailureTests.swift:131`, :148 and :161;
  - `ReplayServerInputDecodeFailureTests.swift:206` and :227.

  They pin the refusal, the drop, the count and the logged text for actions, client events and server inputs. They must stay green unchanged.
- **Not chosen:** teaching the walk `Result` (A.7's (b)). That is a SwiftStateTurns macro change, and belongs to the PlainData plan.

### F11: decode at intake with the descriptor's type, keep the drop (a deviation from A.7 F11 (a), agreed by Review on rev 1)

**Why A.7's (a) doesn't work.** (a) holds the bytes and rebuilds the `AnyClientEvent` at apply. But a live keeper has `RecordPayloadDecoders.jsonOnly`: that is the default, and only `ReevaluationEngine` and the runner pass `payloadDecoders:`. So a live MessagePack land's apply step couldn't rebuild a source from bytes.

**Today.**
- A descriptor from the public init has no `decodeClientEvent`. Intake queues the `AnyClientEvent` (LK:3358).
- Apply finds the one handler with `canHandle(descriptor.type)` (LK:3877), and calls `handler.invoke`.
- `invoke` runs `validateRecordable()` and `decode(E.self)`. It **drops** the event on failure, and counts a too-deep one (`noteDroppedClientEvent`).
- `canHandle` is metatype equality, so the handler's `E` is `descriptor.type`.

**The change, at live intake (LK:3345–3368), in this order:**
1. The recorded bytes, when the land records (`RecordedPayloadBytes(of:)`, LK:3362). Their refusal stays ahead of the new decode (S1): a too-deep or non-finite payload on a recording land is refused with an error to the client and never queued, as today.
2. For a descriptor without a decode, `AnyEventDescriptor.clientEventDecoder(for: descriptor.type)`, after `validateRecordable()`. That is the call the handler made (EventRegistry.swift:50–59).
   - A success is held as `.decoded`.
   - A failure is held as `.failed(RecordedPayloadDecodeFailure(error))`, and **not refused**. Apply's `.failed` case drops it and counts a too-deep one, once and with the same type string. So the client sees what it sees today: no error, and the event is recorded and dropped. A descriptor with a decode keeps #537's refusal.
3. **The item's bytes are step 1's (rev 2.1, S1).** On a recording keeper, step 1 made them, and the item carries them on success and on failure alike. With recording off, `recorded` stays `nil`: apply appends a record entry only when `recordsInputs`, so nothing reads it.
   - A keeper can't start recording after an item was queued. `reevaluationRecorder` is set only in `init`, and `mode` is fixed (LK:1198–1223). So rev 2's "queued before recording began" case can't happen, and there's no second encode.
   - A second `try?` encode would have recorded `Data()` tagged `.json` in place of bytes that passed step 1.

**The replay build (LK:4660).** It decodes only when `definition.eventHandlers` has a handler for `descriptor.type` (S1). Otherwise apply skips the event at its handler lookup, so no decode runs for it. The item is then `.failed`, which apply never reads.

**What moves (S1), written down:**
- A public-descriptor event's `Decodable` code now runs at intake, not at apply.
  - It runs for an item that a later shutdown or land failure discards. It also runs in replay when the frame's items are built, before the frame's passes run.
  - The result is the same only for a deterministic decoder, which a replayable payload's decoder must be anyway.
- **The no-handler case is replay-only.** Live intake already refuses an event without a descriptor (LK:3320–3343). A descriptor whose type isn't a `ClientEventPayload` can't match a handler, because every handler's `E` is one.
- **Cost:** a decode moves from apply to intake. A failure adds one encode for its bytes. No DSL-built land has such a descriptor: the DSL and the `EventRegistry` paths use `clientEventDecoder`.
- **`.undecoded` is removed** once the public item init stops making it (K1b-Q5, decided (d): the init is removed with the type's demotion).

### K1-Q7 (d): a recorded resolver output as bytes

**Readers today (MF1):**
- **`replayedResolverOutputs`** (LK:1352), called at :1372, :4621 and :4733. It builds `.recorded` from the record.
- **`LandContext.resolverOutput(_:named:)`** (LandContext.swift:282) is the one typed read. `integralFloats` matters only here.
- **`recordedEntries`** (LandContext.swift:336). Its callers are OnInitialize (LK:1582), the action (:3842) and the lifecycle (:4021).
  - Live, they project live outputs (`.live`), never `.recorded`.
  - In replay, `recordsInputs` is true, so they project `.recorded` outputs too. But a reevaluation keeper has no recorder: `reevaluationRecorder` is created only when `mode == .live` (LK:1198–1223), and a tick writes its record only `if let recorder` (LK:4134). So nothing reads the replay's projection.
  - `HeldResolverOutputTests.swift:23` compares the projection's canonical bytes for a `.recorded` output.
- No export, verifier or Tools reader sees a replay resolver tree.

**The change:**
- **`RecordedResolverOutput`** holds `typeIdentifier`, `integralFloats`, and its encoded tree as a package `@PlainData` enum: `case bytes([UInt8])` or `case failed(RecordedPayloadDecodeFailure)`. `value: AnyCodable` goes.
- **`replayedResolverOutputs`** encodes each tree once, with `CanonicalMessagePack.encode`. A failure is held as `RecordedPayloadDecodeFailure(error)` (rev 2.1, S3): nesting past the canonical depth maps to `.recordTooDeep` (#817), and anything else, such as `EncodingError.invalidValue`, to `.undecodable` with its text.
- **The typed read** decodes with `CanonicalMessagePack.decode(_:from:integralFloats:)`. A failed output reads `nil`, with today's warning.
- **The shortcut it removes (rev 2.1, S3).** Today `RecordPayloadSource.decode` first tries `payload.base as? T` (PayloadDecodingSource.swift:110).
  - A tree read from a record file holds dictionaries and scalars, so only a scalar output type takes the shortcut. `recordedScalarResolverOutputReadsAsBefore` pins that case.
  - An in-memory record that was never encoded can hold the typed value itself: the live projection writes `AnyCodable(output)` (LandContext.swift:340). Today, a replay of such a record casts it. After (d), it goes through the codec, as a replay of a file already does.
  - The result differs only for an output whose `Codable` doesn't round trip, which a recorded output's type must do anyway. Or the decode throws where the cast succeeded, which then reads `nil` with the warning.
  - The commit re-runs the tests that build recorded outputs from values: `ReevaluationRecordLogTests.swift:476`, `ReplayJSONAllowanceTests.swift:139`, `HeldResolverOutputTests.swift:28`, and the replay suites that replay an in-memory recording. Each must stay green. A change in any of them is reported in the PR, not absorbed.
- **The projection's contract, for `.recorded`.**
  - It decodes the bytes back to an `AnyCodable` tree with `CanonicalMessagePack`, and a `.failed` output is left out of the projection.
  - When the bytes don't decode back to a tree, the output is left out too, with a warning that names it. One example is a `UInt` above `Int.max` under strict `integralFloats` (rev 2.1, S3).
  - It has no reader today, and its doc comment says so: "replay's projection has no reader; a future reader compares canonical bytes, not trees".
  - `HeldResolverOutputTests:23` builds its `.recorded` case from bytes, and still compares canonical bytes.
  - `integralFloats` can't be seen through this projection: `CanonicalMessagePack` unboxes an integer as `Int` before its `Double` branch, so both flag values give the same tree. That is why the pin is on the typed read.
- **The pins:**
  - `ReplayJSONAllowanceKeeperTests.swift:190` already reads an integral `Double` output from a JSON-view record, and gets `nil` when the source doesn't read JSON. The mutant "decode with `integralFloats: false` always" fails it.
  - `ResolverOutputReplayTests.swift:219` and :231 pin `Data` and the integral `Double` per record form, and the warning on a wrong type.
  - K1-Q7's `recordedScalarResolverOutputReadsAsBefore` is new (§4).

### `LandFailure`, and the other public enums

`@PlainData` on these public types: `LandFailure`, `LandFailure.Kind`, `LandFailurePosition`, `LandFailurePosition.Stage`, `RecordPayloadEncoding` and `LifecycleKind`. All are additions (§3). `RecordedPayloadBytes` (package) gets it too.

### F3: three tuples become structs

| Field | Struct | `@PlainData` |
|---|---|---|
| `syncOutputIndexCursor` | `SyncOutputIndexCursor { observedTickId: Int64?, count: Int }` | yes |
| `replayFailureEnd` | `ReplayFailureEnd { tickId: Int64, pass: Int64? }` | yes (a replay field; K2 moves it) |
| `pendingFold` | `PendingFold { deadline: ContinuousClock.Instant, overdueAtFold: Bool }` | no: F4's `Instant` exception, until K2 |

These are field-type changes inside the actor, with no behavior change. Each field keeps its name, as K1b-4's census expects.

**Sites:**
- `pendingFold`: its assignment in `runSync` (LK:6120) and its readers;
- `replayFailureEnd`: `runTick`'s read (LK:4786), :4346 and its setter (:4441);
- `syncOutputIndexCursor`: its readers and writers.

`runSync` and `runTick` are also K1b-3's (§6).

### The items and `PendingItem`

`@PlainData` on:
- `PendingItem`;
- `PendingActionItem`, `PendingClientEventItem`, `PendingLifecycleItem`, `PendingServerInputItem`, `PendingShutdownItem` and `PendingLandFailureItem`;
- `PendingClientEventPayload`, `HeldResolverOutput` and `RecordedResolverOutput`.

The types are nested in the generic actor `LandKeeper<State>`. `InputOutcome` compiles under the walk with this enum shape, but it isn't nested; `PendingClientEventPayload` isn't a precedent, since it isn't marked today. So nesting is checked by compiling, not by expanding the macro.
- **The compile pin** is a test that calls a `requirePlain<T: PlainData>(_:)` helper for a type. It lands in **commit 2** (rev 2.1, S2). Commit 2 marks `LifecycleKind`, which is already nested in the generic actor (`public enum LifecycleKind` inside `LandKeeper<State>`, LK:163), so commit 2 is the first that depends on nested expansion. Each later commit adds its types to the pin.
- **If the macro doesn't compile there,** the items move out to file scope under the same names, with `LandKeeper` typealiases of the same access (S3).
  - The public item struct `PendingLifecycleItem` stays **public**, with a public alias. The others are package after K1b-Q5 (d).
  - **`LifecycleKind` stays nested** (rev 2.1, S2). Moving it to one non-generic type would merge the distinct `LandKeeper<A>.LifecycleKind` and `LandKeeper<B>.LifecycleKind` into one type, which is a further break. If the macro can't expand on it there, that is reported, not worked around.

## 3. Public questions (decided) and the public changes

**K1b-Q4: decided (a), remove `PendingActionItem.actionType`** (maintainer, 2026-11-25). K1b-Q5's (d) demotes the whole type anyway.

**K1b-Q5: decided (d), a new option** (maintainer, 2026-11-25). `PendingActionItem` and `PendingClientEventItem`, with their inits, become `package`.
- **Who uses them, at 6657fce4:** only `LandKeeper.swift`, and one `@testable` test file (`RecordedPayloadReplayTests`). Nothing in Examples, Tools or other modules does.
- **Their public inits:**
  - `PendingActionItem`'s typed init becomes `package`, and the Transport test at `RecordedPayloadReplayTests.swift:328–337` keeps calling it through `@testable`.
  - `PendingClientEventItem`'s `init(event: AnyClientEvent)` is removed, because nothing calls it. That removes F11's last `.undecoded` source. If a caller turns up, it takes the typed event and defaults the identifier to `E._payloadWireName` (rev 2.1, S5). That keeps today's typed `AnyClientEvent` naming, a custom witness included.
- **No public declaration may name them.** `PendingItem` is already `package`. The compiler checks the rest: a public declaration that mentions a package type doesn't compile. Commit 2 runs that build before anything else changes.
- **Docs:** `docs/core/runtime.md:272–273` and its zh-TW copy list the two types in the queue enum. The passage is rewritten to describe the queue in concepts (an input of each kind, waiting for its turn), without internal type names, in both languages.

**The public changes, for §8's K1b row and the PR:**
- **Removals (maintainer-approved, K1b-Q4/Q5, 2026-11-25):** `PendingActionItem`, `PendingClientEventItem` and their inits are `package` now. `actionType` goes with the type.
- **Additions (`PlainData` conformances):**
  - `LandFailure`, `LandFailure.Kind`, `LandFailurePosition`, `LandFailurePosition.Stage`;
  - `RecordPayloadEncoding`, `LifecycleKind`;
  - `PendingLifecycleItem`, the one item struct that stays public.

## 4. Commits

1. **Tests only, green on #835's merge.** A.7 says the first commit is tests only and green on K1a. Each test matches today's behavior at every gate before the one it pins (MF3).
   - **`recordedScalarResolverOutputReadsAsBefore`** (K1-Q7): a retroactive `extension Int: ResolverOutput` in the test target, as rev 5.7 describes.
   - **`recordHoldsOnlyTheActionTypeName`** (F9, the decision's condition): a land with three action handlers records an action of the second one. The action entry's JSON has exactly today's key set, and `typeIdentifier` is the type's name.
   - **`replayFindsTheHandlerAfterTheHandlersAreReordered`** (F9).
     - Record on a land whose target handler is at position 1. Replay on the same land with the handlers rotated, so the target is at position 2: a different, nonzero position (S2).
     - The replay completes with no mismatch. Taking the recorded position, or the first handler, fails it.
   - **F11, three cases** (MF3). Each uses a hand-built registry with a public-init descriptor, because DSL registration makes a decoder.
     - **`publicDescriptorMalformedPayloadIsRecordedAndDropped`:** a shallow, wrong-typed payload whose bytes can be made, on the json and messagepack presets, recording on and off. The client gets no error, the event is recorded (when recording) and dropped, and the handler doesn't run. A decodable payload runs the handler with the value.
     - **`publicDescriptorUnrecordablePayloadIsRefusedAtIntake`:** recording on, a non-finite MessagePack number. `RecordedPayloadBytes(of:)` refuses it with `EVENT_INVALID_PAYLOAD`. Nothing is queued, and no sequence is taken.
     - **`publicDescriptorTooDeepPayloadIsDroppedAndCountedOnce`:** recording off, with a direct source, not through a frame decoder, which refuses past its own limit first (rev 2.1, S4). A direct MessagePack source throws `PayloadNesting.TooDeep` from `validateRecordable`, and a direct `AnyCodable` source throws it from the decode's tree check. Either exercises the new live fallback. The event is dropped, and `noteDroppedClientEvent` counts it once.
       - A replay JSON fixture isn't used: it fails while the source is built, which takes the existing replay-failure path.
       - Nor is a too-deep recorded MessagePack value: it fails to unpack with `invalidData`, which maps to `.undecodable` and isn't counted as too deep, today included.
   - F10 and K1-Q7's typed read keep their existing pins (§2), and the PR names them.
2. The public enums and `LandFailure`: `@PlainData` (additions).
3. F10: `DecodedAction` and `DecodedServerInput`, plus the compile pin, which starts here (§2).
4. F9: `ActionHandlerIndex`, with its in-package non-`Codable` pin and the out-of-range unit test.
5. F11, with K1b-Q5 (d): the two item types become package, the client event's `AnyClientEvent` init goes, and the docs passage is rewritten in both languages.
6. K1-Q7 (d), with the projection's contract and `HeldResolverOutputTests:23`'s bytes case.
7. F3.
8. `@PlainData` on the items and `PendingItem`. They join the compile pin.

Only `Sources/` and `Tests/` change; there's no Examples change.

## 5. Verification, mutants and measurement

**Verification on the Mac:**
- the build;
- the touched suites;
- the full debug `swift test` before the push.

E2E, release and must-not-compile run on CI.

**Mutants (cloud):**
1. Apply ignores `handlerIndex` and takes the first handler. Expected to fail the reorder test.
2. The record's `typeIdentifier` is written from the index (`"\(position)"`). Expected to fail `recordHoldsOnlyTheActionTypeName`.
3. Refuse a public-descriptor event whose fallback decode fails. Expected to fail `publicDescriptorMalformedPayloadIsRecordedAndDropped`.
4. Drop the too-deep count in `.failed`. Expected to fail `publicDescriptorTooDeepPayloadIsDroppedAndCountedOnce`.
5. K1-Q7: decode with `integralFloats: false` always. Expected to fail `ReplayJSONAllowanceKeeperTests.swift:190`.
6. Add `Codable` to `ActionHandlerIndex`. Expected to fail the in-package non-`Codable` pin.
7. Apply drops the `indices` guard on the index. Expected to fail the out-of-range unit test.
   - **The seam (rev 2.1, S5):** a package `applyPendingItemForTesting(_ item: PendingItem) -> AppliedItem` on the keeper. It runs the real `applyPendingItem` branch on one item, outside a turn, with a fresh `AppliedInputs`.
   - The test builds an action item with an out-of-range index through the package init, and expects `.skipped`, the log, and no record entry. Building the item alone can't observe either, because the queue and `applyPendingItem` are private.

**Measurement: the small A/B runs (S4).** Removing the handler scan and the layout changes touch the hot path.
- **Report:**
  - `MemoryLayout` size and stride of each item type and `PendingItem`, base and head. A tiny test prints them, and nothing is asserted. The layout moves because the items' fields change: the index for the metatype, the enums for `Result`, and `HeldResolverOutput`'s recorded form, which sits in live action and lifecycle items. A conformance adds no per-value storage;
  - action throughput, with instructions:u deciding;
  - malloc per action on `wide-tickless-mp`;
  - the parent plan's other small cells, by name: `default-production` and `rows-mp`.
- **The brief** is written for the measurement host when K1b-1 is pushed. Base is the merge base, and head is the PR.

## 6. Boundary with K1b-3 (the RNG)

Agreed with K1b-3's author, against `2026-11-25-k1b-3-land-rng-into-model.md` rev 2.1. K1b-3 reads and changes none of these: `PendingItem`, the item types, live intake, the replay builds, `replayedResolverOutputs`, `resolverOutput`, `RecordedResolverOutput` or `recordedEntries`.

**Shared: the handler-call wrappers in apply.** K1b-3 rewraps every handler call that takes a context: `withMutableStateSync { … }` becomes `withHandlerStep(ctx) { state, ctx in … }`. Three of those calls are in the apply cases K1b-1 reshapes:
- the action at LK:3860;
- the client event at LK:3914;
- the server input at LK:3963.

The lifecycle cases (LK:4060, :4083, :4106) follow the same rule if K1b-1 touches them. K1-Q7 doesn't change their handler calls.

The rule:
- K1b-1 keeps each handler call in its own statement.
- **`.failed` moves out of the client event's wrapper (S6).** The switch on the payload comes first, and only `.decoded` enters the wrapper. So a dropped event doesn't make K1b-3's step RNG service.
- **The same for a server input (rev 2.1, S5).** The decoded value is taken after the record append and before the wrapper. So a `.failed` server input throws before the wrapper, and doesn't allocate a step RNG either.
- Whichever PR lands second redoes the wrapper by hand.

**Shared: F3's two sites (S6).** `pendingFold`'s assignment in `runSync` (LK:6120) and `replayFailureEnd`'s read in `runTick` (LK:4786) are in functions K1b-3 also edits. Each is a one-line change of a tuple to a struct. The second lander redoes it by hand, as for the wrappers.

**Not shared:**
- `LandContext.swift`: K1b-1 doesn't touch `LandContext`'s memberwise init or its stored-field block, where K1b-3 adds `stepRandom`, or `random`.
- `LK`: K1b-1 doesn't touch `makeContext`, the RNG registration in the init, `getRngSeed`, `replayInitializeBeforeTickZero`, sync's or the tick's RNG use, the drain or destroy paths.

# A differential test harness for TransportAdapter's adoption levels (#555)

**Status:** rev 3, for review. **Issue:** #555 (part of #546). **Base:** `main` at cef7177c.

**Rev 3** answers the review of rev 2 (6f8a44df):
- the capture barrier is the transport's flush marker, after the producers settle (§5.3);
- each join stage is its own schedule, and the pre-admission disconnect holds before the keeper's admission (§8);
- the mutants compare against a stored clean capture (§7 (b));
- the assembly splits into a synchronous build and an async attach, and the refusal moves to the throwing init (§3, §4);
- the oracle uses per-request outcomes, live checkpoints and lifecycle counts (§5.6);
- the stop order is forced before the membership queue, client IDs are keyed by attempt, and capture is live then terminal (§5.3, §5.4);
- the count, the nightly switch and the record's completeness flag are stated (§9, §5.5);
- a shared test-support target is added (§3).

**Rev 2** answered the review of rev 1 (458c247c):
- a quiescence condition and positive milestones for the capture point (§5.3);
- a cell rule and a reach check for every hold (§8);
- stable identities instead of positional normalisation, and a forced leave order (§5.4);
- exact, one-use expected differences (§6);
- the `IN_TURN_SYNC=false` leg and the corrected counts (§9);
- an independent property oracle (§5.6);
- source mutants per channel (§7);
- one extracted assembly (§3);
- the record's 3.5 format (§5.5);
- the access path for the level (§4).

## 1. Goal

#546 moves `TransportAdapter` onto the turn core (`SwiftStateTurns`, #551) one slice at a time. An adoption level selects each slice, so a slice can land switched off and be compared with the code it replaces. This plan is the test that does that comparison. It runs the same scenarios at two adoption levels. It fails on any difference in what clients and the replay record see, unless the slice lists that difference as expected.

The harness ships before slice 1, with one level only, so its own checks (§7) run against the current adapter first.

## 2. Prior art

The harness borrows from two classic techniques. From each, it takes the failure modes the technique is known for, and §7 has a check for each row.

**Differential testing** (McKeeman, "Differential Testing for Software", Digital Technical Journal 10(1), 1998). Two implementations of one specification get the same inputs, and any difference in their outputs is a bug in one of them, found without writing the expected output down. Its known failure modes:

| Failure mode | What goes wrong | Where this plan handles it |
|---|---|---|
| Non-determinism | Two runs of the same side differ, so every comparison is noise | §5.4: stable client identities, fixed request IDs, a forced leave order, named record fields; §7 (a) same-level runs |
| A shared bug | Both sides run the same faulty code, so they agree and the bug passes | §5.6: a property oracle checked on each side alone, independent of both |
| Triage of differences | Real differences drown among known ones | §6: each entry names its cell and both outcomes, and is used exactly once |
| Input coverage | Only the orders the inputs reach are compared | §8: holds with a cell rule, and a hold that isn't reached fails; §10 lists what no scenario reaches |
| A vacuous or weak comparison | Two empty captures compare equal, or the comparator ignores what changed | §5.3: the flush barrier, two checkpoints and positive milestones; §5.7: per session, in order, byte for byte; §7 (b) source mutants per channel |

**Golden (snapshot) testing.** A run's output is stored as a file, later runs are compared with it, and a change to the file is reviewed like code. It detects an unintended change in output, here in the code both levels share. It is not a correctness oracle: a file records today's output, bugs included. Its known failure modes:

| Failure mode | What goes wrong | Where this plan handles it |
|---|---|---|
| Blind update | The update command rewrites every file, and nobody reads the diff | §5.8: an explicit key, readable files, and the PR names each changed file |
| A missing file passes | A new scenario without a file is accepted silently | §5.8: a missing file fails, except under the update key |
| Brittle output | Unrelated noise changes the file | §5.4's identities and field rules, the same as the differential side |
| Unreadable diffs | Binary frames give a diff nobody can review | §5.8: decoded frames and the decoded record, one file per cell |

## 3. Boundary and assembly

**The boundary** is the assembler: `LandRouter`, `LandManager` and the host's wiring, with a fake `WebSocketConnection` for each client. Everything below it is real: the transport, the adapter, the keeper, the sync engine, the encoders and the recorder. The adapter isn't driven directly. A slice can move work between the adapter and its neighbours, and a test at the adapter's own API would miss what moved.

**One assembly (Q1), in two parts.** Step 1 extracts `NIOLandServer`'s assembly, and both the host and the harness call both parts.
- **Build:** a synchronous `package` construction in `SwiftStateTreeNIO`. It builds the transport, the manager, the router and the adapter factory, and forwards `autoStartLoops` and `adoption`. `NIOLandServer.init` calls it, passing `true` and the configured level.
- **Attach:** an `async` `package` step. It installs the router as the transport's delegate, and wires the server's failure-stop callback onto the same stop registry an explicit stop uses.
  - It has to be async: `WebSocketTransport` is an actor whose `setDelegate` is actor-isolated (`WebSocketTransport.swift:242`).
  - The host awaits it before it publishes the route, as `NIOLandHost.swift:373–412` does today. So no frame arrives before the router is installed.
  - A direct caller of the public init keeps its own delegate, because the attach isn't part of the init.

Both callers get the same wiring, so no copy and no configuration test is needed. Sockets and HTTP stay in `NIOLandHost` and are out of scope (§10).

**Test targets.** The harness lives in `SwiftStateTreeNIOTests`, which already depends on `SwiftStateTreeNIO`, `SwiftStateTreeTransport` and `SwiftStateTree`. It needs two helpers that live elsewhere today:
- `TestGate` is in `SwiftStateTreeTransportTests`;
- `ShutdownConnection` is private in `GracefulShutdownTests`.

`Sources/SwiftStateTree/Support/Deadline.swift` already names the follow-up: move it and `TestGate` into a shared test-support target "once a second shared helper needs it". `RecordingConnection` is that second helper.

So step 1 adds a `SwiftStateTreeTestSupport` target to `Package.swift`. It holds `TestGate`, `Deadline` and `RecordingConnection` (`ShutdownConnection`, renamed), and `SwiftStateTreeTransportTests` and `SwiftStateTreeNIOTests` depend on it. Each move is its own commit, and the existing users switch to the shared copies. `Deadline` leaves `Sources`, so its `package` access no longer has to be there for tests.

**Compared, per scenario:**
- each session's frames, in order, byte for byte;
- each session's close: code and reason, or none;
- each request's response, derived from the frames (§5.7);
- the replay record (§5.5).

**Not compared:** counters, logs, admin routes and timing. A slice that needs one of them compared adds it explicitly.

**Shared code.** The keeper, the sync engine, the encoders, the transport and the recorder run on both sides. The property oracle (§5.6) checks them for correctness, and the golden files (§5.8) detect changes to their output.

## 4. Adoption levels

As #555 and #546 say: an environment key plus a `package` parameter, never public.

- **The enum:** `TransportAdapterAdoption`, a `package` enum in `SwiftStateTreeTransport`. `.legacy` is today's adapter. Each slice adds one case (`.membership` for slice 1, and so on), and each level includes the slices before it.
- **The env parser:** `TransportAdapterAdoption.fromEnvironment(_:)`, a `package` static function in Transport. It reads `TRANSPORT_ADAPTER_ADOPTION` (a constant in `TransportEnvKeys`) through `getEnvString`. NIO calls it, so `TransportEnvKeys` stays internal. Unset means `.legacy`. An unknown value is an error naming the known levels.
- **The parameter:**
  - `LandManager`'s existing `package` init (`LandManager.swift:303`) gains `adoption:`.
  - `NIOLandServerConfiguration` gains a `package var adoption: TransportAdapterAdoption?`, nil by default. A public init can't take a `package` type, so no public signature changes. Tests set the property as an override.
  - `NIOLandServer.init`, which throws (`NIOLandServer.swift:45`), resolves the level: the override if set, or else the parser's result. An unknown env value throws there. The configuration's public init doesn't throw, so the refusal can't be in it.
  - The extracted assembly (§3) passes the resolved level on.
- **Who uses which:** the harness passes the parameter, so both levels run in one process. The env key is for E2E and the load test, where the server runs in its own process.
- **Operator-facing behaviour:** the key is a server setting even though every declaration is `package`. In step 1, an unknown value is refused at startup with the list of known levels. That is new behaviour, and step 1's PR states it. The key goes into the server env docs when a second level exists.
- **Start:** the harness lands with `.legacy` only. Slice 1 adds `.membership` and the first real comparison.

## 5. The harness

### 5.1 Shape

```swift
struct DifferentialScenario {
    let name: String
    let cells: CellRule                  // sync modes and land kinds it applies to (§8)
    let connections: [ConnectionName]    // "A", "B", ...: the stable identities (§5.4)
    let steps: [ScenarioStep]            // connect, join, send(requestID:), tick, hold, release, disconnect, stop
    let milestones: [Milestone]          // what must be observed before capture (§5.3)
    let outcomes: [RequestOutcome]       // per request and connection attempt (§5.6)
}

struct Capture: Equatable {
    var frames: [ConnectionName: [Data]]          // in arrival order
    var closes: [ConnectionName: CloseInfo?]
    var responses: [ConnectionName: [RequestID: Data]]
}

struct RunResult: Equatable {
    var live: Capture                             // before the stop (§5.3)
    var terminal: Capture                         // after the stop
    var record: DecodedRecord                     // §5.5, after the stop
}
```

A scenario is data. One runner executes it at any level, sync mode and encoding, so a new scenario is one value and needs no new test code.

### 5.2 Fake connections

`RecordingConnection` (§3) captures each frame and the close (code and reason) in arrival order. There is no separate response callback, so responses come from the frames (§5.7).

### 5.3 The capture point

A run ends at a defined point, not when its last step returns. The trap is the one in `Notes/solutions/2026-11-10-a-returned-send-is-not-a-delivered-frame.md`: a returned send isn't a delivered frame. Three producers can still be busy after the last step:
- **`stepTickOnce()`** can return before its frames are sent. On a tickless land the input drain may be scheduled but not yet applied.
- **The adapter's outbound writer** hands frames to a per-session send queue in `WebSocketTransport`, which a drain task delivers later.
- **In-turn admission** starts a separate flip waiter.

**The barrier.** A session's drain task can't be awaited: it is a `for await` over a stream that lives as long as the connection (`WebSocketTransport.swift:110`), so awaiting it waits until the session ends. Outbound idle alone isn't enough either: it can return while a producer is about to enqueue, such as a deferred sync retry after `cycleBeforeEndSync` is released, or a pending action reply. And a join reply on the wire doesn't show that the router's `awaitFlip` (`LandRouter.swift:1309`) has set the session to joined.

The transport already has the right primitive. A `.flush(id)` element in a session's queue resumes its waiter when the drain reaches it (`flushSessionQueues`, `SessionFlushWaiters`). It is a barrier through the queue, not a wait for its end. The capture waits, in this order:
1. **The producers settle:**
   - each adapter's `waitForSyncQuiescenceForTesting`;
   - `waitForActionResponsesFinishedForTesting` with the scenario's action count;
   - no pending flip wait in the router. Step 1 adds that hook, which reports when the router has no `awaitFlip` in progress.
2. **Each adapter's outbound is idle:** `waitForOutboundIdleForTesting()`.
3. **The queues are flushed:** `flushSessionQueues()`, awaited, so every frame enqueued before it has reached its connection.

**Bounds and cleanup.** Each wait has a bound, through `raceDeadline`. A wait that hits its bound fails the run, naming the producer it waited on. After a failure, or a missed milestone, the runner releases every hold it set, stops the land and closes the fake connections. So one failed run doesn't leave a held task for the next one.

**Two checkpoints.** The stop produces leaves, closes and record entries of its own, so a capture taken before it misses them, and one taken only after it misses the live state.
- **Live:** the barrier, then a capture of frames, closes and responses. Convergence is checked here (§5.6).
- **Terminal:** stop each land once, the barrier again, a second capture, and then the record (§5.5).

**Positive milestones.** Each scenario lists what it must observe before capture. Examples: the join reply and the first sync for each session; each input applied; each response; each close. A milestone that isn't observed fails the run. A scenario with no milestone is refused as vacuous. So two empty captures can't compare equal.

### 5.4 Stable identities and order

- **Client identity:** `WebSocketTransport.handleConnection` makes a random `ClientID` from `UUID()` (`:435`). It appears in the record's lifecycle, action and client-event entries, and in event targets.
  - Step 1 adds a `package` hook on the transport that supplies the client ID, keyed by connection attempt, not by `SessionID`. So a scenario that reuses a session ID, as #548's reconnect may, still gets a distinct identity per attempt. The harness names each attempt (`A`, `A2`), and that name is in every reference to it on both sides. The public entry point and its six-character default stay as they are.
  - Positional normalisation ("first", "second") is not used. It would make "both actions came from A" equal to "the second action came from B", and hide exactly the routing difference a membership slice could introduce.
- **Other IDs:**
  - session IDs, player IDs and land IDs are named by the scenario;
  - request IDs are fixed in the input frames;
  - `rngSeed` is kept as it is, since both sides seed the same way.
- **Leave order at stop:** a server stop snapshots its bindings from a dictionary and starts concurrent leave tasks (`LandManager.swift:714–745`, `LandRouter.swift:437–465`). So two leaves on one land can be enqueued in either order.
  - A hold at the keeper's `.leave` is too late: by then the router's stop tasks have already raced to enter the adapter's serial membership queue.
  - Step 1 adds a router hold at each stop task's entry, keyed by session, before the enqueue. A scenario whose output depends on the order releases those holds one at a time, each after the previous leave is observed in the membership queue.
  - A scenario with one player per land doesn't need it.

### 5.5 The record

- **Format.** `recorder.save` finalises a binary SSTR 3.5 record: metadata, ordered turns, the sync stream, sequence watermarks and a footer. The harness compares that format, decoded into its Swift types. `encodeJSONViewForTesting()` gives only the older 2.6 view, so it isn't used.
- **Capture.** At the terminal checkpoint (§5.3): after the stop, the barrier and the recorder's submissions have settled, the record is saved.
- **Completeness.** A 3.5 footer can say it is incomplete (`ReevaluationRecordCompleteness.incomplete`, `ReevaluationRecordLog.swift:51`), so having a footer isn't enough. The harness asserts that the decoded completeness is `.complete`.
- **Decoder access.** The log decoder (`ReevaluationRecordLog.read`) is internal to `SwiftStateTree`. Step 1 adds a `package` entry that returns the decoded contents, so the comparison keeps the sync stream and the watermarks. `@testable` would work too, but it needs testing builds, which a release test run doesn't have.
- **Fields.** Each field that depends on the wall clock or the process is named in a list in the harness, with its rule:
  - wall-clock metadata (`createdAt` and the like): replaced with a constant;
  - client IDs: already stable (§5.4);
  - everything else: compared as it is.
- **Field-list test.** A test walks the decoded record type itself, nested fields included, not fixtures. It fails when a field is neither on the list nor known to be stable. So a new optional field that no fixture has still fails until it is classified.

### 5.6 The property oracle

The differential comparison can't see a bug both levels share. An oracle independent of both sides can. Each run checks, on each side alone:
- **convergence, at the live checkpoint:** each client's decoded state equals the keeper's per-player view for that player, as the E2E convergence check and `RowAddressingAdapterTests`' oracle do. A scenario must have at least one live client at its live checkpoint, or it is refused, so the check can't compare nothing;
- **request outcomes:** each request gets the outcome its scenario states for its connection attempt: one reply, an error frame correlated by request ID, or none. "A stale action reply after a leave" states none, so a correct run passes it. Each joined attempt gets exactly one join reply;
- **lifecycle:** the record's join and leave entries match the identities and counts the scenario states (for example A joins and leaves, A2 joins and leaves). So a record with both of a pair dropped fails too. No OnLeave lacks its OnJoin.

A property failure fails the run whether or not the two sides agree.

### 5.7 Comparison and responses

- **Frames:** per session, in order, byte for byte. Same encoding on both sides, so the bytes match when the behaviour matches. Today's `expectSameFrames` (`DirtyTrackingByteIdentityTests.swift:241`) already compares ordered bytes per target, after a total count. The harness has its own comparison for its report shape, and for the closes, responses and record.
- **Responses:** derived from each side's frames by request ID, strictly. A frame that should be a response but doesn't decode as one fails the run. So does a response that differs from the outcome the scenario states (§5.6). Nothing is dropped by a `compactMap`.
- **Report:** on a mismatch it names the scenario, the cell (sync mode, encoding, land kind), the connection and the index of the first differing frame. It shows both frames decoded (JSON), and the steps run before that frame.

### 5.8 Golden files (Q2)

Golden files are change detection on shared code, not a correctness check (§5.6 is that).
- **Set:** two scenarios, each with a file per cell: the two-player join–act–leave scenario and the land stop with players. File name: `Tests/SwiftStateTreeNIOTests/Differential/Golden/<scenario>.<sync>.<encoding>.<land>.json`. Each file holds the decoded frames per connection, the closes, the responses and the decoded record.
- **Compare:** the `.legacy` result against the file. A missing file fails.
- **Environment:** the CI legs differ by env settings that change frames (the tables-off and per-player-tables-off runs in `build-and-test.yml`). The harness pins each such setting through its parameters, so a golden doesn't depend on the leg. A setting it can't pin goes into the file's key.
- **Update:** with `SST_UPDATE_GOLDEN=1` only, a named constant beside the harness. The update rewrites the files and prints the changed paths. A PR that changes a golden file names it in its body, and review reads the diff.

## 6. Expected differences

A slice may change behaviour on purpose, mostly where it fixes a race. It lists those differences in its test file:

```swift
struct ExpectedDifference {
    let issue: Int
    let scenario: String
    let cell: Cell                    // sync mode, encoding, land kind; one cell per entry
    let connection: ConnectionName?
    let legacy: Outcome               // the exact outcome on the reference side
    let adopted: Outcome              // the exact outcome on the slice's side
    let why: String
}

enum Outcome: Equatable {
    case frames([Data])               // the whole frame list for that connection
    case close(code: UInt16, reason: String)
    case noClose
    case response(RequestID, Data?)   // nil: no response
    case recordField(path: String, value: DecodedValue)   // value may be .absent
}
```

- **Exact:** an entry excuses a difference only when both sides' outcomes equal its `legacy` and `adopted` values in its cell. There is no "from this frame on" form. A wrong close code or a different later frame stays a failure.
- **One use:** each difference consumes at most one entry, and each entry is consumed exactly once per run. These fail:
  - an unused entry (stale);
  - two entries that match the same difference (overlap);
  - one entry that matches two differences.
- **Several cells:** an entry for several cells is written once per cell. A helper builds those, so the cells stay explicit.
- **Absent on one side:** an outcome can be `absent`, for something one side has and the other doesn't, such as a lifecycle entry the adopted side never records. `recordField(path:value:)` takes `.absent` as its value, and `frames([])` means no frames at all.
- **Masked cells:** selectors are checked against the cells that ran. An entry for a cell the run masked (the in-turn-on cells under `IN_TURN_SYNC=false`) is not reported as stale.
- **The PR body:** each slice's PR states its list, one line per entry.

**The first list** (slice 1, membership) starts with the two entries #555 names:
- **#548, a teardown during the keeper join.** Today the admission re-creates membership and the connection generation on a torn-down adapter. With the turn core, the join's ticket is captured when it is enqueued, so after the teardown the admission does nothing.
  - Both levels may send nothing to the disconnected socket, and a reconnect can supersede the stale entry before its action, so both levels would give the same reconnect frames. So the scenario asserts the first attempt's membership and connection generation at a defined point: after `.allow` is released and the admission returns, before the reconnect.
  - The teardown is `endSessionTicketsForTeardown()`, and the adapter's `teardownTicketEnds` counter is a milestone showing it ran while `.join` was held. So the scenario can't pass by never racing.
  - The reconnect (attempt `A2`) follows, and joins and acts, for the record and routing outcome.
  - The teardown is the adapter's membership teardown, not a keeper shutdown. A full keeper shutdown at the keeper's `.join` hold can set `isDraining` and stop the admission the scenario is meant to test.
  - The entries name each side's exact membership state at the assertion point, and the exact frames and record fields for `A2`.
- **A disconnect before the keeper's admission, with in-turn sync on.** Today neither OnJoin nor OnLeave runs. The scenario holds the keeper's `.join`, which is before the player's insertion and the OnJoin resolvers. It disconnects there, and releases after the disconnect is forwarded (router `disconnectForwarded`). The record tells the two cases apart: before admission there is no join entry for the attempt; after it, there is one.
  - Whether the turn version keeps that is behaviour a land author sees, so the maintainer decides it in slice 1's plan, before its code.
  - **Provisional, until that decision:** neither runs, as today. The player was never admitted, and an OnLeave without its OnJoin breaks the pairing a land relies on (§5.6).
  - If that holds, this case is not a difference and the entry is dropped. If the decision changes, the entry names the exact record entries on each side.

### Fit with resolve, apply and sync, and with #588

The harness compares outputs only, so it doesn't depend on how a slice splits its phases. The scenarios still place their holds at the phase edges, because that is where slices move work:
- **resolve → apply:** between a join's resolvers and its admission, and between an action's resolvers and its answer;
- **apply → sync:** a sync cycle in flight, and a joiner's initial sync.

**#588** moves a state-dependent join check into the turn that applies the join, as a validate step before a non-throwing apply. When the join slice adopts that shape, the refusal can move from before the resolvers to after them. #588 requires the client to get the same refusal whichever check refuses.
- The harness has a scenario for each refusal source: `CanJoin`, `maxPlayers`, and later validate. Each is compared at both levels.
- A refusal that moves in time but reaches the client as the same frame is no difference.
- A different frame or close is a difference that #588 rules out, so it never goes on the expected list.

## 7. Checks of the harness itself

The rows of §2's tables, each with a check:

- **(a) Determinism.** Every scenario runs twice at each level it runs at, in every applicable cell, and the two runs must match. Until slice 1, this is the whole harness run.
- **(b) Source mutants, one per compared channel.** Until slice 1, both sides are `.legacy` from the same source, so a hand edit changes both runs alike and the differential comparison can't fail on it. A mutation test compares the mutant's output with the unmutated program's, so these mutants do that:
  - **Clean capture:** before the mutants, the first scenario set runs at `.legacy` and its `RunResult`s are stored, in the golden files' decoded form. It is a test artifact for this check, under `.build`, not a reviewed file.
  - **Each mutant** is one hand edit, run, recorded and reverted, as for other gates. Its run is compared with the clean capture, and the scenario that claims its channel must fail. That also proves the scenario reaches the code.
  - **frames:** skip one event frame in the adapter's event loop;
  - **closes:** change a close code in the adapter's close path;
  - **record:** skip one record entry in the keeper's submit;
  - **a race:** the stale action reply. Removing the guard in `finishActionResponse` alone can survive, because both final enqueue branches check the ticket again (`TransportAdapter.swift:5732`, `:5783`). So the scenario reconnects with the same `SessionID`, as a new attempt, and the mutant removes the check on the branch that scenario takes;
  - **responses:** a mutant on the extractor's input, changing the request ID in one response frame. A join-response field edit would change frames too, so it wouldn't show that response extraction works on its own.

  The PR body has each mutant's failing output.
- **(c) Comparator.** One test applies transforms to one side's `RunResult`: drop a frame, swap two adjacent frames, change a close, drop a record entry, add a stray expected entry. Each must be reported. This shows the comparator is strict; (b) shows the runner captures what the adapter does.
- **(d) Golden.** A missing file fails. A changed file fails without the update key. With the key, the update prints the changed paths.
- **(e) Record fields.** The field-list test of §5.5.
- **(f) Property oracle.** For each property, one mutant breaks it on both sides alike, so the comparison passes and only the oracle fails. Example: an OnLeave dropped in the shared keeper path.
- **(g) Vacuity.** A scenario with no milestones is refused. A milestone that isn't observed fails.

## 8. Scenarios and holds

**Cell rule.** Each scenario names the cells it applies to: sync mode (in-turn on, off) and land kind (tick, tickless). It runs in exactly those, with every encoding. A test checks that each scenario's cell set is nonempty before the `IN_TURN_SYNC=false` mask is applied, so a scenario can't disappear by its rule.

**One schedule per row.** A row's holds are all reached in one run. Holds that exclude each other, such as a disconnect at `beforeAdmit` that returns before `afterAdmit`, are separate rows.

**Disconnects at a hold.** The runner starts the disconnect, waits until the router reports it forwarded (`disconnectForwarded`), and only then releases the hold. Awaiting the disconnect while the hold is closed could wait behind the same membership operation that the hold is stopping.

**TestGate in the NIO target** comes from the shared test-support target (§3).

**Reach rule.** Every hold a scenario names must be reached in each cell it runs in. A hold that isn't reached fails the run with the hold's name. The runner waits through `TestGate`, whose 60 s guard is the backstop. The cell rule keeps a hold out of cells that can't reach it, so the guard isn't what ends a correct run.

| Scenario | Cells | Holds | Covers |
|---|---|---|---|
| one player joins, acts, leaves | all | none | the plain path |
| two players, an action and an event, broadcast and per-player state | all | none | merged broadcast frame, per-player updates |
| a second session of the same player | all | none | #531's rule, supersede |
| a join refused by `CanJoin`, and one refused by `maxPlayers` | all | none | refusal frames (§6, #588) |
| a disconnect at the router's `beforeAdmit` | all | router `beforeAdmit` | the router returns before admission |
| a disconnect at the router's `afterAdmit` | all | router `afterAdmit` | a disconnect after the router's admission step |
| a disconnect while the join response is sent | in-turn off | router `sendingJoinResponse` | only on the path without the in-turn flip (`LandRouter.swift:1052–1093`) |
| a disconnect while the initial sync is sent | in-turn off | router `sendingInitialSync` | the same path |
| a disconnect before the keeper's admission | in-turn on | keeper `.join` | the pre-admission disconnect entry (§6) |
| a disconnect at the in-turn registration | in-turn on | adapter `registerSession` | after the keeper's admission (`TransportAdapter.swift:2164–2200`), before registration and flip |
| a teardown during the keeper join (#548) | all | keeper `.join`, then `endSessionTicketsForTeardown()`, then `.allow`, the membership assertion, then a reconnect | #548's entry (§6) |
| a stale action reply after a leave | the land kinds where the action has a pending job | adapter `actionResponse`; the reconnect with the same `SessionID` | reached only when a pending action job's reply comes back after the session left; a tickless action with no resolvers doesn't reach it |
| a join while a sync cycle is in flight | in-turn off, and in-turn on with an explicit legacy cycle | adapter `cycleBeforeEndSync` | as `TransportAdapterInTurnSyncTests` drives it |
| a land stop with players connected | all | the router's stop-task holds (§5.4), keeper `shutdownTurnApplied` | closes, OnLeave order, the record's end |

`drainWait` from rev 1 is gone. It fires only when a land is created again while its previous instance drains (`LandManager.swift:465`), and no scenario here does that yet.

**Growth.** Each slice's PR adds scenarios for the orders it moves, each with its cell rule, and names the hold points it adds. A slice that moves a path no scenario holds adds the hold point first, as its own commit. A slice's review checks that every await the slice removes or adds has a scenario holding it.

## 9. Matrix and CI cost

- **Sync modes in one process:**
  - `LandManager`'s `inTurnSync` parameter turns in-turn sync off for one manager. `IN_TURN_SYNC=false` in the environment turns it off for all of them, since "an explicit off in either place wins".
  - The required CI matrix in `build-and-test.yml` has one leg with `IN_TURN_SYNC=false`. In that leg the harness runs only the in-turn-off cells. It records the in-turn-on cells as disabled, with that reason. The other leg runs every cell in one process.
- **Count.** The first set has 14 scenarios after the split rows (§8). Their cell rules give about 120 cells (scenario × sync mode × land kind × encoding) in the unrestricted leg, and about 60 in the `IN_TURN_SYNC=false` leg. With two runs per level (§7 (a)), that is about 360 runs at one level in the unrestricted leg, and 720 once a second level exists. Step 2 states the exact number from the cell rules.
- **Time.** Each run has real holds, flushes and a stop, so "a few milliseconds per run" is an assumption to measure, not a number. Step 2 measures it at that count, on the CI runner.
- **Other jobs.** `build-and-test.yml` also runs the NIO suite in its tables-off and per-player-tables-off runs, so the harness's time counts in each of them. Step 2 states the total.
- **Cost of a missed hold:** one unreached hold costs `TestGate`'s 60 s guard on its own. So the reach rule (§8) is what keeps the budget, and a harness run that hits the guard fails.
- **Budget:** the whole matrix runs in the PR CI's NIO suite while it stays under 30 s on the CI runner, summed over the jobs that run it. Past that, the PR CI runs messagepack only, and the nightly (#625) runs all three encodings.
  - `full_matrix` is a workflow input, so `swift test` doesn't see it. The workflow sets an env var from it, `SST_DIFFERENTIAL_FULL_MATRIX`, which the harness reads through `getEnvBool` and a constant in the test-support target's env keys.
  - The PR that makes the split states the numbers.

## 10. What it can't see

As #555 lists, and where each is covered instead:
- **orders no scenario forces:** the growth rule in §8, and review of each slice's awaits;
- **load-dependent behaviour** (sync lag, back-pressure, slow-reader closes): the A/B and the load test;
- **lifetimes** (leaks, reference cycles): not covered here;
- **counters, logs, admin:** compared only when a slice adds them explicitly;
- **real sockets and the NIO host's HTTP layer:** E2E, which the env key runs at a chosen level.

## 11. Steps

1. **Groundwork (one PR, `package` additions and tests):**
   - `TransportAdapterAdoption` with `.legacy`, its env parser, the `LandManager` parameter, the configuration override and the resolution in `NIOLandServer.init` (§4), with the startup refusal stated in the PR;
   - the extracted assembly, its build and attach parts, with `NIOLandServer` and the host calling them (§3);
   - the `SwiftStateTreeTestSupport` target with `TestGate`, `Deadline` and `RecordingConnection`, and their users switched over (§3);
   - the hooks: client identity by attempt (§5.4), the router's stop-task holds (§5.4), the no-pending-flip report (§5.3), and the record decoder entry (§5.5);
   - the record field list and its test (§5.5).
2. **The harness (one PR):**
   - the runner, the barrier, the two checkpoints and the milestones;
   - the comparison, responses and the property oracle;
   - golden files;
   - the first scenario set, with its cell and reach rules;
   - the same-level check;
   - the clean capture, the source mutants and the comparator transforms (§7), with their outputs in the body;
   - the measured CI time and count.
3. **Slice 1** (#546) adds `.membership`, its expected-difference list (§6) and its scenarios. That is #546's work. Its plan carries the maintainer's decision on the pre-admission disconnect.

## 12. Decisions from review

- **Q1:** one extracted `package` assembly that both `NIOLandServer.init` and the harness call (§3).
- **Q2:** two golden files, as change detection on shared code (§5.8). The property oracle (§5.6) handles shared bugs.
- **Q3:** this plan fixes how the decision is held; slice 1's plan makes it, with the maintainer. Provisional: neither OnJoin nor OnLeave runs, as today (§6).

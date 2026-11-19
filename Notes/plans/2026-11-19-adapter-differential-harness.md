# A differential test harness for TransportAdapter's adoption levels (#555)

**Status:** rev 1, for review. **Issue:** #555 (part of #546). **Base:** `main` at cef7177c.

## 1. Goal

#546 moves `TransportAdapter` onto the turn core (`SwiftStateTurns`, #551) one slice at a time. Each slice is selected by an adoption level, so a slice can land switched off and be compared with the code it replaces. This plan is the test that does the comparison. It runs the same scenarios at two adoption levels and fails on any difference in what clients and the replay record see, unless the slice lists that difference as expected.

The harness ships before slice 1, with one level only, so its own checks (§7) run against the current adapter first.

## 2. Prior art

The harness borrows from two classic techniques, and from each it takes the failure modes that are known for it. §7 has a test for each row.

**Differential testing** (McKeeman, "Differential Testing for Software", Digital Technical Journal 10(1), 1998). Two implementations of one specification get the same inputs, and any difference in their outputs is a bug in one of them, found without writing down the expected output. Its known failure modes:

| Failure mode | What goes wrong | Where this plan handles it |
|---|---|---|
| Non-determinism | Two runs of the same side differ, so every comparison is noise | §5.3: manual ticks, fixed IDs, normalised record fields; §7 (a) same-level run twice |
| A shared bug | Both sides run the same faulty code, so they agree and the bug passes | §5.5: golden files on a few scenarios; §3 what stays shared |
| Triage of differences | Real differences drown among known ones | §6: the expected-difference list, each entry matched exactly and required to occur |
| Input coverage | Only the orders the inputs reach are compared | §8: scenarios force orders through hold points; §10 lists what no scenario reaches |
| A weak comparison | The comparator ignores what changed (count only, set not sequence) | §5.4: per session, in order, byte for byte; §7 (b) mutants |

**Golden (snapshot) testing.** The output of a run is stored as a file. Later runs are compared with it, and a change to the file is reviewed like code. Its known failure modes:

| Failure mode | What goes wrong | Where this plan handles it |
|---|---|---|
| Blind update | The update command rewrites every file, and nobody reads the diff | §5.5: an explicit env key, files in readable decoded form, and the PR lists which files changed |
| A missing file passes | A new scenario without a file is accepted silently | §5.5: a missing golden file fails, except under the update key |
| Brittle output | Unrelated noise (timestamps, IDs) changes the file | the same normalisation as the differential side (§5.3) |
| Unreadable diffs | Binary frames give a diff nobody can review | golden files hold decoded frames (JSON) for every encoding, with the encoding in the file name |

## 3. What is compared, and at which boundary

**The boundary** is the assembler: `LandRouter`, `LandManager` and the host's wiring, with a fake `WebSocketConnection` for each client. Below it everything is real: the transport, the adapter, the keeper, the sync engine, the encoders and the recorder. The adapter isn't driven directly. A slice can move work between the adapter and its neighbours, and a test at the adapter's own API would miss what moved.

**The host.** `NIOLandHost` adds sockets and HTTP on top of the same assembly. The harness builds the router and manager as `NIOLandServer` does. Step 1 checks whether `NIOLandServer`'s assembly can be called with a fake transport through a `package` entry point. If it can, the harness uses it, and the wiring can't drift. If it can't, the harness copies the wiring, and a test compares its configuration with `NIOLandServer`'s field by field. Real sockets are out of scope (§10).

**Compared, per scenario:**
- each session's frames, in order, byte for byte (§5.4);
- each session's close: code and reason, or none;
- the replay record (§5.3 lists the normalised fields);
- for each join and action, the response the client got.

**Not compared:** counters, logs, admin routes and timing. A slice that needs one of them compared adds it explicitly (§10).

**What stays shared** between the two levels: the keeper, the sync engine, the encoders, the transport and the recorder. A bug in them shows on both sides and is invisible to the differential comparison. The golden files (§5.5) are there for that.

## 4. Adoption levels

As #555 and #546 say: an environment key plus a `package` parameter, never public.

- `TransportAdapterAdoption`, a `package` enum in `SwiftStateTreeTransport`. Level `.legacy` is today's adapter. Each slice adds one case (`.membership` for slice 1, and so on), and each level includes the slices before it.
- **Parameter:** `LandManager` and `NIOLandServerConfiguration` take `adoption: TransportAdapterAdoption` as a `package` parameter, defaulting to the env key's value.
- **Env key:** `TRANSPORT_ADAPTER_ADOPTION`, a named constant in `TransportEnvKeys` and read through `getEnvString`. An unknown value stops at startup with the list of known levels, so a typo doesn't fall back to `.legacy` without a word.
- **Who uses which:** the harness passes the parameter, so both levels run in one process. The env key is for E2E and the load test, where the server is a separate process.
- The harness lands with `.legacy` only. Its first comparison is `.legacy` against `.legacy` (§7 (a)). Slice 1 adds `.membership` and the first real comparison.

Step 1 adds the enum and the parameter. They change no behaviour, and nothing reads them until slice 1.

## 5. The harness

### 5.1 Shape

```swift
struct DifferentialScenario {
    let name: String
    let land: LandKind            // a small test land; tick or tickless
    let steps: [ScenarioStep]     // connect, join, send, tick, hold, release, disconnect, stop
}

struct RunResult: Equatable {
    var frames: [SessionID: [Data]]      // in arrival order
    var closes: [SessionID: CloseInfo?]
    var responses: [SessionID: [Data]]
    var record: NormalizedRecord
}

func run(_ s: DifferentialScenario, level: TransportAdapterAdoption,
         inTurnSync: Bool, encoding: TransportEncodingConfig) async throws -> RunResult
```

A scenario is data. One runner executes it at any level, sync mode and encoding, so a new scenario is one value and no new test code.

### 5.2 Fake connections

`Tests/` has no shared fake connection today. `GracefulShutdownTests`' private `ShutdownConnection` is the closest: it captures frames and the close code. Step 1 moves it to a shared test-support file as `RecordingConnection`, captures responses too, and makes `GracefulShutdownTests` use the shared one. The move is its own commit.

### 5.3 Determinism

- **Ticks:** the manager is built with `autoStartLoops: false`, and the scenario's `tick` step calls `LandKeeper.stepTickOnce()`. No wall-clock loop runs.
- **IDs:** the scenario names every session ID, player ID and land ID. No guest IDs are generated.
- **Order:** every order that matters is forced by a hold (§8). A step that needs a task to arrive somewhere waits on that hold point, never on a sleep.
- **Recording:** `enableLiveStateHashRecording: true`. The record is read with `recorder.save` into a temporary file. Step 1 lists the record's fields that depend on the wall clock or a random value, and the normalisation replaces each one with its position (first, second, …). That list is in the harness, as code, with a test that fails when the record gains a field the list doesn't classify.
- **Same-level check:** each scenario runs twice at the same level before any comparison. A difference there fails as "not deterministic", naming the scenario, so it can't be mistaken for a slice's difference (§7 (a)).

### 5.4 Comparison

- Per session, in order, byte for byte. Same encoding on both sides, so the bytes match when the behaviour matches. Today's `expectSameFrames` compares the multiset per target; the harness needs sequence equality, and adds it as its own function.
- On a mismatch the report names the scenario, sync mode, encoding, session, and the index of the first differing frame. It shows both frames decoded (JSON), and the steps run before that frame.
- Closes, responses and the record are compared as values, with the same report shape.

### 5.5 Golden files

A small set of scenarios also keeps a golden file per sync mode and encoding: `Tests/SwiftStateTreeTransportTests/Differential/Golden/<scenario>.<sync>.<encoding>.json`. Each file holds the decoded frames per session, the closes and the normalised record.
- **Set:** at first, the two-player join–act–leave scenario and the shutdown-with-players scenario, the two with the most shared code on the path.
- **Compare:** the `.legacy` result against the file. A missing file fails.
- **Update:** with `SST_UPDATE_GOLDEN=1` only, a named constant beside the harness. The update rewrites the files and prints the changed paths. A PR that changes a golden file names it in its body, and review reads the diff.

## 6. Expected differences

A slice may change behaviour on purpose, mostly where it fixes a race. Those differences are listed in the slice's test file, as values:

```swift
struct ExpectedDifference {
    let issue: Int              // the issue the difference fixes or accepts
    let scenario: String
    let session: SessionID?
    let kind: Kind              // .frames(from: index), .close, .response, .record(field)
    let why: String
}
```

- An entry matches one scenario, session and kind exactly. A difference that matches no entry fails.
- An entry that matches nothing in a run also fails, as a stale entry. Fixing the difference then means deleting its entry, and the list can't grow quietly.
- Each slice's PR states its list in the body, with one line per entry.

**The first list** (slice 1, membership) starts with the two entries #555 names:
- **#548**, a teardown during the keeper join: today the admission re-creates the membership and generation on a torn-down adapter. With the turn core the join's ticket is captured when it is enqueued, so after the teardown the admission does nothing. Expected: the torn-down session gets no join response and no initial sync, and the record has no join for it.
- **A disconnect before the keeper's admission**, with in-turn sync on: today neither OnJoin nor OnLeave runs. Whether the turn version keeps that or runs both is slice 1's decision. Either way the entry names the outcome the slice chose, and the comparison holds it to that.

### Fit with resolve, apply and sync, and with #588

The harness compares outputs only, so it doesn't depend on how a slice splits its phases. The scenarios still place their holds at the phase edges, because that is where slices move work:
- **resolve → apply:** between a join's resolvers and its admission (the keeper's `.join`, the router's `beforeAdmit`/`afterAdmit`), and between an action's resolvers and its answer (the adapter's `actionResponse`);
- **apply → sync:** a sync cycle in flight (`cycleBeforeEndSync`), and the initial sync of a joiner (`initialSync`, `sendingInitialSync`).

**#588** moves a state-dependent join check into the turn that applies the join, as a validate step before a non-throwing apply. When the join slice adopts that shape, the refusal can move from before the resolvers to after them. #588 requires the client to get the same refusal whichever check refuses. The harness has a scenario for each refusal source (`CanJoin`, `maxPlayers`, and later validate), compared at both levels. A refusal that moves in time but reaches the client as the same frame is no difference. A different frame or close is a difference, and #588 says it must not be one, so it never goes on the expected list.

## 7. Checks of the harness itself

The rows of §2's tables, each with a test:

- **(a) Determinism.** Every scenario runs twice at `.legacy`, in every sync mode and encoding, and must match. This is also the whole harness run until slice 1 adds a second level.
- **(b) Mutants.** The repository has no mutation tool. Most mutants here are transforms that a test applies to one side's `RunResult` before the comparison, so they test the comparator and touch no shipping code. One is a hand edit of the adapter, recorded and then reverted as for other gates, to show the whole path end to end:
  - (adapter edit) skip one event frame in the adapter's event loop: caught;
  - drop one frame of one session: caught as a frame-count difference;
  - swap two adjacent frames of one session: caught by the in-order comparison, and not by today's `expectSameFrames`, which shows why the harness needs its own;
  - change one close code: caught;
  - drop one record entry: caught;
  - add a stray entry to the expected list: caught as stale.
  The PR body has each mutant's failing output.
- **(c) Golden.** A missing golden file fails. A changed golden file fails without the update key. Updating with the key prints the changed paths.
- **(d) Record fields.** A record field the normalisation doesn't classify fails the field-list test.
- **(e) Wiring.** If the harness copies `NIOLandServer`'s assembly (§3), a test compares their configurations.

## 8. Scenarios

Each scenario names the holds it uses. The first set, in step 2:

| Scenario | Hold points | Covers |
|---|---|---|
| one player joins, acts, leaves | none | the plain path, both land kinds |
| two players, action and event, broadcast and per-player state | none | merged broadcast frame, per-player updates |
| a second session of the same player | none | #531's rule, supersede |
| a join refused by `CanJoin`, and one refused by `maxPlayers` | none | refusal frames (§6, #588) |
| a disconnect during each join stage | router `beforeAdmit`, `afterAdmit`, `sendingJoinResponse`, `sendingInitialSync`; adapter `admitJoinEntry`, `registerSession` | pre-admission disconnect entry, membership teardown |
| a teardown during the keeper join | keeper `.join`, then a teardown, then `.allow` | #548's entry |
| a leave during an action's resolvers | adapter `actionResponse` | an answer for a session that left |
| a join while a sync cycle is in flight | adapter `cycleBeforeEndSync` | the joiner's first frames against the cycle |
| a land stop with players connected | manager `drainWait`, keeper `shutdownTurnApplied` | closes, OnLeave order, record end |

**Growth.** Each slice's PR adds the scenarios for the orders its slice moves, and names the hold points it adds. A slice that moves a path no scenario holds adds the hold point first, as its own commit. A slice's review checks that every await the slice removes or adds has a scenario holding it.

## 9. Matrix and CI cost

The matrix is scenarios × 2 sync modes × 3 encodings × levels, plus the same-level run.
- **Sync modes in one process:** `LandManager`'s `inTurnSync` parameter turns in-turn sync off for one manager, and `IN_TURN_SYNC=false` in the environment turns it off for all of them ("an explicit off in either place wins"). So both modes run in one process unless the environment says false. Then the harness fails at its start with that reason, rather than running the "on" leg off.
- **Estimate:** with manual ticks and no sleeps, a scenario is a few milliseconds per run. 9 scenarios × 6 combinations × 3 runs (two same-level, one other level) is about 160 runs. Step 2 measures it, and the PR states the number.
- **Budget:** the whole matrix runs in the PR CI's Transport suite while it stays under 30 s on the CI runner. Past that, the PR CI runs messagepack in both sync modes and the nightly (#625) runs all three encodings. The split is decided by the measured time, and the PR that makes it states the numbers.

## 10. What it can't see

As #555 lists, and where each is covered instead:
- **orders no scenario forces:** the growth rule in §8, and review of each slice's awaits;
- **load-dependent behaviour** (sync lag, back-pressure, slow-reader closes): the A/B and the load test;
- **lifetimes** (leaks, reference cycles): not covered here;
- **counters, logs, admin:** compared only when a slice adds them explicitly;
- **real sockets and the NIO host's HTTP layer:** E2E, which the env key runs at a chosen level.

## 11. Steps

1. **Groundwork (one PR, tests and a `package` addition):** `TransportAdapterAdoption` with `.legacy`, the parameter and the env key; `RecordingConnection` moved to shared support; the assembly check (§3); the record field list (§5.3).
2. **The harness (one PR):** runner, comparison, golden files, the first scenario set, the same-level check, the mutants (§7) with their outputs in the body, and the measured CI time.
3. **Slice 1** (#546) adds `.membership`, its expected-difference list (§6) and its scenarios. That is #546's work, not this plan's.

## 12. Open questions for review

- **Q1.** Does the harness call `NIOLandServer`'s assembly through a `package` entry point, or copy it with a configuration test (§3)? Recommendation: the entry point, if step 1 finds it takes a fake transport with no change beyond `package` access.
- **Q2.** Golden files for two scenarios, or for none until a shared-code bug shows up? Recommendation: two. They are the only check on shared code, and their cost is a reviewed diff when output changes on purpose.
- **Q3.** For the pre-admission disconnect entry, slice 1 decides whether OnJoin and OnLeave run. This plan only fixes how that decision is held (§6). Is that the right split?

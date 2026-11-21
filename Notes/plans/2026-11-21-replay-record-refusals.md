# A malformed record fails its replay run instead of trapping or broadcasting (#639, #640, #641)

Rev 1, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main 61706807.

A record is untrusted input: it is uploaded through the admin replay start, or handed to a runner. One malformed file must fail its own run, with the tick and what is wrong, and leave the process and the other lands running. The lesson `Notes/solutions/2026-11-09-wire-fed-integer-conversions-must-be-exact-and-throwing.md` states the rule for wire data. The same rule holds for record data: an operation fed by it throws, it never traps.

## 1. All three still reproduce on main (by reading the code)

- **#639.** `JSONReevaluationSource.init(data:)` builds its index with `Dictionary(uniqueKeysWithValues:)` (`Sources/SwiftStateTree/Runtime/ActionSource.swift:176`). Two frames with the same `tickId` trap there.
  - The test init `init(metadata:frames:)` (:198) does the same, but its frames come from code: six test callers, none in `Sources/` or `Examples/`.
  - The 3.x binary source (`ReevaluationRecordLogSource`, :286) can't trap this way. Its frames come from `ReevaluationFrameAssembler`, which merges records of one tick into one frame (`ReevaluationRecordLog.swift:178-189`).
- **#640.** `ReevaluationRunnerService.setRunnerInstance` sets `_status.totalTicks = runner.maxTickId + 1` (`ReevaluationRunnerService.swift:237`). Both sources take `maxTickId` as the largest recorded tick ID, unchecked (`ActionSource.swift:177`, :287). A frame at `Int64.max` traps the addition.
  - A live keeper can never record that tick: `nextTickId += 1` (`LandKeeper.swift:4412`) traps at it first. Tick IDs start at 0 (LK:620), and a tickless land keeps them non-negative (`ensureTickIdForTicklessLand`, LK:3391). So a live record's tick IDs lie in `0 ..< Int64.max`.
  - A negative tick ID is malformed too: both runners step from tick 0, so such a frame's inputs would be skipped without a word.
- **#641.** `ReevaluationEventTargetRecord.toEventTarget()` (`ActionRecorder.swift:883-907`) maps an unknown `kind`, or a `player`, `client` or `session` target without an ID, to `.all`. Its only library caller is the replay land (`GenericReplayLand.swift:127`), which re-emits the recorded events with that target.
  - The same mapping also takes the first of several IDs and drops the rest, and it accepts `all` with IDs.
  - `ReevaluationEventTargetRecord.from(_:)` (:867) writes exactly one ID for `player`, `client` and `session`, none for `all`, and any number for `players`. Anything else did not come from a live run.

## 2. Fit with #612 and with #637/#709

- **#612 deletes the code these fixes touch.**
  - Its S1 deletes the 3.x replay readers, `JSONReevaluationSource` among them (its §5 table, row "The 3.x replay readers").
  - Its S5 deletes `GenericReplayLand` and the runner wrapper.
  - #612 is in plan review (rev 4), and S1 isn't started. These three bugs are before-release, and each fix is a few lines in today's code, so fixing them now patches nothing #612 redesigns.
- **What #612 has to carry over.** Its record cursor's structural validation (§3.1) ends a run with `recordInvalid(position, rule)`. This plan adds the rules to that list, in a short note on #612, not in its plan file:
  - tick IDs in `0 ..< Int64.max`;
  - a well-formed event target, if 4.0 records server-event targets;
  - in 4.0 a tick has several frames, one per boundary. So S1's bridge index (`MaterializedRecordSource`) must group frames by tick, never with `uniqueKeysWithValues`.
- **#637 and #709** are about payload values: how a recorded value keeps its type, and how a recorded action's payload is decoded on replay. None of the three fixes reads or decodes a payload.
  - #641's check sits in `ReevaluationReplayFrame.resolveEvents`, next to the payload decode that #637 may change. The two changes touch different lines of the same function.

## 3. Design

### 3.1 #639 and #640 at the source: the record's tick IDs are checked when it is opened

- **A new public error, `ReevaluationRecordContentError`.** It has two cases:
  - `duplicateTickId(Int64)`;
  - `tickIdOutOfRange(Int64)`.

  Its description names the tick and says the record isn't one a live run writes. #612's `recordInvalid` replaces it in S1, with the readers.
- **One shared check, `ReevaluationRecordContentCheck.tickIndex(_ frames:) throws -> [Int64: ReevaluationTickFrame]`.**
  - It refuses a tick ID outside `0 ..< Int64.max`, then a duplicate, in frame order, so the first bad frame is named.
  - `JSONReevaluationSource.init(data:)` and `ReevaluationRecordLogSource.init(bytes:)` build their index through it. Both inits already throw.
- **The runs fail without a crash.**
  - The admin start opens the record in the runner factory (`factory.createRunner`). There, a throwing open already marks the run `.failed` with the error's description (`ReevaluationRunnerService.swift:205-212`).
  - `ReevaluationEngine.run` throws to its caller.
- **The test init.** `init(metadata:frames:)` keeps its non-throwing signature: it is public, and its frames come from code. It goes through the same check and stops with a `preconditionFailure` that names the tick: a programmer error, documented on the init. Q1 asks whether it should throw instead.

### 3.2 #640 in the service: the total can't trap for any runner

`ReevaluationRunnerProtocol` is public, so a custom runner can report any `maxTickId`. `setRunnerInstance` computes the total with `addingReportingOverflow(1)`.
- On overflow the run fails, with a message that names the runner's `maxTickId`. It fails through the same path as a refusal (`.failed`, `errorMessage`), before the first step.
- With §3.1 in place, the two library runners never hit this path.

### 3.3 #641: a malformed target fails the tick's resolve

- **A new throwing conversion,** `ReevaluationEventTargetRecord.eventTarget() throws -> EventTarget`. It accepts exactly what `from(_:)` writes:
  - `all` with no IDs;
  - `player`, `client` or `session` with exactly one ID;
  - `players` with any number of IDs. An empty `players` is a target with no recipients, as it was live.

  Anything else throws.
- **`resolveEvents` converts each recorded target** after the event's payload decodes (`ReevaluationReplayFrame.swift:174-203`). A target that doesn't convert throws the new case `ReevaluationReplayResolutionError.eventTarget(tickId:origin:sequence:name:target:)`, so the run fails at that tick. That is the path an undecodable payload already takes.
- **`ResolvedEvent.target` becomes `EventTarget`.** It is a package type, so this doesn't change public API. `GenericReplayLand` emits that target and no longer converts it.
- **`toEventTarget()` stays,** because it is public. It is marked deprecated in favour of `eventTarget()`, and its doc comment says that it maps a malformed target to `.all`. Q2 asks whether to remove it now instead.
- **Both event lists of a frame go through the same resolve.** The projected events come from the replay itself (`from(_:)` of a live `EventTarget`), so they always convert. The check costs nothing there, and it keeps one path for both.

## 4. Tests (each written first, and fails or traps on main)

The tests that trap on main run as exit tests (`#expect(processExitsWith: .failure)`) in the commit that adds them. After the fix, they become plain `#expect(throws:)` tests. The commit message records the failing run.

- **#639:**
  - a JSON record with two frames at tick 3: `JSONReevaluationSource(data:)` throws `duplicateTickId(3)`;
  - through the service: the admin start with that file ends `.failed`, its message names tick 3, and the service takes the next run;
  - a 3.x binary record with two turn records of one tick still opens, and its frames merge: a pin that the binary path keeps today's merge.
- **#640:**
  - a JSON record with a frame at `Int64.max`, and one at `-1`: each throws `tickIdOutOfRange`;
  - a scripted runner whose `maxTickId` is `Int64.max`: the run ends `.failed`, and the process keeps running;
  - a record at `Int64.max - 1` opens, which pins the boundary.
- **#641:** one case per malformed form:
  - an unknown kind;
  - `player`, `client` and `session` with no ID;
  - `player`, `client` and `session` with two IDs;
  - `all` with an ID.

  Each fails `ReevaluationReplayFrame.resolve` with `.eventTarget`, naming the tick and the sequence. Through `GenericReplayLand`, a test client of the replay land receives no event from that tick.
  - The valid forms still convert, empty `players` included. The existing `ReevaluationReplayCompatibilityTests` round trips stay as they are.
- **Mutants** (each restored; each must fail a test):
  - the range check removed;
  - the duplicate check removed;
  - the service's overflow check replaced by `+ 1`;
  - `eventTarget()` falling back to `.all`;
  - `resolveEvents` skipping the target check.

## 5. Steps, verification, docs

- **One PR, three commits** (#639, #640, #641). Estimated size: Sources about +80 / −10, Tests about +200.
- **Mac, holding the slot:** build, then `ReevaluationReplayCompatibilityTests`, `ReplayTypedEventDecodeTests`, `ReplayTypedReEmitTests`, `MonitorTicketTests` (the service's runs), the new record-source tests, and the mutants.
- **CI:** the full `swift test` and E2E. The reevaluation E2E runs with `ENABLE_REEVALUATION=true` through `test-e2e-game.sh`.
- **A/B:** none. The checks run once per record open and once per replayed event, not on the live path.
- **Docs:** `docs/core/reevaluation.md` and its zh-TW page say that a record with a duplicate or out-of-range tick ID, or a malformed event target, fails its run when it is opened or resolved.
- **Solutions:** update the lesson cited above. Its rule now also covers record data: a duplicate key from a file and an addition on a recorded value. Its index row gains the tags `record` and `replay`. No new entry.
- **#612:** a comment on the issue with the three rules of §2.

## 6. Questions

- Q1: the test init `init(metadata:frames:)`: a documented precondition (recommended: it is public and non-throwing, and its six callers are tests), or `throws`, which breaks a public signature?
- Q2: `toEventTarget()`: deprecated, with its fallback documented (recommended), or removed before the release?
- Q3: out of scope here, a follow-up issue. A record whose tick IDs are valid but far apart, for example 0 and 2^62, makes a run step through 2^62 empty ticks. That is not a trap, and a new run supersedes it. Should a later change refuse a run longer than the record supports?

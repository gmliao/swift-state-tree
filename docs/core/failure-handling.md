[English](failure-handling.md) | [中文版](failure-handling.zh-TW.md)

# Failure Handling

This page states how SwiftStateTree handles a failure in sync, encoding, handlers and input. It also lists, path by path, where the code stands today against that rule. Several paths don't follow it yet; the table says which, and the issue that tracks each one.

## The rule

The test is whether the failure can be brought back to fully correct.

- **Yes: recover.** A path that restores a correct state stays, for example a resync that sends the client a full view.
- **No: end the smallest unit the failure corrupted.** Log the reason, then end that unit.

Never add an absorb-and-continue path. Absorbing hides the bug: the client shows a wrong state while the server looks healthy, and nothing reports it.

One process hosts many lands, so the unit is never the process. A failure in one land doesn't stop another.

## Scope: what ends

The scope follows what the failure made wrong (decided in #535; see [the decisions](https://github.com/gmliao/swift-state-tree/issues/535#issuecomment-6852509570) and [the plan](https://github.com/gmliao/swift-state-tree/blob/440210de/Notes/plans/2026-11-13-sync-failure-ends-unit.md)):

| The failure | What it made wrong | What ends |
|---|---|---|
| A type error knowable when the land is registered | every recipient, from the first sync | nothing runs: **registration is refused** |
| A failure that corrupts every recipient's view or the land's state, including a type error found only at run time | every recipient, or the state itself | **the land** is closed, and the error logged |
| A failure confined to one connection, such as its outbound queue over the writer's ceiling | that connection's frames only | **that session** is closed. Rejoining sends a full view, which is correct again, so the land keeps running |
| A malformed input from a client | nothing yet | **that input** is rejected, and the client is told. The session and the land keep running |

An event that fails to encode is a fact about the value, not about who receives it: each event is encoded once, before it fans out to its recipients. So it ends the land, whatever its target (#521).

No sync failure is known to be confined to one player's view. A player's view is a deterministic function of the land's state, so a rejoin recomputes the same failure. So every sync failure ends the land, including one in a resync's or a first view's frame (#535). The session row is for failures that are genuinely per-connection, such as the outbound writer's ceiling. A failure that ends a session must not loop: one that recurs after the rejoin ends the land.

## Where the code stands

Read at `main` 9755a625; line numbers are as of that commit. **Current** means the code already does what the rule asks. **Target** means it doesn't yet, and the issue tracks the change.

### Refused at registration

| Path | Today | Status |
|---|---|---|
| A reference type (class) as synced state (#464) | refused at registration: `LandDefinition.validateForRegistration`, `LandRegistrationError.sync` `.valueSemantics` ([Sync](sync.md#what-registration-refuses)) | current |
| A server event or a declared action response type without `@Payload` on a compressed encoding (`messagepack`, `opcodeJsonArray`) (#521) | refused at registration: `LandDefinition.validateForRegistration` (`NIOLandHost.swift:366`, `LandManager.swift:406`); on `json` it's written by its `Codable` form | current |
| Other type errors the type alone decides: an unsupported dictionary key type, a node with player-dependent fields under a broadcast field | refused at registration: `LandRegistrationError.sync` `.unsupportedKey`, `.policyNesting` (#535). A value only a later instance holds (a plain struct's element in a collection empty by default, an enum case the default doesn't take) and storage behind a hand-written `toSnapshotValue()` are found at sync time and handled as the first row under "The land ends"; so is a keeper built directly, whose initialization runs the same check | current |
| An existential synced field (`Any`, `any P`) | refused at compile time where the declared type spells `any`, `Any`, `AnyObject` or `P & Q`, and `AnyHashable` and `AnyCodable` by name; at registration, `.existentialField` for `Any`, `AnyObject`, `AnyHashable` and `AnyCodable` as a collection's element, key or value or an optional's wrapped type, in a plain struct or a `@SnapshotConvertible` type. Not caught: a protocol spelled bare, a typealias to an existential, a plain struct's own property declared `Any` or `any P` (seen only as the type of its default value) and a hand-written conversion; such a field ends the land at its first failing conversion (#535) | current |

### The land ends

| Path | Today | Status |
|---|---|---|
| A field whose conversion throws at run time | the land ends with `syncConversion`, naming the field; the plan commits and sends nothing, and its sessions close with 4016 (`SyncPhasePlan.noteExtractionDrops`). A joiner's view, a resync's and a seed are covered too | current (#535 rows 1, 3, 4, 6) |
| Dictionary keys that convert to the same string | the conversion throws `SyncError.collidingKeys`, and the land ends as for any conversion that throws. Only the library's conversion checks it: a custom `toSnapshotValue()` that builds its own `.object` has merged its keys before the library sees them, and that stays the type's own contract | current (#535 D8) |
| A patch the encoding can't carry (for example a non-finite number in JSON) | the land ends with `syncEncode`, in any frame: the merged broadcast frame (`encodeMergedBroadcastFrameOrFail`), a per-player or combined frame, a row-addressed table's row (`planPerPlayerFrames`, `stateFrameEncodeFailure`). Nothing is re-encoded without it, and the failing cycle sends nothing | current (#535 rows 8, 9, 10) |
| A patch whose path is outside the schema | as the row above, and counted in `unmappedPathPatches` (a failure counts once) | current (#535 D6). A let-only `@SnapshotConvertible` struct has no schema paths below it today (#566) |
| A sync plan that throws | the first throw ends the land, its sessions close with 4016, no retry. In-turn sync: the keeper ends it in the same turn (`applyInTurnSyncResult`). Legacy sync (off in-turn): the adapter sends nothing more and submits the failure, which the keeper applies in its next turn (`submitLandFailure`). A joiner's standalone firstSync plan that throws ends the land the same way, with no follow-up (row 16) | current |
| One player's state frame, or a broadcast-only frame, fails to encode entirely | the land ends; the failing cycle sends nothing, and its sessions close with 4016 (`planPerPlayerFrames`, `planBroadcastOnlySeparateFrames`) | current (#535 rows 10 and 12) |
| A resync's or first view's full view fails to encode | the land ends at the first failure, with no retry; 4012 is no longer sent (`planPerPlayerFrames`, `planFirstSync`) | current (#535 rows 11, 13) |
| A server event that fails to encode | opcode 107: an event whose merged body fails goes out as its own frame; one that reaches no frame at all, whose event frame doesn't pack, or whose merged state-and-events frame doesn't pack, ends the land (`enqueueEventSynchronously`, `appendEventFrames`, `encodeMergedBroadcastFrame`). Without opcode 107: an event whose frame doesn't encode ends the land; one whose target has no current recipient isn't a loss | current (#535 row 17) |
| An untyped server event on a compressed encoding: `emitAnyServerEvent` with a payload that isn't a payload type (a dictionary, an array, a primitive) | the encoder throws `UntypedPayloadError`, so the event reaches no frame and the land ends as in the row above, with `eventEncode`; its sessions close with 4016, and the process and the other lands keep running. On `json` the payload is written as is. A registered event's name with a dictionary that decodes into its type isn't resolved through the land's registry yet | current (#544); resolving registered dictionaries: #521 |
| A handler that throws after writing state | the input fails alone and the inputs after it continue; its writes stay and are synced, with a warning in debug builds (`LandKeeper.swift:3836-3837`, `:3189`) | target: close the land (#535); #87 tracks the partial writes |
| The replay land re-emits a recorded event on a compressed encoding, under the opt-in `.projectedWithFallback` event policy (`GenericReplayLand.swift:21`; not the default) | a record's payload decodes to a dictionary, so the re-emit is an untyped event (the row above): the replay land ends with `eventEncode` and its sessions close with 4016; the process and the other lands keep running | current for the process (#538); target: re-emit a registered, decodable record through the land's registry, byte-identical to the live event (#521) |
| Replay can't load or match a recorded input | the input is skipped with a warning, and the tick runs without it (`LandKeeper.swift:4126-4139`, `:4250-4256`) | target: the verification run fails, with the tick and the reason (#521; #535 tracks the rule) |

### The session ends

| Path | Today | Status |
|---|---|---|
| The outbound writer drops a frame over its ceiling | every session the frame addressed is ended, and disconnected where the transport can close sessions; the clients rejoin and get a full view (`TransportAdapter+Outbound.swift:38-63`) | current |

### The input is rejected

| Path | Today | Status |
|---|---|---|
| An action whose payload doesn't decode | rejected at intake; the client gets an error (`LandKeeper.swift:2721`, `TransportAdapter.swift:6079`) | current |
| A client event whose payload doesn't decode | dropped without an error to the client (`LandDefinition.swift:276-277`), and still recorded as applied, since recording happens before the handlers run (`LandKeeper.swift:3487-3498`) | target: reject it, as for actions, and don't record it (#537) |

### When a land ends on a failure

| Path | Today | Status |
|---|---|---|
| OnLeave and the destroy handlers | a failed land clears its players without OnLeave in the failing turn, and its destroy handlers and save run with `LandDestructionCause.failed` and `LandKeeper.failure` (`LandKeeper.swift:4892`). With a host, the failure's teardown stops the land through the host (`NIOLandServer`): the router forwards each session's leave, which finds no player and runs no OnLeave, then closes it. A session an admin stop closed before the failure had its leave run as for any stop | current (#535 PR 1 part B) |
| The re-evaluation record | the failure is recorded once, in the frame of its tick, in the turn segment that ends the land (`ReevaluationTickFrame.landFailure`, record format 3.4). Replay stops at that tick and reports it (`RunResult.liveFailure`); see [Reevaluation](reevaluation.md#pass-ordinals-and-the-land-failure-34) | current |

## Close codes

- **4016 `landFailed`:** a land that ends on a failure closes its sessions with it, built directly or hosted. With a host, the failure's teardown stops the land as an admin stop does (detach, each session's leave, the close), and the code is read per session when its close request is issued: a land that fails while an admin stop runs gives 4016 to every session whose close request comes after the failure. A session already closed, or whose close request was issued before the failure, keeps 4014; so does a failure during the request's last hop to the transport. Once a host shutdown has taken the sessions for its own close (`closeSessionsForShutdown`), a land that fails closes them with the shutdown's 1001.
- **4012 `unencodableView`:** reserved, no longer sent (#535). Until then it closed a session whose resync's or first view's frame kept failing to encode; such a failure now ends the land with 4016.
- **4014 `landStopped`:** an admin stop of a land that hasn't failed.

## How other systems do it

Other servers take the same approach. Room-based servers dispose the room and disconnect its clients on an unhandled room error. Engines kick a single connection on a per-connection overflow or serialization error, and the client reconnects to a full state. Deterministic lockstep engines halt the session on a checksum mismatch. Supervision trees let the failed process end ("let it crash") instead of recovering it in place.

## Related

- [Sync Rules](sync.md)
- [Runtime Operation](runtime.md)
- [Deterministic Re-evaluation](reevaluation.md)

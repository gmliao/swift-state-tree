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
| A reference type (class) as synced state (#464) | refused at registration: `SyncValueSemantics.validate` (`LandTypeRegistry.swift:38`, `NIOLandHost.swift:363`, `SchemaExtractor.swift:20`) | current |
| A server event or a declared action response type without `@Payload` on a compressed encoding (`messagepack`, `opcodeJsonArray`) (#521) | refused at registration: `LandDefinition.validateForRegistration` (`NIOLandHost.swift:366`, `LandManager.swift:406`); on `json` it's written by its `Codable` form | current |
| Other type errors the type alone decides: an unsupported value or dictionary key type, a node with player-dependent fields under a broadcast field | found at sync time; handled as the first row under "The land ends" | target: refuse at registration (#535) |
| An existential synced field (`Any`, `any P`) | allowed; a value that doesn't convert is found at sync time and handled as the first row under "The land ends" | target: refused at compile time where the declared type spells `any` or `Any`, and `AnyHashable` and `AnyCodable` by name. A protocol spelled bare, a typealias to an existential and a hand-written conformance aren't caught there: such a field ends the land at its first failing conversion (#535) |

### The land ends

| Path | Today | Status |
|---|---|---|
| A field whose conversion throws at run time | the field is dropped for that sync (the client keeps its old value), the drop is counted and logged, and the rest of the frame goes out (`SyncEngine.swift:1405-1428`, `TransportAdapter.swift:4190`) | target: close the land (#535) |
| Dictionary keys that convert to the same string | the later entry silently overwrites the earlier one (`SnapshotValue.swift:424`) | target: close the land (#535) |
| A patch the encoding can't carry (for example a non-finite number in JSON) | the frame is re-encoded without that patch and sent; the field stays stale on clients until it changes (`TransportAdapter.swift:5663`) | target: close the land (#535) |
| A patch whose path is outside the schema | dropped as the row above, and counted (`TransportAdapter.swift:719-723`) | target: close the land (#535) |
| A sync plan that throws | in-turn sync: the first throw ends the land, its sessions close with 4016, no retry (`LandKeeper.swift:4447`, `:4892`). Legacy sync (off in-turn): nothing is sent and the plan is retried, on every tick with periodic sync, without it a bounded number of follow-ups | current for in-turn sync; target for legacy sync: the same (#535 PR 1 part B) |
| One player's state frame fails to encode entirely | nothing is sent to that player that cycle, and its client can stay behind on fields until they change again (`TransportAdapter.swift:4940-4951`) | target: close the land (#535, #532) |
| A resync's or first view's full view fails to encode | retried; after a bound, the session is closed with 4012 `unencodableView` (`TransportAdapter.swift:3634`) | target: close the land at the first failure, with no retry; 4012 is no longer sent (#535) |
| A server event that fails to encode | logged, and the event isn't sent (`TransportAdapter.swift:3026-3031`, `:3135`) | target: close the land (#521) |
| A handler that throws after writing state | the input fails alone and the inputs after it continue; its writes stay and are synced, with a warning in debug builds (`LandKeeper.swift:3836-3837`, `:3189`) | target: close the land (#535); #87 tracks the partial writes |
| The replay land re-emits a recorded event on a compressed encoding, under the opt-in `.projectedWithFallback` event policy (`GenericReplayLand.swift:21`; not the default) | `fatalError`, which stops the whole process (`MessagePackTransportMessageEncoder.swift:277`, `TransportMessageEncoder.swift:346`) | target: re-emit through the land's registry; an event that can't be resolved ends the replay land, never the process (#538, #521) |
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
| OnLeave and the destroy handlers | a failed land clears its players without OnLeave in the failing turn, and its destroy handlers and save run with `LandDestructionCause.failed` and `LandKeeper.failure` (`LandKeeper.swift:4892`). A host's stop that closes a session before the failure's teardown still runs that session's leave (`LandKeeper.swift:2397-2439`) | current for the failure's own teardown; target: the host's stop path also skips OnLeave on a failed land (#535 PR 1 part B) |

## Close codes

- **4016 `landFailed`:** a land that ends on a failure closes its sessions with it (current for an in-turn sync plan's throw; the other rows are the target, #535). Until #535 PR 1 part B, a host's stop that closes a session first gives it 4014.
- **4012 `unencodableView`:** sent today when a resync's or first view's frame keeps failing to encode. Once #535 lands it is reserved and no longer sent.
- **4014 `landStopped`:** an admin stop, unchanged.

## How other systems do it

Other servers take the same approach. Room-based servers dispose the room and disconnect its clients on an unhandled room error. Engines kick a single connection on a per-connection overflow or serialization error, and the client reconnects to a full state. Deterministic lockstep engines halt the session on a checksum mismatch. Supervision trees let the failed process end ("let it crash") instead of recovering it in place.

## Related

- [Sync Rules](sync.md)
- [Runtime Operation](runtime.md)
- [Deterministic Re-evaluation](reevaluation.md)

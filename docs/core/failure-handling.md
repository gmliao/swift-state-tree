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

The scope follows what the failure made wrong (decided in #535):

| The failure | What it made wrong | What ends |
|---|---|---|
| A type error knowable when the land is registered | every recipient, from the first sync | nothing runs: **registration is refused** |
| A failure that corrupts every recipient's view or the land's state, including a type error found only at run time | every recipient, or the state itself | **the land** is closed, and the error logged |
| If a failure is confined to one player's view | that player's client only | **that session** is closed. Rejoining sends a full view, which is correct again, so the land keeps running |
| A malformed input from a client | nothing yet | **that input** is rejected, and the client is told. The session and the land keep running |

An event that fails to encode is a fact about the value, not about who receives it: each event is encoded once, before it fans out to its recipients. So it ends the land, whatever its target (#521).

Whether any sync failure is confined to one player is open in #535. A player's view is a deterministic function of the land's state, so a rejoin would recompute the same failure, and no shipped encoder has a throwing input that depends on the recipient. #535 is deciding whether every sync failure ends the land instead. The session row states the principle; a failure that ends a session must not loop, so one that recurs after the rejoin ends the land.

## Where the code stands

Read at `main` 9755a625; line numbers are as of that commit. **Current** means the code already does what the rule asks. **Target** means it doesn't yet, and the issue tracks the change.

### Refused at registration

| Path | Today | Status |
|---|---|---|
| A reference type (class) as synced state (#464) | refused at registration: `SyncValueSemantics.validate` (`LandTypeRegistry.swift:38`, `NIOLandHost.swift:363`, `SchemaExtractor.swift:20`) | current |
| Other type errors the type alone decides: an unsupported value or dictionary key type, a node with player-dependent fields under a broadcast field | found at sync time; handled as the next row | target: refuse at registration (#535) |

### The land ends

| Path | Today | Status |
|---|---|---|
| A field whose conversion throws at run time | the field is dropped for that sync (the client keeps its old value), the drop is counted and logged, and the rest of the frame goes out (`SyncEngine.swift:1405-1428`, `TransportAdapter.swift:4190`) | target: close the land (#535) |
| A patch the encoding can't carry (for example a non-finite number in JSON) or a path outside the schema | the frame is re-encoded without that patch and sent; the field stays stale on clients until it changes (`TransportAdapter.swift:5663`) | target: close the land (#535) |
| A server event that fails to encode | logged, and the event isn't sent (`TransportAdapter.swift:3026-3031`, `:3135`) | target: close the land (#521) |
| A handler that throws after writing state | the input fails alone and the inputs after it continue; its writes stay and are synced, with a warning in debug builds (`LandKeeper.swift:3836-3837`, `:3189`) | target: close the land (#535); #87 tracks the partial writes |
| The replay land re-emits a recorded event on a compressed encoding, under the opt-in `.projectedWithFallback` event policy (`GenericReplayLand.swift:21`; not the default) | `fatalError`, which stops the whole process (`MessagePackTransportMessageEncoder.swift:273`, `TransportMessageEncoder.swift:336`) | target: re-emit through the land's registry; an event that can't be resolved ends the replay land, never the process (#538, #521) |
| Replay can't load or match a recorded input | the input is skipped with a warning, and the tick runs without it (`LandKeeper.swift:4126-4139`, `:4250-4256`) | target: the verification run fails, with the tick and the reason (#521; #535 tracks the rule) |

### The session ends

| Path | Today | Status |
|---|---|---|
| One player's state frame fails to encode entirely | nothing is sent to that player that cycle, and its client can stay behind on fields until they change again (`TransportAdapter.swift:4940-4951`) | target: end it, not continue; #535 decides whether the session or the land (#532) |
| A resync's full view keeps failing to encode | retried; after a bound, the session is closed with 4012 `unencodableView` (`TransportAdapter.swift:3634`) | current under the session row; may move to the land with #535's decision |
| The outbound writer drops a frame over its ceiling | every session the frame addressed is ended, and disconnected where the transport can close sessions; the clients rejoin and get a full view (`TransportAdapter+Outbound.swift:38-63`) | current |

### The input is rejected

| Path | Today | Status |
|---|---|---|
| An action whose payload doesn't decode | rejected at intake; the client gets an error (`LandKeeper.swift:2721`, `TransportAdapter.swift:6079`) | current |
| A client event whose payload doesn't decode | dropped without an error to the client (`LandDefinition.swift:276-277`), and still recorded as applied, since recording happens before the handlers run (`LandKeeper.swift:3487-3498`) | target: reject it, as for actions, and don't record it (#537) |

## Close codes

The close codes for a failure-driven close are to be defined by #535. The existing 4012 `unencodableView` is in use today.

## How other systems do it

Other servers take the same approach. Room-based servers dispose the room and disconnect its clients on an unhandled room error. Engines kick a single connection on a per-connection overflow or serialization error, and the client reconnects to a full state. Deterministic lockstep engines halt the session on a checksum mismatch. Supervision trees let the failed process end ("let it crash") instead of recovering it in place.

## Related

- [Sync Rules](sync.md)
- [Runtime Operation](runtime.md)
- [Deterministic Re-evaluation](reevaluation.md)

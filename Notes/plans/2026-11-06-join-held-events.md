# Join PR 4b: targeted events to a joining session are held, then sent after its firstSync (#69)

Status: open. PR 4b of [Join as a turn input](2026-11-05-join-as-turn-input.md) (decision 1 = B, test 4). 4a merged as #194.

## Today (after #194)

A joining session (`joiningSessions`) gets nothing but its JoinResponse before its flip. Targeted events meant for it are counted in `eventsDroppedForJoiningSessions` and lost. There are two paths:

- **Immediate mode** (json, opcodeJsonArray, and an opcode-107 event whose body doesn't encode): `sessionIDs(for:)` in `TransportAdapter+Outbound.swift` returns no session for `.session(S)` while S joins in a turn, and leaves the joining sessions out of `.player(P)`.
- **Merged mode** (opcode 107): the event body is queued in `pendingEventManager`. The plan reads the targeted bodies and leaves joining sessions out (they aren't recipients). The commit removes the consumed events and counts the joiner's share as dropped (`targetedEventsForJoiningSessions`).

Broadcast events are not affected: the firstSync reflects them (decision 1 = B).

## Change

**Hold instead of drop.** `JoiningSession` (in-turn joins) gets `heldEvents`, a list in arrival order, with a byte count.
- Immediate mode: `sessionIDs(for:)` appends the encoded frame for each in-turn joining session it leaves out, instead of counting it.
- Merged mode: the plan collects each in-turn joiner's targeted bodies from the events it consumes (the same membership-stamp checks as for a joined recipient). The commit appends them, in the plan's order, before the flips run.
- The order between the two paths is the one a joined session sees today: a body that falls back to its own frame goes out before the merged frame that carries the queued ones.

**Send at the flip.** The flip's writer element is JoinResponse, then firstSync. The held events follow in the same element, in order, as event frames:
- in merged mode, one standalone event frame per body (its own event frame, not a 107 frame);
- in immediate mode, the frames as encoded.

So the client sees the JoinResponse, then its full state, then the events, and nothing in between.

**Bound (the design choice).** At most 256 events and 256 KiB per joining session, the same defaults as the inbound deferral (4c), from `JOIN_HELD_EVENTS_MAX` / `JOIN_HELD_EVENTS_MAX_BYTES` through EnvHelpers and `TransportEnvKeys`.
- **Over the bound, the join fails** with a new reason `eventOverflow`, handled like `inboundOverflow`: the router sends a join error and closes the session, and the client reconnects to a fresh state.
- **The client sees a distinct code.** Today every in-turn join failure is answered with `JOIN_DENIED` (`LandRouter`'s `catch let flipError as JoinFlipError`).
  - `eventOverflow` gets its own `ErrorCode`, `JOIN_EVENT_OVERFLOW`, so the SDK's join error and ws-loadtest's join-failure report (`joinFailures.byReason`) name it.
  - The new `JoinFlipError` case is documented with the others, and in docs (EN and zh-TW) where the join failure reasons are listed.
  - The SDK's error-code type gains the value if it lists codes.
- Dropping the oldest or newest events would break decision 1's guarantee ("never dropped while the join succeeds") without the client knowing, and a join lasts at most `JOIN_FLIP_TIMEOUT` (10 s). So an overflow means the land is sending a joiner far more targeted events than a join window should hold.

**Leave, failed join, kick.** The held events go with the `JoiningSession` entry: they are discarded wherever the entry is removed without a flip (`disconnected`, `superseded`, `landClosed`, `onJoinFailed`, `timeout`, `eventOverflow`).
- `eventsDroppedForJoiningSessions` then counts only those discards, and it's 0 in any run where every join succeeds.
- `eventsHeldForJoiningSessions` counts the ones held and sent, for the measure branch and the rerun.

**Off path** (`IN_TURN_SYNC=false`): unchanged. Its `.player` drop for a joining session stays counted. The off path is the kill switch, removed in layer 3 PR B, and the rerun measures the in-turn path. (Holding there too would need a second delivery point after `syncStateForNewPlayer`.)

## Tests (held, no timing)

1. Merged mode: OnJoin sends `.session(S)` and `.player(P)` events. The joiner's frames are JoinResponse, firstSync, then the events in order, and the counter is 0.
2. Immediate mode (json): the same.
3. A `.player(P)` event while P has a joined session A and a joining session B: A gets it at once, B after its firstSync.
4. An event emitted between the join's consumption and the flip, held at the flip turn: it is delivered after the firstSync, not lost.
5. Bound: 257 events, then a payload over 256 KiB (two cases). The join fails with `eventOverflow` and a join error, the session closes, and the keeper's player is removed.
6. Disconnect, and a kick by a newer session, while events are held: no event frame is sent, and the discard is counted.
7. Mutation checks: with the hold removed, 1–4 fail; with the bound removed, 5 fails.

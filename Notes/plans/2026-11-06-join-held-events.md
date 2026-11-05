# Join PR 4b: targeted events to a joining session are held, then sent after its firstSync (#69)

Status: open (rev 2: review of rev 1 at b770108 addressed). PR 4b of [Join as a turn input](2026-11-05-join-as-turn-input.md) (decision 1 = B, test 4). 4a merged as #194.

**In-turn path only.** The off path (`IN_TURN_SYNC=false`) is unchanged; see the end.

## Today (after #194)

A joining session (`joiningSessions`) gets nothing but its JoinResponse before its flip. Targeted events meant for it are counted in `eventsDroppedForJoiningSessions` and lost. There are two paths:

- **Immediate mode** (json, opcodeJsonArray, and an opcode-107 event whose body doesn't encode): `sessionIDs(for:)` in `TransportAdapter+Outbound.swift` returns no session for `.session(S)` while S joins in a turn, and leaves the joining sessions out of `.player(P)`.
- **Merged mode** (opcode 107): the event body is queued in `pendingEventManager` with a membership stamp. The plan reads the targeted bodies and leaves joining sessions out (they aren't recipients). The commit removes the consumed events and counts the joiner's share as dropped (`targetedEventsForJoiningSessions`).

Broadcast events are not affected: the firstSync reflects them (decision 1 = B).

## The hold window

It opens at admission, when the session's `JoiningSession` entry is created (`admitJoining`), and closes at its flip or its failure. A targeted event emitted before admission (before the entry exists) isn't held. That's today's behaviour, and there's no session to address yet.

## Change

### 1. The registration keeps the admission's membership stamp

`admitJoining` registers the player (`registerPlayer`, ~1210), which stamps the session at version v1. The registration path (`_registerSessionImpl`, ~1088) calls `registerPlayer` again for the same session and player. `bindMembership` then moves it to v2.

An OnJoin targeted event is queued with v1, so it fails `isSessionCurrent`/`isPlayerCurrent` when the plan consumes it, and it would be lost even with a hold.

**Fix:** `registerPlayer` for a session already bound to the same player keeps its stamp. A re-registration of the same membership is not a new membership. A different player for the session, or a session not yet bound, binds as today.

### 2. Hold instead of drop

`JoiningSession` (in-turn joins) gets `heldEvents`, a list in arrival order, with a byte count of the encoded size at hold time.
- **Immediate mode:** `sessionIDs(for:)` appends the encoded frame for each in-turn joining session it leaves out, instead of counting it.
- **Merged mode:** the plan collects the targeted bodies for every in-turn joining session (`joiningSessions`, so the joiners past the flip budget too) from the events it consumes, with the same stamp checks as for a joined recipient. The commit appends them in the plan's order.
- **Order between the two paths:** what a joined session sees today. A body that falls back to its own frame goes out before the merged frame that carries the queued ones.

### 3. Capacity is decided in the plan, not in the commit

The bound is 256 events and 256 KiB per joining session, from `JOIN_HELD_EVENTS_MAX` / `JOIN_HELD_EVENTS_MAX_BYTES` (EnvHelpers, `TransportEnvKeys`).

**Merged mode.** The plan is synchronous and already reads the consumed bodies. It adds each joiner's share to its held count and size, and marks the joiners that would go over.
- A marked joiner is left out of the plan's joiners, frames and flips, so the commit never flips a join it also fails.
- After the commit, in the same turn, each marked joiner fails with `eventOverflow`.

**Immediate mode.** The overflow is found in `sessionIDs(for:)`, which only marks the session.
- The failure runs after the synchronous emit returns (`enqueueEventSynchronously`), never inside the target resolution.
- A marked joiner is not flipped.

### 4. Send at the flip, after a committed firstSync

The flip's writer element is JoinResponse, then firstSync. The held events follow in the same element, in order, as event frames:
- in merged mode, one standalone event frame per body (not a 107 frame);
- in immediate mode, the frames as encoded.

**Encode failure (`skippedJoiner`).** The session flips with no firstSync encoded, and its full view comes with the next full cycle's from-empty path. Its held events stay held until that firstSync commits, and then follow it in the same element. So a client never gets an event before its state.

### 5. `eventOverflow` fails the join

- A new `JoinFlipError.eventOverflow`, documented with the other cases and in the docs (EN and zh-TW) where the join failure reasons are listed.
- **The client sees a distinct code.** Today every in-turn join failure is answered with `JOIN_DENIED` (`LandRouter`'s `catch let flipError as JoinFlipError`). `eventOverflow` gets its own `ErrorCode`, `JOIN_EVENT_OVERFLOW`. The SDK's join error, and ws-loadtest's join-failure report (`joinFailures.byReason`), name it. The SDK's error-code type gains the value if it lists codes.
- **Cleanup goes through the router's explicit path**, as for `.timeout` and `.onJoinFailed`:
  - the binding is removed;
  - the join error is sent;
  - `container.transportAdapter.onDisconnect` runs (membership, slot, joining record, and the keeper's player through `keeper.leave` and the membership queue);
  - then `transport.closeSession`.
  - `closeSession` alone wouldn't reach the adapter, because the binding is already gone.
- Dropping the oldest or newest events instead would break decision 1's guarantee ("never dropped while the join succeeds") without the client knowing. A join lasts at most `JOIN_FLIP_TIMEOUT` (10 s), so an overflow means the land sends a joiner far more targeted events than a join window should hold.

### 6. Leave, failed join, kick

The held events go with the `JoiningSession` entry. They are discarded wherever the entry is removed without a flip: `disconnected`, `superseded`, `landClosed`, `onJoinFailed`, `timeout`, `eventOverflow`.

### 7. Counters

- **`eventsHeldForJoiningSessions`:** events released to the writer at a flip (or after the repair firstSync).
- **`eventsDroppedForJoiningSessions`:** events discarded with a failed join. That includes, on `eventOverflow`, the overflowing event and every event already held for that session.
  - It is 0 in any run where every join succeeds, **with in-turn sync on**.
  - The off path still counts its `.player` drops here.

### 8. What is verified

The opcode-107 events hash (`SyncOutputDigestInput.eventsScope`) covers the canonical consumption of events, not their delivery to each recipient. Held delivery isn't verified by replay; tests pin it.

Held frames are not counted as `eventsSentAlone`: they are the queued bodies' delivery to a joiner, not a body that failed to merge.

### 9. Event semantics (docs)

A joiner gets its held events after a firstSync that already reflects their effects. A client that applies events as deltas to its own state would count them twice.

Add to the event docs (`docs/core/land-dsl.md` § events and `docs/transport/README.md`, EN and zh-TW):
- Server events are notifications, and the synced state is the source of truth.
- For a joiner, the events held during its join describe effects already in its firstSync. They come right after it, in emission order.

## Off path (`IN_TURN_SYNC=false`)

Unchanged. Its `.player` drop for a joining session stays counted. The off path is the kill switch, removed in layer 3 PR B, and the rerun measures the in-turn path. The PR states that held events are on the in-turn path only.

## Tests (held, no timing)

1. **Merged mode:** OnJoin sends `.session(S)` and `.player(P)` events. The joiner's frames are JoinResponse, firstSync, then the events in emission order, and the dropped counter is 0.
2. **Immediate mode (json):** the same.
3. **Registration held** at `.registerSession`, with OnJoin events queued at admission. They are delivered after the firstSync, not lost to the stamp bump. This checks to fail without change 1.
4. **A `.player(P)` event while P has a joined session A and a joining session B:** A gets it at once, B after its firstSync.
5. **An event emitted between the join's consumption and the flip**, held at the flip turn: it is delivered after the firstSync. A joiner past the flip budget keeps its events to its own later flip.
6. **Bound, merged mode:**
   - 257 events, then (as a second case) a payload over 256 KiB, collected in one plan;
   - the overflowing joiner is not flipped by that commit (no JoinResponse, no firstSync for it) and fails with `JOIN_EVENT_OVERFLOW`;
   - the session closes, and the keeper's player is removed;
   - another joiner in the same commit flips normally.
7. **Bound, immediate mode:** the overflow found in `sessionIDs(for:)` fails the join after the emit returns, through the same router cleanup.
8. **Encode failure at the flip** (`skippedJoiner`): held events are not sent before the repair firstSync, and follow it.
9. **A disconnect and a kick** while events are held: no event frame is sent, and the discard is counted.

Mutation checks:
- with the hold removed, 1, 2, 4 and 5 fail;
- with change 1 removed, 3 fails;
- with the plan-time capacity check moved to the commit, 6 fails (the overflowing join is flipped and failed);
- with the `skippedJoiner` rule removed, 8 fails.

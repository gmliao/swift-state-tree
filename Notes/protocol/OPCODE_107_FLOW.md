# Opcode 107: Server-Side Flow Analysis

## Your question

Events are queued and sent together; sync happens after the tick completes. Is that correct?

**Yes.** Here is the exact order.

---

## Server timeline (one tick)

### 1. Tick runs

- **Process pending actions** (e.g. "attack" action) with `flushOutputsImmediately: false`  
  → Actions run, state is updated (e.g. monster HP → 0).  
  → Handlers can call `ctx.emitEvent(...)` → events are **only** written to `outputCollector.emittedEvents` (in-memory, not sent yet).
- **Tick handler** runs: `handler(&state, ctx)`  
  → More state changes and possibly more emitted events (same collector).
- **Commit**: `lastCommittedTickId = tickId`  
  → State is now “after this tick” (e.g. monster dead).

So at this point: **state is already the “after tick” state**, and **all events for this tick** are in `outputCollector.emittedEvents`.

### 2. `flushOutputs(forTick: tickId)` (same tick, right after handler)

- **Step A – “Send” events to transport**  
  For each item in `outputCollector.emittedEvents` for this tick:
  - `transport?.sendEventToTransport(item.event, to: item.target)`  
  With opcode 107 enabled, **TransportAdapter.sendEvent** does **not** send on the wire; it only **appends** `(target, event)` to `pendingServerEventsForNextSync`.
- **Step B – Sync**  
  If this tick requested sync (e.g. via `requestSyncBroadcastOnly()`):
  - `transport?.syncBroadcastOnlyFromTransport()`  
  Inside TransportAdapter:
  - Encode **current state** (the one after the tick) as state update.
  - For each client: if there are pending events and opcode MessagePack, build **107 = [107, statePayload, eventsArray]** and send; else send state only.
  - **Clear** `pendingServerEventsForNextSync`.

So:

- **Events are queued** in the adapter during Step A (still within the same “tick update”).
- **Sync runs only after** the tick has finished and state is committed; the state in 107 is exactly the “after tick” state.
- So: **this tick is fully updated → then we flush events (queue) → then we sync**. So “this tick updates first, then we sync” is correct.

---

## Summary

| Moment              | State                    | Events                                      | Network                |
|---------------------|--------------------------|---------------------------------------------|------------------------|
| During tick         | Being mutated            | Appending to `outputCollector.emittedEvents`| Nothing                |
| After tick handler  | Committed (e.g. dead)    | Still in collector                          | Nothing                |
| flushOutputs        | Unchanged (already committed) | Moved to adapter queue (`pendingServerEventsForNextSync`) | Nothing yet |
| syncBroadcastOnly   | Snapshot of current state used for 107 | Read from queue, then queue cleared   | 107 (or state only) sent |

So:

1. **Events are queued** (in LandKeeper’s outputCollector, then in TransportAdapter’s `pendingServerEventsForNextSync`) and **sent together** in one 107 frame.
2. **Sync runs after the tick has finished**; the state in that frame is the state **after** the tick (e.g. monster already dead in state).
3. The 107 payload is therefore: **state = after tick**, **events = emitted during this tick**. So “this tick updates completely, then we sync” is correct.

---

## Client-side order (events first, then state)

We chose **dispatch events first, then apply state** so that:

- The **event** (e.g. “attack hit”) is handled first → client can show cause (attack animation/sound).
- Then **state** is applied → client shows effect (monster dead).

So the client order matches the causal order (attack → death), even though on the server the state was already “monster dead” before we sent 107.

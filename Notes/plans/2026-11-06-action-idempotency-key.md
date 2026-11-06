# Action idempotency key (#103)

Status: open, rev 3. Based on `main` at `eeae9a78`. The trade-offs T1–T9 below go to the maintainer before implementation.

Rev 1 was reviewed with one blocking finding: a duplicate waiting on a superseded in-flight send got its rejection, so the reconnect case applied the action zero times. Rev 2 makes one waiter re-run in that case. It also adds:
- the partial-write reason for storing handler errors;
- the delivered-but-never-run class;
- the wire-skew check (done; the decoders are lenient);
- T8 (a waiting duplicate blocks its session);
- T9 (memory per stored outcome);
- the matching tests and mutants.

Rev 2 was reviewed GO. Rev 3:
- makes the hand-off a loop: a re-run can be rejected too, and the entry then goes to the next waiter;
- states per-process memory figures for T2 and T9, since there's one adapter per land.

## Problem

A client that resends an action (after a timeout, a lost response, or a reconnect) has it applied again. Nothing tells the server that two sends are one logical request: the action envelope's `requestID` only routes the response.

`requestID` can't be the key:
- **It restarts with the page.** The TS SDK makes it from a module-level counter (`generateRequestID`: `action-1`, `action-2`, …). After a reload, or in a second tab of the same player, `action-1` names a different request.
- **It's chosen for routing.** A client may reuse it once the response has arrived.

So the key is a new, optional field, distinct from `requestID`.

## Current semantics (main, `eeae9a78`)

- **Actions are at-most-once from the client's side** (the 2026-11-06 decision on #103).
  - A pending action is rejected with `ConnectionClosedError` when the connection closes (#109), and its outcome is unknown.
  - The client's state after the reconnect's firstSync is the source of truth.
  - Nothing resends automatically: not the SDK, the CLI or ws-loadtest.
- **Where an action goes** (`TransportAdapter.handleActionRequest` → `LandKeeper.handleActionEnvelope`):
  1. find the handler and decode the payload;
  2. intake: `rejectIfLandClosed`, `rejectSenderIfSuperseded` (#141, newest session wins), the sequence and the sender's ticket;
  3. the action's resolvers, if any;
  4. `deliverResolvedAction` appends the input.
- **What the response means depends on the land:**
  - **Tickless land:** the response is the handler's result, from the input turn that applied it (`awaitInputTurn`).
  - **Tick land** (Hero Defense, the game demos): the response is an empty ACK, returned once the input is queued. The handler runs in a later tick turn. A handler error there never reaches the client.
- **Error codes:** every action error except `actionNotRegistered` maps to `actionHandlerError` (`mapActionError`). The client therefore can't tell "didn't run" (superseded, land closed) from "ran and failed".
- **Since the 11-06 draft:**
  - **#224:** a joining session's inbound frames are held in the adapter (`deferredInbound`) until its flip. An action sent during the join reaches `handleActionRequest` after the flip, so the dedup point below sees it then.
  - **#230:** the router's join is one attempt. It doesn't change actions.
  - **#236:** it doesn't touch the action path.
  - **#237 (open PR):** every resolver group gets a deadline. A timed-out action resolver throws `ResolverExecutionError.timedOut`, and the action isn't delivered. The resolver's external effect may still happen, and the docs state that resolvers with side effects must be idempotent (at-least-once).

## Design (recommended options; the alternatives are in the trade-offs)

**Wire.** `ActionEnvelope` gains `idempotencyKey: String?`, encoded only when present.
- json: an optional `idempotencyKey` key in the envelope.
- opcodeJsonArray and messagepack: an optional trailing element of the action array (`[101, requestID, type, payload, key]`).
- **Skew, checked:** an old server ignores the new element, so a new SDK that always sends a key works against it.
  - Both array decoders take `array.count >= 4` and read elements 1–3 only: `OpcodeTransportMessageDecoder.decodeAction`, and `MessagePackDirectDecoder` case 101.
  - The same holds at `b629861` and at today's main. The JSON check has been `>= 4` since `6f3da95d` (2026-01-14).
  - The json object form decodes `ActionEnvelope` with `Codable`, which ignores an unknown key.
  - An old server simply doesn't dedup. A test pins the lenient decode, so a later strict count can't break new clients unnoticed.
- The schema and the docs (en + zh-TW) describe it. Without a key nothing changes, and old clients keep today's behaviour.

**Where: the adapter, before the keeper.** In `TransportAdapter.handleActionRequest`, before `keeper.handleActionEnvelope`.
- **The recording holds each input once.** The keeper records an action when it delivers it, so a filtered duplicate never becomes an input, and a recording replays unchanged. The ReevaluationRunner and the record format don't change.
- **The key isn't recorded.** `ReevaluationRecordedAction` stores the type and payload, not the envelope. Recordings don't grow, and replay has nothing to ignore.
- **Other callers are unaffected:** a direct caller of `LandKeeper.handleActionEnvelope` (benchmarks, tests) bypasses the adapter.

**Table: `ActionDedup`** (new, `SwiftStateTreeTransport`), owned by the adapter actor and keyed by `(playerID, idempotencyKey)`. An entry is one of:
- `inFlight(generation)`: the first send is in the keeper. A duplicate awaits the same outcome through `SingleFlight` instead of running again. That's the cross-session case: the old session's send is still in flight when the new session resends.
  - **A waiter that receives a not-stored outcome re-runs.** "Rejected before it ran" includes a superseded sender (#141, #148). In the reconnect case the old session's send is exactly that: once the new session takes the player's entry, `deliverResolvedAction` rejects the old send's ticket.
  - If waiters shared that rejection, the resend would apply the action zero times. Instead, on a not-stored outcome the entry goes back to `inFlight` with a new generation, in the segment where the rejection resumes.
  - Exactly one waiter, the first in arrival order, runs as a new first send, under its own session, clientID and ticket. The other waiters wait on the new generation.
  - **The hand-off repeats.** The re-run can come back not-stored too: its session was superseded in turn (a second reconnect), the land closed, or its resolver timed out (#237).
    - The rule is a loop: on every not-stored outcome, the entry gets a new generation and goes to the next waiter in arrival order. With no waiter left, the entry is removed.
    - Each hand-off happens in the segment where that rejection resumes, under the entry's ticket.
  - **A waiter whose session ended while it waited** is still suspended in the adapter. If it's picked, its re-run is rejected as superseded, and the loop moves on.
    - That's deliberate: a dead waiter is skipped only through that ticket-checked rejection, never by a shortcut that drops waiters without the ticket check.
  - The original sender still gets its own rejection, which is correct: its session was superseded.
- `completed(outcome, fingerprint)`: the stored outcome, plus the action's type and a hash of its payload.

**Turn rule** (CLAUDE.md, Reentrancy):
- The entry is inserted in the synchronous segment that decides to call the keeper.
- The outcome is written, and a not-stored entry removed or handed to a waiter, in the segment after the keeper's `await` returns, by the operation holding the entry's ticket (`GenerationTable`), never by key alone.

**Response routing.** A duplicate gets the stored outcome under *its own* `requestID`, so the SDK's callback for the resend resolves.

**Joins and client events.** Out of scope.
- **Joins:** #99 and #230 cover a repeated join, and a join carries no key.
- **Client events:** they have no response, and the demos' events (`MoveTo`) are idempotent. A follow-up issue can reuse the table if a land needs it.

**SDK (`sdk/ts`).** `sendAction(type, payload, { idempotencyKey })`.
- Whether a key is generated by default is T5.
- The SDK doesn't retry on its own. Retrying stays the app's choice, and the docs say so.
- Codegen'd `actions.*` wrappers pass the option through.
- The CLI gets a scenario step that resends an action with the same key.

## Open trade-offs (maintainer decision before implementation)

Each has a recommendation; the cost of each option is stated.

**T1. Scope of a key.**
- (a) **Per player within a land instance** (recommended).
  - It dedups across a reconnect, which is the main case. #92 already keeps one session per player.
  - A rejoin into a *new* instance of the land gets a fresh table.
- (b) Per session: simpler, with no cross-session in-flight case. It misses the reconnect, which is the reason for the feature.
- (c) Per player across land instances: needs state outside the adapter, in the router or realm. It only helps a client that rejoins a different instance and resends there, which is rare.

**T2. Dedup window.**
- (a) **Count-bounded** (recommended).
  - 128 completed keys per player, oldest evicted. In-flight entries are never evicted.
  - **A per-land cap** (there's one adapter per land): `maxPlayers × 128` entries, evicting the least recently used player's table. A land of 5 players holds at most 640 entries.
  - **Per process,** the entries are at most lands × maxPlayers × 128. That's 640,000 at 1000 lands of 5, about 100 B each without bodies, so about 64 MB. T9 bounds the bodies.
  - Both are configurable, with an env key in the `EnvConfig` pattern.
  - No wall clock, so tests stay timing-free.
  - At 20 actions/s per player, 128 keys is about 6 s of that player's history. That covers a reconnect. A player resending a burst after a long offline queue exceeds it by design.
- (b) A time TTL, e.g. 60 s, plus a count cap for memory. It's easier to document ("a resend within 60 s is deduplicated"), but tests need a manual clock, and memory grows with the action rate.
- **Either way:**
  - a player's table survives a disconnect, since the reconnect is the case;
  - it's dropped when the land is destroyed, and isn't persisted across a server restart;
  - a resend after eviction is applied again, as documented.

**T3. What a duplicate returns.**
- (a) **The stored outcome** (recommended): the same response or the same error, under the resend's `requestID`. The client can't tell it from the first answer, which is what a retry wants.
- (b) A distinct `DUPLICATE_REQUEST` error with no payload. It's simpler to store, since no outcome is kept, but every client has to handle a new error. In a tickless land the response is then lost if the first answer was lost.
- (c) A hybrid: the stored outcome plus a flag `duplicate: true`. Useful for debugging, but it's a wire addition with no client use yet.

**T4. Which outcomes are stored, and the #237 interaction.**
- **Stored:**
  - a response, which in a tick land is the empty ACK;
  - an error from the action's handler in a tickless land (it ran and failed).
    - Storing it isn't only a convenience. A tickless handler that throws keeps the state writes it made before the throw (#162: the turn consumes them and they go out with the turn's sync, `LandKeeper` near the comment on P's partial writes).
    - Re-running it would apply those partial writes twice.
  - **Delivered but never run**, stored as its response:
    - on a tick land, the input is ACKed and then the land drains or closes before a tick applies it (#158 rejects late inputs);
    - on a tickless land, `awaitInputTurn` ends because of the drain.
    - The stored outcome is what the first send got: the ACK, or the drain's error. A resend doesn't run it again: at-most-once, and the client reads the outcome from state.
- **Not stored:** a rejection before the action ran. The entry is removed, so a resend can succeed. That covers:
  - not registered;
  - a decode failure;
  - the land closed;
  - a superseded sender;
  - a resolver failure, a timeout (#237) or a cancellation.
- **The choice that matters is resolver failures and timeouts.**
  - (a) **Not stored** (recommended). A resend with the same key runs the resolvers again. That's at-least-once for resolver effects, which #237 already documents (resolvers with side effects must be idempotent), and the action is delivered at most once.
  - (b) Stored. A resend gets the same timeout error until the key is evicted, so the client must use a new key to try again. That re-runs the resolvers anyway, so (b) only adds a step.
- **Needs a code change either way:** the classification is server-side, by error type. The client-visible code is `actionHandlerError` for most of these today. The PR lists `handleActionEnvelope`'s throw sites with their class.

**T5. Opt-in or default.**
- (a) **The SDK generates a key for every `sendAction` by default** (recommended).
  - It's a random 128-bit hex string from `crypto.getRandomValues`, available in browsers and Node 18+.
  - An option opts out, and another lets the app pass its own key to retry.
  - The server dedups whenever a key is present. Dedup is then available without app work, but it does nothing until the app retries.
  - Cost: per action, about 40 bytes on the wire and one table insert. The tables at the caps are about 16,384 entries × (key + outcome) per adapter; see T9 for the outcome's size.
  - Skew: none against older servers, since their decoders ignore the extra element (see Wire). Recordings don't carry the key.
- (b) The SDK sends a key only when the app passes one. There's no cost for apps that don't retry, but an app that retries has to remember to pass a key.
- (c) Per action type on the server: a DSL flag such as `.idempotent` makes the key required for that action and rejects sends without one. It's the strictest, for purchases and trades, but it's a DSL addition. It can come later, on top of (a) or (b).

**T6. A key reused with a different action.** The same key arrives with another type or payload.
- (a) **Reject with a new error `IDEMPOTENCY_KEY_REUSED`** (recommended). It compares the stored type and a payload hash, and catches a client bug instead of returning an unrelated response.
- (b) Return the stored outcome anyway: cheaper, with no hash, but a client bug looks like success.

**T7. Tick lands: what dedup buys there.** In a tick land the response is the empty ACK at enqueue, and the handler's result never goes back to the client.
- Dedup there prevents a second enqueue, so the effect isn't applied twice. A duplicate gets the ACK.
- That's the intended protection. It doesn't make the handler's result visible, and the client still reads the outcome from state.
- No alternative proposed; this is stated so the decision covers it.

**T8. A duplicate that waits blocks its session.** A session's inbound frames are handled in order (the session's inbound chain from #112, then the router, then the adapter).
- A resend that awaits the in-flight first send holds that session's later frames until the first completes.
- With a resolver, that's up to the resolver deadline: 5 s, #237. #113 may then pause the session's reads.
- **Options:**
  - (a) **Wait, keeping order** (recommended): the duplicate answers after the original, and the session's later frames follow it. The bound is the resolver deadline. It applies only to a duplicate that arrives while its original is in flight, which in practice is a reconnect during a slow resolver.
  - (b) Answer `IN_PROGRESS` at once, and let the client retry later. Nothing blocks, but it's a new error every client must handle with a backoff, and it brings back the client-side retry loop this feature avoids.

**T9. Memory per stored outcome.** T2 counts keys, not bytes. A tickless response can be large, and there's one adapter per land, so a per-adapter bound doesn't bound the process. Tick-land outcomes are the empty ACK, a few bytes.
- **In every option:** a stored body is capped at 4 KiB, configurable. Above it the entry is stored "completed" without the body. A duplicate then gets a `DUPLICATE_REQUEST` error that says the original completed; a retry of a large-response action can't recover its body, and that's documented.
- (a) **Plus a process-wide byte budget for bodies** (recommended), default 64 MiB, configurable.
  - It's a shared atomic counter of stored body bytes: an adapter adds a body's size when it stores it and subtracts it on eviction or land destroy.
  - When a store would exceed the budget, the entry is stored without its body, the same fallback as above the per-body cap. Nothing is evicted across lands.
  - **Per-process worst case:** 64 MiB of bodies, plus T2's entry overhead, about 64 MB at 1000 lands of 5. So about 130 MB at the defaults; the body part doesn't grow with the land count.
  - Cost: one atomic add per stored outcome. There's no cross-adapter lock and no cross-land eviction.
  - **The budget is first-come.** One land storing large outcomes can use it up. The other lands' duplicates then get `DUPLICATE_REQUEST` instead of their stored response: degraded and bounded, not wrong.
  - **The counter is released on every path that drops a body:** count eviction, the per-player cap, the land's destroy, and a body replaced by a hand-off outcome.
- (b) Per-land bounds only: the 4 KiB cap × T2's per-land entries.
  - The per-process worst case is lands × maxPlayers × 128 × 4 KiB: about 2.5 GiB at 1000 lands of 5, and more with larger lands.
  - Simpler, with no shared state, but the bound grows with the land count.
- (c) A process-wide budget that evicts the least recently used body across lands. It keeps large bodies while there's room, but it needs a shared index of every land's entries, a lock across adapters, and eviction that depends on sizes, which is harder to reason about and test.

## Tests (forced interleavings, no timing)

Swift (`TransportAdapterActionDedupTests`), each in both in-turn modes, on a tickless and a tick land where it matters:
1. The same action twice with one key on one session: applied once; two identical outcomes, each under its own `requestID`.
2. A duplicate while the first is in flight: hold the action's resolver (`TestGate`), resend from a second session of the same player (a reconnect), release. One application, and both callers get the outcome.
3. A reconnect, then a resend with the same key after completion: applied once.
4. Eviction: 129 keys, then a resend of the first: applied again.
5. The same key from another player: applied (no match).
6. A rejection before the action ran (a superseded sender), then a resend from the current session: applied.
7. A tickless handler error is stored: a resend gets the same error, and the handler ran once.
8. A resolver timeout (with #237) isn't stored: a resend with the same key runs the resolvers again and delivers once.
9. A key reused with another payload: `IDEMPOTENCY_KEY_REUSED`, and nothing is applied (if T6 a).
10. No key: applied twice, unchanged behaviour.
11. A recording of case 1 holds one action input and replays with 0 mismatches.
12. Wire: the key round-trips in json, opcodeJsonArray and messagepack, and an envelope without it decodes as before.
13. #224: an action sent during a join (deferred until the flip) and resent after it: applied once.
14. **The blocking case:**
    - the old session's send passes intake and its resolver is held;
    - the player reconnects, and the new session takes the entry;
    - the new session resends the key and waits;
    - release: the old send is rejected as superseded, the waiter re-runs as a new first send, and the action is applied once;
    - the old sender gets its rejection, and the resender gets the response.
15. The same, with two waiters (two resends from the new session): one re-runs, the other gets its outcome, and the action is applied once.
15b. **Repeated hand-off:** three sessions of the player in turn. The first send and the second session's waiting re-run are both superseded, and the third session's waiter re-runs. Applied once, by the third.
15c. A waiter whose session ended while it waited is picked: its re-run is rejected as superseded, and the next waiter re-runs. Applied once.
15d. **Body budget (T9 a):** with a small test budget, a store that would exceed it keeps the entry without its body. A duplicate gets `DUPLICATE_REQUEST`. The counter goes down when an entry is evicted by the per-player cap, and returns to 0 after the land is destroyed.
16. **Drain:** on a tick land the action is ACKed, then the land drains before a tick. A resend gets the stored ACK, and nothing is applied. On a tickless land the drain error is stored the same way.
17. **Order (T8 a):** a duplicate waiting in flight, then a later frame from the same session (an event that changes state). The later frame isn't applied before the duplicate answers.
18. **Skew:** an action array with a fifth element decodes on the opcode and messagepack paths, with the element ignored by the old field set. That pins the lenient decoders.

Row 8 (resolver timeout) uses #237's pattern: a stuck gate that ignores cancellation and a 20 ms deadline. Nothing else is timing-sensitive.

TS: `sendAction` sends a key per T5, and a resend with the option reuses it (vitest). Codegen passes the option through. CLI E2E: a scenario sends an action twice with one key and asserts one effect.

Mutation checks before the PR:
- the outcome written by key alone, without the ticket;
- a stored resolver timeout;
- no fingerprint check (if T6 a);
- eviction of an in-flight entry;
- no second hand-off (row 15b must fail);
- the body counter not decremented on eviction (row 15d must fail), and separately not on destroy (row 15d must fail);
- waiters sharing a not-stored outcome (row 14 must fail);
- more than one waiter re-running (row 15 must fail);
- the entry removed by key alone on a rejection, without the ticket;
- the dedup placed after the keeper call.

## Steps

1. **Core PR:**
   - the `ActionEnvelope` field and the three encoders and decoders;
   - `ActionDedup`, the adapter wiring and the error classification;
   - the config and env key;
   - the Swift tests;
   - the docs (en + zh-TW).
2. **Direct to main after the merge:** the SDK key and option, the codegen pass-through, the CLI scenario, and the regenerated example clients.

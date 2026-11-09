# Core round and full rerun (2026-11-09)

The 2026-11-08 measurement round found three gaps that need core changes:
- The slow-reader cells of the network-impairment topic never reached the server's send-backlog bound. The kernel's autotuned socket buffers absorbed 180 s of updates, so the bound (#61, `SendBacklogBound`) never saw a backlog.
- A tickless land's replay applies inputs in sequence order, not in live apply order (#325, #321).
- The 3.x recorder's timer flush splits a tick across writes (#327).

Measuring the current code would publish numbers for behavior we already plan to change. Instead, this round lands the core changes first, ends the wire and record-format freeze, and reruns every topic once at one new SHA.

The data committed in the 2026-11-08 round stays in git history as the record of the earlier code.

## Scope

| # | Change | Kind |
|---|---|---|
| 1 | Merge the held PRs #317, #318, #319, #320, #322 | merge |
| 2 | Recorder flush at a turn boundary signalled by the keeper (#327, option A) | core PR |
| 3 | Tickless replay applies inputs in recorded apply order, with per-pass sequence watermarks (#325 with #321); record-format version bump | core PR |
| 4 | Action completion queue to `main`: PRs 1–3 from `exp/action-completion-queue`, then PR 4 (unblock the chain on tickless lands, after step 3) | core PRs |
| 5 | Sync lag from client acks: resync a session that falls behind, disconnect one that keeps falling behind or stops acking (below) | core PR + SDK + load client |
| 6 | Network-impairment topic: recovery criterion against each session's own baseline; slow-reader cells expect a resync; client fixes from the 2026-11-08 run | direct (`deep-research/`, `Tools/`) |
| 7 | Refreeze at one SHA, then rerun every topic and commit the data | host + data commits |

Out of scope for this round: a `SO_SNDBUF` cap, and lowering `SendBacklogBound`'s defaults. With step 5, the existing bound is only a last-resort memory guard.

## Step 5: sync lag from client acks

*Revised 2026-11-09: the resync is in place, on the live connection, and the player never leaves; details in [the design note](2026-11-09-sync-lag-from-client-acks.md). The rows below are updated to match.*

**Problem.** Over TCP the server can't see how far behind a client is. Data handed to the kernel counts as sent, wherever it then sits: the server's send buffer, the network, or the client's receive buffer. Engines on UDP with their own reliability layer track unacked data directly. This step gives the server the same information.

**Mechanism.**
- Every sync frame to a session carries a per-session sync sequence number.
- The client acks the latest sequence it has applied, about once a second and on every resync. The ack is a small new wire message, so the wire version is bumped.
- The server computes each session's lag as the time since the newest sync that the client has acked.

**Rules.** All thresholds are configurable through `*EnvKeys` constants with defaults:

| Condition | Action |
|---|---|
| Lag under 3 s | Nothing. Short stalls recover on their own. |
| Lag over 3 s while acks still arrive | Resync in place: the server sends a fresh full view on the live connection, and the client clears its state and applies it. |
| A third resync within 60 s | Close as a slow consumer. The client does not auto-rejoin. |
| No ack for 10 s while frames are unacked | Close as unresponsive. |

**Semantics.** A resync replaces the client's view in place. The player stays a member, with no leave or join. Events emitted while it is behind aren't delivered, the same as for a client that reconnects. No event is ever applied on top of state the client hasn't reached.

**Constraints.**
- Lag state lives outside keeper turns, so it follows the reentrancy rule in CLAUDE.md. The close decision is checked against a session ticket captured before any `await`. Tests force the interleavings with hold points.
- The ack is not a turn input. It is never recorded and doesn't touch land state.
- `SendBacklogBound` (8 MiB / 30 s unwritable) and the pong timeout stay as they are, as a memory guard and a transport-level keepalive.

**Needs:**
- TS SDK: sending the ack, and applying the resync update after clearing its state;
- ws-loadtest: the same, plus counters for resyncs and slow-consumer closes;
- docs in both languages;
- codegen if the schema changes.

This step starts with a short design note for Review: frame field, ack cadence, ticket handling, and close codes. The PR follows.

## Step 6: network-impairment topic

**Recovery criterion.** It replaces "every session within the other P0 repeats' max-gap band". A session has recovered after the impairment lifts when all of these hold:
- its state converged;
- it received updates throughout the last 10 s;
- its update-gap p99 in the last 10 s is at most its own pre-impairment p99 plus one sync interval (100 ms).

The P0 repeats are checked the same way, as the control. Before changing the topic, the criterion is tried on the held 2026-11-08 data: every P0 repeat should pass, and the impaired cells should be told apart.

**Slow-reader cells (SR, SR-CAL).** A reader that stops reading should be resynced in place about 3 s after its lag starts, through step 5. A reader that keeps stalling across resyncs should be closed as a slow consumer. `srpause.py` and the topic's checks follow the new close causes. The receive-buffer cap considered on 2026-11-09 isn't needed.

**Client fixes in ws-loadtest**, both gated on `--slow-read`:
- a slow reader that rejoins inside its window pauses again (`readPausedAt` reset on reconnect);
- the stale check measures silence by bytes on the socket, not by handled messages, so a client draining a backlog isn't counted as silent.

The plan's § 5 and § 7 and the topic README are updated in the same change. `--check` gets tests for the new criterion.

## Order and gates

1. Merge the held PRs (step 1) after merging main into each, rerunning CI, and getting a Review delta if main moved under them.
2. Steps 2, 3 and 5 run in parallel:
   - Builds on the measurement host stop while it measures.
   - Builds on the development machine share its build slot.
3. Step 4: PRs 1–3 go to `main` once step 1 has merged. This means merging `main` into the experiment branch, plus one PR to `main` with Review. PR 4 follows step 3.
4. Step 6 follows step 5, because its slow-reader checks need the new close codes. The criterion work can start earlier on the held data.
5. Each core PR passes these gates:
   - a plan, or a short design note, reviewed for anything beyond a bounded fix;
   - Review GO;
   - green CI on the PR itself at the reviewed head;
   - a squash merge pinned to that head;
   - green CI on `main` after the merge.

   Record-format and wire-version bumps update docs, the SDK and codegen in the same PR.
6. **Refreeze (step 7).**
   - `swift test` and all three E2E encodings are green.
   - A replay run on the new record format shows 0 mismatches.
   - The SHA is picked once all of this holds. The host reruns every topic there from calibration, with a smoke per topic first. The keep-passed-topics rule doesn't apply this round: every topic reruns.
   - Data commits go one topic at a time. Each runs the privacy grep, the absolute-path grep and the Windows-path grep as separate steps. Each SHA's Swift Build & Test must be green before the next push.

## Estimates (agent time)

| Work | Estimate |
|---|---|
| Step 1 | about 1 h |
| Step 2 | half a day to a day |
| Step 3 | half a day to a day |
| Step 4 | half a day |
| Step 5 | about a day, design note included |
| Step 6 | half a day |
| Step 7 | about a day of host time, plus half a day of data commits |

Total: 3 to 4 days.

# Network impairment experiment: design

Status: **design rev 3, awaiting the design check.** Engineering starts after it; nothing runs before the host checklist in § 10 has passed.

Revisions:

- **Rev 3** narrows the planned runs to 27 (§ 8): population U with five profiles, M with three, and the slow reader SR, all at 300 rooms. The rest of the rev 2 matrix stays below as a documented extension that isn't planned. § 10 is now a self-contained checklist for the measurement host.
- **Rev 2** followed an adversarial design review:
  - netem in a forwarding namespace, with explicit queue limits, in-place changes and a FIFO child for jitter;
  - outage and backlog expectations separated from guarantees;
  - per-session close reconciliation;
  - raw-sample exports;
  - recovery gated on population and sample coverage;
  - shared-room orchestration;
  - full-coverage convergence with state reconstruction;
  - isolation controls and the slow reader;
  - a memory criterion tied to what each bound covers;
  - corrected load-point reasoning;
  - separate budgets for each stage.

Topic folder once it runs: `deep-research/network-impairment-2026-11/`.

## Question

When the client–server network is delayed, jittered, lossy, throttled or cut for a while, what happens to the server? Four questions, each answerable from a table:

1. How far do input-to-visible latency and the server's send backlog grow?
2. How long does each take to come back after the impairment ends?
3. Does every client end in the server's state?
4. Are clients whose own network is fine affected, in the same room or in other rooms?

The answers cover the **synthetic conditions tested here**: netem profiles on one host. They are not a claim about any particular real network.

This is a **design run** in the `sst-experiment` sense. It adds an impairment axis, new populations, and new metrics: recovery, reconnect, and convergence under load. The tool needs new options, listed in § 9.

## Prior lessons applied

- **`Notes/solutions/2026-11-05-load-tool-is-the-bottleneck.md`.** Extra latency makes the client hold more pending requests and timers. Each segment of each run records the worst worker's loop delay p99 and the client's CPU. A segment whose worst-worker loop delay p99 exceeds 20 ms is marked *client-bound*, and its latency isn't read as the server's.
- **`Notes/solutions/2026-11-07-benchmark-option-honoured-on-one-path-only.md`.**
  - Each new option is smoked on every entry path with a pair of runs whose output must differ.
  - A run records the impairment actually applied (the `tc` commands and counters), not only the one requested.
  - The analysis refuses a run whose recorded config doesn't match its cell.
- **`Notes/solutions/2026-11-06-unbounded-queues-and-awaits-at-boundaries.md`.**
  - The bounds under test are the send backlog bound (`WS_SEND_BACKLOG_MAX_BYTES` 8 MiB, `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS` 30 s, close 4008), the pong timeout, and the inbound bound.
  - Every breach must be visible. § 7 reconciles each close with a cause.
- **`Notes/solutions/2026-11-05-hold-points-not-timing-in-race-tests.md`** doesn't apply: this is a measurement, not a race test.

## 1. Topology: where netem applies

The baseline rerun (`deep-research/multiroom-load-2026-11`) ran the server and the client in one Linux environment, on `localhost`.

**Choice: impair in a forwarding namespace between the client and the server.**

```
[lt-client ns]                [lt-router ns]                    [container ns]
 load client   veth-c0 ── veth-c1  (forwarding)  veth-s1 ── veth-s0   GameServer :8080
 10.201.0.2                10.201.0.1     10.200.0.2                 10.200.0.1
```

- **Downstream** (server → client) is shaped on `veth-c1`'s egress, inside `lt-router`.
- **Upstream** (client → server) is shaped on `veth-s1`'s egress, inside `lt-router`.
- Neither TCP endpoint's own egress carries a netem qdisc. That avoids the distortion the netem man page warns about when a qdisc sits on the sending TCP endpoint (TCP Small Queues).
- `lt-router` forwards with `net.ipv4.ip_forward=1`, a sysctl local to its namespace.
- The load client connects to `ws://10.200.0.1:8080/game/hero-defense`. The scenario's `serverUrl` already takes this.
- Population M (§ 4) adds a second client namespace, `lt-good`, attached to `lt-router` through its own veth pair, whose router-side qdisc stays at P0.

**Offloads.** TSO, GSO and GRO are off on every veth end, with MTU 1500, so netem sees wire-sized packets. The smoke checks the effective state with `ethtool -k`, and doesn't rely on the commands' exit codes.

**The qdisc tree on each shaped interface** is attached once, before the run, and stays for the whole run:

- **root:** `netem` with an explicit `limit` (see below);
- **child:** a `pfifo` with its own explicit limit. With jitter, this is the FIFO composition the netem man page gives for jitter without reordering. It is attached in every profile, so every profile has the same tree.

**Profile changes happen in place.** A profile is applied and lifted with `tc qdisc change`, never `del` or `replace`, so queued packets and counters survive the boundary.

- Lifting means changing back to P0's parameters. Packets already delayed still drain with their old delay; the timeline records the change time, and recovery is measured from it.
- An outage (100 % loss) drops at enqueue, so nothing is queued behind it.

**Queue limits.** netem's default limit is 1000 packets. At 1500 connections with 50 ms of delay, it can overflow and add loss that no profile asked for. Each shaped interface instead gets:

```
limit = max(10000, 4 × packets per second × (delay + 4 × jitter) in seconds)
```

The packet rate is P0's measured peak per-second packet rate on that interface. Delay-only and jitter profiles must show zero qdisc drops; a run with any is invalid and rerun with a larger limit. Loss and rate profiles report the qdisc's own drops apart from netem's loss drops (the `tc -s` counters separate them).

**Rejected alternatives:**

- **netem on each TCP endpoint's egress** (rev 1): the TCP Small Queues confound above.
- **Receiver ingress through IFB:** equivalent to the router for this purpose. It needs the `ifb` module as well, and it is harder to check by eye.
- **Filtered `lo`:** it shares the loopback's segment sizes and puts the client's and the server's sockets in one namespace.
- **Two containers on a Docker bridge:** a valid option. It changes the container layout relative to the baseline, which a forwarding namespace inside one container doesn't.

**What the topology itself changes.** Even with zero impairment, traffic crosses three veth hops and a forwarding namespace instead of `lo`. The control profile P0 measures that cost on the same topology. No number is compared directly with the localhost rerun.

### Verifying the impairment

**Pre-sweep calibration**, once per profile and load point, under load:

- **Delay:** 600 pings at 0.1 s intervals (`ping -i 0.1 -c 600`) from `lt-client` to the server, during a P0-level load run. The median and p90 must be within 2 ms of the configured RTT, and within 2 ms of the configured RTT plus the jitter's expected spread.
- **Loss:**
  - The netem loss-drop delta over *offered* packets (sent + dropped) must be within ±0.2 points of the configured rate. It is measured over at least 200,000 offered packets, which puts a 1 % rate's 95 % binomial interval at about ±0.04 points.
  - The burst-loss profile is checked against its model's mean loss rate.
- **Rate:**
  - The qdisc's dequeued bytes per second (`tc -s`, including headers, ACKs and retransmissions) must be within ±5 % of the configured rate during the throttle window.
  - Application payload bytes per second are reported next to it, from the client report.
  - Every load point and population with a RATE cell is calibrated separately.
- **Order:** for 10 s of D50J10 under load, a capture (`tcpdump -w`, receiving side of each direction, in the router namespace) is checked for TCP sequence numbers that decrease within a flow, excluding retransmissions. Both directions must show none.

**Per run**, before and after each boundary:

- `tc -s qdisc show` on every shaped interface;
- `ethtool -k` on every veth end;
- `ss -tn` in each client namespace at steady-state start, which must show every load connection to `10.200.0.1:8080`.

All of these go into the run's provenance; a run with a failed check is invalid.

## 2. Load points

**Client settings:** the rerun's defaults, which are `--layout rooms`, 5 players per room, `--send spread`, `--connect ramp` at 1000/s, 12 workers, 1 action per player per second, and Hero Defense. Plus `--input-latency on --move-to-rate 1`, so input-to-visible has samples.

**Planned:** 300 rooms (1500 connections).

**Extension, not planned:**

- 100 rooms with the full profile set;
- 500 rooms (2500 connections) with P0, COMBO, RATE and BO75.

The baseline rerun's 500-room runs passed with zero disconnects. Server CPU was about 3.6 cores of the 8 pinned, so 500 rooms isn't a saturation point; it is left out only for time.

## 3. Impairment profiles

"Each way" means the value is applied to upstream and downstream separately.

| ID | Upstream | Downstream | Impaired for | Purpose | Planned in |
|---|---|---|---|---|---|
| P0 | no delay | no delay | none | Control: the same topology and qdisc tree | U, M |
| D50 | 50 ms | 50 ms | 60 s | +100 ms RTT, delay only | extension |
| D50J10 | 50 ± 10 ms | 50 ± 10 ms | 60 s | Jitter, no reordering (FIFO child) | U |
| L1 | 25 ms, 1 % loss | 25 ms, 1 % loss | 60 s | Independent loss, mild | extension |
| L5 | 25 ms, 5 % loss | 25 ms, 5 % loss | 60 s | Independent loss, heavy | U |
| GE | 25 ms, burst loss | 25 ms, burst loss | 60 s | Correlated loss, Gilbert–Elliott (`loss gemodel`), mean 2 %, mean burst 5 packets; exact parameters fixed at calibration | extension |
| ASYM | 10 ms | 80 ms, 1 % loss | 60 s | Asymmetric | extension |
| COMBO | 40 ± 10 ms, 1 % loss | 40 ± 10 ms, 1 % loss, rate 0.8 × P0 downstream | 60 s | Combined | M |
| RATE | none | rate 0.5 × P0 downstream | 60 s | Aggregate throughput shortfall | U |
| BO10 | 100 % loss | 100 % loss | 10 s | Short outage | extension |
| BO45 | 100 % loss | 100 % loss | 45 s | Medium outage | extension |
| BO75 | 100 % loss | 100 % loss | 75 s | Long outage, past the pong-timeout window | U, M |

**What the planned runs cover:**

| Impairment kind | Planned runs | What they show |
|---|---|---|
| Delay and jitter | U-D50J10; M-COMBO | Latency growth against the added RTT, and in-order jitter (§ 1) |
| Loss | U-L5; M-COMBO (1 %) | Retransmission cost and recovery; closes only through a bound |
| Rate limit | U-RATE; M-COMBO (0.8 ×) | Send-backlog growth, unwritable episodes, closes by the bound, and recovery |
| Outage, with backlog and recovery | U-BO75; M-BO75 | Guaranteed pong-timeout activation, the backlog during the outage, reconnect with `firstSync`, recovery and convergence |
| Isolation | M-COMBO; M-BO75 (healthy groups) | Same-room and cross-room effects on healthy clients |
| Per-client backlog bound (4008) | SR | Guaranteed 4008 for independent slow readers, healthy room-mates unaffected, reconnect with `firstSync` |

BO10 and BO45 aren't planned. The pong-timeout window they would characterise is covered by BO75's guaranteed activation, and by the code analysis below.

**P0 downstream** is measured per load point and per population, in qdisc bytes per second. The cell config records the aggregate rate and the per-connection equivalent. A rate on the shared veth throttles all impaired clients together, so it is not a per-client access link; the per-client case is the slow reader, SR (§ 4).

**Expected observations versus guarantees,** from the code:

- **Pong timeout.** The server pings each session every 30 s, with per-session phases, and arms a 20 s deadline when it writes the ping. Any inbound frame cancels the deadline, not only a pong (`WebSocketSessionHandler.notePeerAlive`). From an outage's start, a session is detected between about 20 and 50 s later. So:
  - **BO10:** closes no session through the pong timeout.
  - **BO45:** closes some sessions, depending on ping phase. It is characterisation, not a guarantee.
  - **BO75:** must close every impaired session that stays silent. It is the guaranteed-activation cell.
- **Backlog bound.** The 30 s unwritable timer starts only when the channel becomes unwritable (above the 64 KiB high watermark, after the kernel's socket buffers have filled), and it resets when the channel is writable again. It isn't an outage timer.
  - RATE and COMBO are characterisation: how many sessions became unwritable, for how long, and how many reached 4008.
  - The guaranteed backlog activation is the slow reader (§ 4), whose pause is calibrated to exceed the time-to-unwritable plus 30 s.

**Timeline of an impaired run:**

1. join and warm-up, unimpaired;
2. a 30 s baseline segment;
3. the impaired segment;
4. a 90 s recovery segment;
5. quiescence and the convergence check (§ 6);
6. leave.

P0 runs keep the same timeline with no changes at the boundaries.

## 4. Populations

| ID | Composition | Answers |
|---|---|---|
| U | All clients in `lt-client`; everyone impaired | How the server behaves when its whole client population is impaired |
| M | `lt-client` holds one player in each of half the rooms (the *mixed rooms*). `lt-good` holds the other four players in those rooms, and all five players of the other half (the *healthy rooms*) | Same-room effect (healthy players in mixed rooms vs P0) and cross-room effect (healthy rooms vs P0), in one run |
| S1 | One impaired client in one room; everyone else healthy | The single bad client. **Extension, not planned** |
| SR | Like M, but the impaired players are slow readers (below) rather than netem-shaped. Their namespace stays at P0, so SR's control is M's P0: the same topology, rooms and instances | Per-client backlog with independent clients, and guaranteed 4008 activation |

**Slow reader** (`--slow-read <start>:<duration>`, a new client option): the client stops reading its socket for the duration (`pause()` on the underlying TCP socket) and keeps sending its actions on schedule. The duration is calibrated in the smoke at each load point as the measured time-to-unwritable plus 30 s plus 10 s. At the end, the client resumes reading, or finds itself closed.

**M and SR need two client instances that share rooms.**

- **Rooms:** both instances get the same land IDs and disjoint slots. That is a new option, explicit land-ID and slot lists; the run ID and players-per-room are no longer part of the generated ID.
- **Start:** a shared barrier, `--start-at <epoch ms>`.
- **Workers:** a split of the 12 workers between the two instances, in proportion to their connections.
- **Check:** server-side room membership is verified through the admin API before the baseline segment starts. A room with the wrong count fails the run.

**Groups reported separately:**

- U: impaired.
- M and SR: impaired, healthy in mixed rooms, healthy in healthy rooms.
- S1 (extension): the bad client, its room-mates, and everyone else.

## 5. Metrics and their semantics

Each sample is assigned to a segment (baseline, impaired, recovery) by the timestamp named below, never by its arrival time when another one is named.

| Key | One unit is | Assigned by | Status |
|---|---|---|---|
| `inputToVisible` samples | One move event: its actual send time, its latency, or its outcome (`seen`, `superseded`, `timedOut`, `pendingAtEnd`, `closedBeforeSeen`) | actual send time | **new export**: timestamped per-event records. The current report has only phase totals |
| `rtt` samples | One action: intended send time, response time, and outcome (`answered`, `late` (after 5 s), `pendingAtEnd`, `timedOutAtEnd`, `closedBeforeAnswer`) | intended send time | **new export**. The current windows bucket RTT by response arrival |
| `updateGap` samples | One state update at a connection: its arrival time and the gap since the previous one | arrival time | **new export** (`update`) |
| `joined` per second | The number of joined, open connections per group | sample time | **new export** |
| `sendsAchieved` per second | Actions actually sent per group, against the target | send time | existing counts, **new**: per-second and per-group |
| Server profile per 1 s window | `sendBufferedBytesMax` (the largest single session's NIO outbound buffer after a write, not a sum), `sendUnwritableEpisodes`, `sendUnwritableSessions` (gauge), `sendUnwritableLongestMs`, `sendBacklogCloses`, `pongTimeoutCloses`, `closeFrameTimeouts` | window time | existing in the profile; **new**: the report reads `pongTimeoutCloses` |
| `closes` | One server-initiated close as the client saw it: time, close code (`CloseRecord`, already recorded), group, land, player | close time | existing records, **new**: aggregation by code and group |
| `reconnect` | One reconnect: close time, the time the new socket opened, the join answer time, and the first `firstSync` time; reported as `downtimeMs` (close → firstSync), `connectMs` and `joinToFirstSyncMs` | close time | **new** (client option, § 9) |
| `firstSyncBytes` | The size of that `firstSync` frame | | **new** |
| `convergence` | Per room: `converged`, `mismatched` (with paths), `inconclusive`, `missingClients` | after recovery | **new** (§ 6) |
| `serverRssMb` per second | The server process's RSS (`monitoring/collect-system-metrics.mjs`, `rssMb`) | sample time | existing samples, **new**: per segment |
| `sockstatMem` per second | Kernel TCP memory pages (`/proc/net/sockstat` `mem`) in each namespace | sample time | **new** sampler |
| `clientLoopDelayP99`, `clientCpu` per segment | As in `METRICS.md`, the worst worker per segment | sample time | existing, **new**: per segment |

**`sendBufferedBytesMax`** samples NIO's buffer after writes. A value of 0 doesn't show that the socket's kernel buffer or the qdisc is empty; `sockstatMem` and the qdisc backlog cover those.

**Bands.** The P0 band of a per-window metric comes from the three P0 repeats of the same cell (same load point and population):

- For each repeat, the metric's per-window values over the baseline and impaired segments of P0, a quiet run, are pooled.
- The band's upper edge is the largest of the three repeats' p95, over windows, of that per-window value. The band is like for like: a window's p99 is compared with the P0 band of per-window p99s, and so on.
- The backlog metrics' bands are `sendUnwritableSessions = 0`, and `sendBufferedBytesMax` and `sockstatMem` at most their P0 band's upper edge.

**A window counts as healthy** for a group when all of these hold:

- joined connections equal the group's target;
- the achieved send rate is at least 95 % of target;
- at least 50 input-to-visible samples were sent in the window, at least 99 % of them `seen`, and the window's latency percentiles are within band;
- RTT is within band, and `unanswered` is 0;
- the update-gap p99 is within band.

A window that fails the sample minimum is *insufficient*. It neither passes nor fails, but it breaks a run of healthy windows.

**`recoveryMs`** for a group runs from the impairment's lift (the `tc qdisc change` time in the timeline) to the start of the first run of **5 consecutive healthy windows**, all inside the recovery segment. If no such run fits, the group has not recovered. It is reported per group and per repeat; the README gives the median and range over repeats.

**Per-session recovery** for an impaired session means: by the end of the recovery segment, it is open on its original connection or on a reconnect, it has a `firstSync` if it reconnected, and its last 10 s update-gap p99 is within band. Sessions that survived on their original connection and sessions rebuilt by a `firstSync` are counted separately.

## 6. Convergence after recovery

Rev 1 assumed ws-loadtest could compare states. It can't: it decodes frames but doesn't reconstruct a client state.

**Reconstruction.** Each connection keeps a client state through the TypeScript SDK's state view (`sdk/ts`, as `Tools/CLI` does). Reconstruction runs in every cell, P0 included, so its client cost is part of every measurement, and the client-bound check covers it.

**Quiescence and the check:**

1. At the end of the recovery segment, the driver tells every client instance to stop sending.
2. One coordinator (the driver), per land, with at most 20 lands checked concurrently, runs the `Tools/CLI` protocol (#79):
   - **freeze** through the admin route;
   - wait for the settle frames;
   - fetch the **projection** for each player;
   - have every client instance report each of its connections' reconstructed, normalised state for that land;
   - compare with `normalizeForConvergence` (shared with `Tools/CLI`, not copied).
3. An inconclusive room is retried once, as in `Tools/CLI` (#226).

**Coverage is every room and every expected connection.**

- A connection that is expected but absent (closed, not reconnected) is `missingClients`, and the room isn't converged.
- Zero rooms checked fails the run.
- The coordinator's time is budgeted: about 15 waves of 20 rooms at 300 rooms, at about 1–2 s per wave including the CLI's 200 ms quiet wait, so up to about 30 s; about 50 s at 500 rooms.

**Reconnects.** A reconnected connection is compared like any other, and reported in its own row. A `firstSync` rebuild converging shows that recovery works. It doesn't show continuity of the original connection's diff stream, which the survivors' row does.

## 7. What "pass" means

Disconnects are expected under outages and throttles, so the zero-disconnect bar doesn't apply by design. Instead:

- **Hard criteria** must hold. A failure is reported as a finding and the cell is marked failed, not tuned away.
- **Isolation criteria** apply to the healthy groups.
- **Everything else** is characterisation.

**Hard criteria, every cell:**

1. **No crash, no decode error.** No server crash or restart. No undecodable frame in any group.
2. **Every close has a cause.** Each server-initiated close the client saw is matched to exactly one server-side cause for that session:
   - **The server-side cause,** found by session in the server's warning log: backlog (4008, `sendBacklogCloses`), pong timeout (1001, `pongTimeoutCloses`), or another logged close. The session-to-player mapping is the join log line; the smoke checks that it carries both, and that runs log at warning level, which the rerun's `LOG_LEVEL=error` would hide. If the mapping isn't logged, adding it is a core change, made first.
   - **The client-side code** may be 4008, 1001 or 1006: a 4008 close frame queues behind the backlog it reacts to, and the channel closes at once, so a non-draining client usually sees 1006.
   - **Counter overlap:** `closeFrameTimeouts` is a mechanism counter that can overlap the causes, not a separate category. The counters are summed per cause, and a session counted under two causes is reported once, by its first cause.
   - **Pass:** every client close is matched, and every server cause has a client close or a still-open session.
3. **Every room converged.** `mismatched = 0` and `missingClients = 0` over every room, after the one retry for inconclusive rooms. A room still inconclusive is reported, and the cell is marked inconclusive, not passed.
4. **Every session recovered.** Every impaired session recovered, per session (§ 5), by the end of the recovery segment.
5. **Memory:**
   - **Per session:** `sendBufferedBytesMax` never exceeds 8 MiB plus one write. This tests the bound itself.
   - **Process:** by the end of the recovery segment, server RSS is back within P0's peak plus 10 % (or plus 64 MiB, if larger). Over the last 30 s of the recovery segment, it doesn't grow: the least-squares slope is at most P0's own slope over the same segment plus 1 MiB/s.
   - The peak during the impairment is reported, not bounded. The 8 MiB bound covers NIO's per-session outbound buffer, not the process's other allocations, kernel socket memory (`sockstatMem`, reported) or the qdisc.

**Hard criteria by profile:**

| Profile | Also required |
|---|---|
| P0, D50J10 (D50 and ASYM in the extension) | Zero server-initiated closes; `unanswered` = 0 outside the impaired segment |
| L1, GE (extension) | Zero server-initiated closes |
| L5, COMBO, RATE (BO45 in the extension) | Closes allowed only if matched to a bound (criterion 2) |
| BO10 (extension) | Zero server-initiated closes; `recoveryMs` finite for every group |
| BO75 | Every impaired session silent through the outage is closed by the pong timeout or the backlog bound, and reconnects with a `firstSync` |
| SR | Every slow reader reaches 4008 (server-side cause), and reconnects with a `firstSync` |

**Isolation criteria,** for M and SR (and S1 in the extension). These are predeclared; a failure is the finding.

- **Closes:** every healthy group has zero closes and zero unanswered actions.
- **Same-room and cross-room effect:** in the impaired segment, each healthy group's input-to-visible p99 and update-gap p99 stay within the P0 band of the same cell. The effect against P0 is reported with its range over the three repeats. Within the band, it is called "no detectable effect at this repeat count"; it is not called isolation proven.
- **Client-bound windows:** they don't count either way, and how many there were is reported.

**Characterisation, reported, not pass or fail:**

- latency growth compared with the added RTT;
- `recoveryMs` per group;
- the backlog counters per profile;
- the reconnect timings;
- the peak RSS and `sockstatMem`.

## 8. Run order and budgets

**Pinning, samplers and toolchain** are the same as the baseline rerun:

- server on CPUs 0–7 and client on 8–11, through the same `taskset` shims;
- the host CPU, commit-charge and memory samplers, and the transport profile;
- `swift:6.2.4-noble`, a release GameServer, and the client from the same SHA. Both SHAs are recorded before the smoke.

`ip netns exec` keeps `PATH`, so the shims apply. The smoke checks the affinity with `taskset -p` on the server and on one worker per client instance.

**Namespace bookkeeping:**

- **Listen counters** are per namespace: ListenOverflows and ListenDrops are read in the container namespace, where the server listens. They describe the namespace, not the server PID.
- **TIME_WAIT** is counted per namespace (container, `lt-client`, `lt-good`, `lt-router`), scoped to port 8080, with `ss -tan state time-wait '( sport = :8080 or dport = :8080 )'`. A run starts only when the total is at most 200.

**Planned matrix, at 300 rooms, 3 repeats each:**

| Block | Cells | Runs |
|---|---|---|
| U | P0, D50J10, L5, RATE, BO75 | 15 |
| M | P0, COMBO, BO75 | 9 |
| SR | SR (control: M's P0) | 3 |
| Total | | 27 |

**Order:**

- U, then M, then SR.
- Within a block, each repeat is one pass over the block's cells in a rotated order, starting with its P0. That way the P0 controls are spread through the sweep instead of all coming first.
- SR runs right after M, so M's P0 is a recent control for it.
- Bands and RATE values come from each block's own P0 runs.
- The sweep stops on any hard-criterion failure in a P0 run.

**Per run:**

| Step | Time |
|---|---|
| Ramp and warm-up | 15 s |
| Baseline | 30 s |
| Impaired segment | 60 s; 75 s for BO75; SR's calibrated pause |
| Recovery | 90 s |
| Quiescence and convergence | up to 30 s |
| Leave | 5 s |
| TIME_WAIT drain | 0–60 s |
| Server restart | 10 s |

That is about 5 min on average, and about 4.5 min for P0.

**Budgets, kept separate:**

| Stage | Estimate | Basis |
|---|---|---|
| Engineering (§ 9) | about 1.5–2 days of agent time. The trim removes cells, not tools: reconnect, shared rooms, reconstruction, the convergence coordinator, the exports, the slow reader and the analysis are all still needed | actual PR cadence |
| Host checklist (§ 10) | about 1 h of the measurement host's time, including the container recreate and the acceptance smoke | |
| Calibration (§ 1) | about 1–1.5 h. At 300 rooms: delay and jitter (D50J10, COMBO), loss (L5, COMBO), rate (RATE, COMBO, in U and in M), order (D50J10), and SR's time-to-unwritable | measured during the smoke, then fixed |
| Smoke | about 1 h: each new option on each entry path, at 10 rooms | |
| Sweep | 27 runs × about 5 min ≈ 2.5 h of host time | |
| Reruns | about 30 min (20 %) | |

The calibration and smoke durations are measured when they first run. If they differ from these estimates by more than half, the sweep budget is revised before it starts.

**Extension, documented but not planned:**

| Block | Cells | Runs (× 3) |
|---|---|---|
| U at 100 | all 12 profiles | 36 |
| U at 300 | D50, L1, GE, ASYM, COMBO, BO10, BO45 | 21 |
| U at 500 | P0, COMBO, RATE, BO75 | 12 |
| M at 300 | D50J10, L5, RATE, BO10 | 12 |
| S1 at 300 | P0, L5, BO75 | 9 |

That is about 90 more runs, or about 7.5 h. Each block is self-contained: it brings its own P0 where it needs one, except U at 300, which reuses the planned P0. Each block can be run later without changing the tooling.

## 9. What has to be built first

These changes are under `Examples/GameDemo/ws-loadtest`, `Tools/` and scripts. They land on `main` as direct changes, each smoked as in the prior lessons. Each gets a separate review of its measurement semantics, against this design's metric table, before the sweep. Being outside `Sources/` doesn't exempt them from review.

1. **External-server mode.** Today `run-ws-loadtest.sh` starts GameServer and checks `localhost:8080`. It needs a mode that leaves the server to the caller, started in the container namespace with the samplers on its PID, and checks the scenario's `serverUrl` instead.
2. **Impairment driver** (`scripts/impair.sh`).
   - It builds and tears down the namespaces, veths, forwarding and qdisc trees of § 1.
   - It applies and lifts profiles with `tc qdisc change` at the timeline's offsets.
   - It writes `impairment-timeline.json`: each change's command, wall-clock and monotonic time, and the before and after `tc -s` and `ethtool -k` output.
3. **Shared rooms:** explicit land-ID and slot lists, `--start-at`, and per-instance worker counts.
4. **Reconnect** (`--reconnect on-server-close`):
   - **Retry schedule:** after a server-initiated close, wait 1 s, then try one connect and join, with a 5 s timeout per attempt. Attempts are serial, never overlapping, and the next one is 1 s after the previous fails. Retrying is cancelled 30 s after the impairment's lift.
   - **Identity:** the join message doesn't carry the configured `playerId` today, and the server assigns the player. So a reconnect is a **new join to the same land**, not a resumption of the same player; resumption is out of scope (§ 11). The tool keeps the configured slot key as the client-side identity across the reconnect, so the analysis can follow a slot.
   - It records the timings of § 5.
5. **State reconstruction and the convergence coordinator** (§ 6): the per-connection SDK state view, a stop-sending command, the per-land freeze, settle and projection protocol across instances, and `normalizeForConvergence` shared with `Tools/CLI`.
6. **Exports and readers:**
   - the per-event and per-window raw samples of § 5, retained in the result set;
   - close aggregation by code and group;
   - the report reading `pongTimeoutCloses`;
   - the `sockstatMem` sampler per namespace.
7. **Slow reader** (`--slow-read`).
8. **The analysis** in `regenerate.py`: segments, bands, healthy windows, `recoveryMs`, per-session recovery, close reconciliation, the client-bound flag, and the pass tables of § 7.

**Server side.** Nothing here changes the server, unless the smoke shows one of these is missing:

- the session-to-player mapping in the log;
- a warning-level line for each close cause;
- usable rejoin behaviour.

Each such change is its own core PR, reviewed and merged before the sweep; the experiment doesn't run on an unmerged branch.

## 10. Measurement host checklist

This section is self-contained, so it can be handed to the measurement host as written.

**When:** after the host's current measurement runs have finished, and before anything in this topic runs.

**Who decides what:**

- **The host may do itself:** container-level changes. That covers recreating the measurement container with added capabilities, its AppArmor setting, apt packages, network namespaces, `tc` and namespace-local sysctls.
- **The maintainer decides:**
  - anything at the Windows level: `.wslconfig`, the WSL kernel, Windows services;
  - anything in the WSL distribution outside the container, such as loading a kernel module.

  If a step below needs one of these, stop and report; don't work around it.

**Why:** the experiment shapes traffic between the load client and GameServer with `tc netem`. It uses network namespaces inside the measurement container (§ 1). That needs kernel support for netem, a FIFO qdisc, veth and network namespaces, plus the `NET_ADMIN` and `SYS_ADMIN` capabilities in the container.

### Step 1: kernel support

Run this inside the current container. It shares the WSL kernel, so the check is valid there.

```bash
uname -r
ls /proc/config.gz && zcat /proc/config.gz | grep -E 'CONFIG_NET_SCH_NETEM|CONFIG_NET_SCH_FIFO|CONFIG_VETH|CONFIG_NET_NS|CONFIG_NET_SCH_TBF'
```

- **All `=y`:** continue.
- **Any `=m`:** the module has to be loaded in the WSL distribution, outside the container (`sudo modprobe sch_netem`, then `lsmod | grep sch_netem`), and kept across WSL restarts. That is the maintainer's step. Stop and report which options are `=m`.
- **Any missing, or no `/proc/config.gz`:** stop and report. This needs a custom kernel, a Windows-level decision, and this design stops there.

Report: `uname -r` and the grep output.

### Step 2: recreate the measurement container with the capabilities

Add these to the measurement container's run arguments (`.devcontainer/devcontainer.json` `runArgs`, or its `docker run`):

```
--cap-add=NET_ADMIN --cap-add=SYS_ADMIN
```

- **Recreate the container** for them to take effect, and keep the same image (`swift:6.2.4-noble`) and the same mounts.
- **Don't use `--privileged`.**
- **AppArmor:** if step 4 fails with a mount or permission error on `ip netns add` or `ip netns exec`, also add `--security-opt apparmor=unconfined`, to the measurement container only. Recreate it, and record that this was needed.

Inside the new container, check the capabilities:

```bash
grep CapEff /proc/self/status       # decode with: capsh --decode=<value>, if capsh is installed
```

Report: the run arguments used, and whether the AppArmor change was needed.

### Step 3: tools

```bash
sudo apt-get update && sudo apt-get install -y iproute2 ethtool iputils-ping iperf3 tcpdump
```

Report: `tc -V`, `ethtool --version`, `iperf3 --version | head -1`.

### Step 4: acceptance smoke

This builds the router topology of § 1, checks delay in both directions, the in-place change, the qdisc tree and the offloads, and tears it all down again.

```bash
set -e
sudo ip netns add lt-client
sudo ip netns add lt-router
sudo ip link add veth-c0 type veth peer name veth-c1
sudo ip link set veth-c0 netns lt-client
sudo ip link set veth-c1 netns lt-router
sudo ip link add veth-s0 type veth peer name veth-s1
sudo ip link set veth-s1 netns lt-router
sudo ip addr add 10.200.0.1/24 dev veth-s0
sudo ip link set veth-s0 up
sudo ip netns exec lt-router ip addr add 10.200.0.2/24 dev veth-s1
sudo ip netns exec lt-router ip addr add 10.201.0.1/24 dev veth-c1
sudo ip netns exec lt-router ip link set veth-s1 up
sudo ip netns exec lt-router ip link set veth-c1 up
sudo ip netns exec lt-router sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec lt-client ip addr add 10.201.0.2/24 dev veth-c0
sudo ip netns exec lt-client ip link set veth-c0 up
sudo ip netns exec lt-client ip link set lo up
sudo ip netns exec lt-client ip route add default via 10.201.0.1
sudo ip route add 10.201.0.0/24 via 10.200.0.2
sudo ethtool -K veth-s0 tso off gso off gro off
sudo ip netns exec lt-router ethtool -K veth-s1 tso off gso off gro off
sudo ip netns exec lt-router ethtool -K veth-c1 tso off gso off gro off
sudo ip netns exec lt-client ethtool -K veth-c0 tso off gso off gro off
sudo ip netns exec lt-router tc qdisc add dev veth-c1 root handle 1: netem delay 50ms limit 10000
sudo ip netns exec lt-router tc qdisc add dev veth-c1 parent 1:1 pfifo limit 10000
sudo ip netns exec lt-router tc qdisc add dev veth-s1 root handle 1: netem delay 50ms limit 10000
sudo ip netns exec lt-router tc qdisc add dev veth-s1 parent 1:1 pfifo limit 10000
sudo ip netns exec lt-client ping -c 20 10.200.0.1                                   # A: expect about 100 ms
sudo ip netns exec lt-router tc qdisc change dev veth-c1 root handle 1: netem delay 0ms limit 10000
sudo ip netns exec lt-client ping -c 20 10.200.0.1                                   # B: expect about 50 ms
sudo ip netns exec lt-router tc -s qdisc show dev veth-c1                            # C: netem 1: with pfifo child
sudo ip netns exec lt-client ethtool -k veth-c0 | grep -E 'tcp-segmentation-offload|generic-(segmentation|receive)-offload'   # D: all off
nproc; taskset -p $$                                                                  # E: CPU visibility for the pinning shims
# teardown
sudo ip route del 10.201.0.0/24 via 10.200.0.2
sudo ip netns del lt-client
sudo ip netns del lt-router
ip link show | grep -c veth || true                                                   # F: expect 0
```

**Pass:**

- A: median about 100 ms (± 3 ms);
- B: median about 50 ms;
- C: shows `netem 1:` with a `pfifo` child;
- D: all three offloads off;
- E: shows the 12 logical CPUs the pinning shims expect;
- F: 0, so nothing is left after teardown.

**Failures:**

- **`Specified qdisc kind is unknown`:** step 1 is incomplete.
- **A mount or permission error on `ip netns`:** step 2's AppArmor note applies.
- **Anything else:** stop and report the output.

**Report:** the full output of step 4, `swift --version`, and `node --version`.

**After this checklist.** Recreating the container is a host change: no number from this topic is compared directly with the earlier multi-room runs, and P0 here is the reference. Record the date of the recreate in the host notes, so the baseline is re-established. The checklist doesn't change any Windows-level setting.

## 11. Not varied (README § Caveats)

**Fixed:**

- the encoding: messagepack;
- the scenario and its action rate: Hero Defense, 1/s;
- 5 players per room;
- the server's bounds, at their defaults: backlog 8 MiB / 30 s, ping 30 s, pong 20 s;
- the in-turn sync mode, as the rerun ran it;
- one host, with the server and the clients on separate pinned CPUs;
- one load point, 300 rooms, in the planned runs.

**Not covered by the planned runs:** the extension of § 8 (100 and 500 rooms, D50, L1, GE, ASYM, BO10, BO45, S1).

**Not covered at all:**

- real WAN paths and measured traces;
- per-client independent netem links: per-client conditions are covered only by the slow reader;
- session resumption by the same player;
- other kernels' TCP stacks;
- clients on separate machines.

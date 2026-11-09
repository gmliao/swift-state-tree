# Network impairment experiment: design

Status: **design rev 5.4, design check GO.** Engineering starts after it; nothing runs before the host checklist in § 10 has passed.

Revisions:

- **Rev 5.4** follows the calibration (§ 1):
  - In a rate cell the rate is below the offered load, so the queue fills to its limit by construction. There, the check is the peak queueing delay against the nominal 500 ms, and the tail drops are a result. "Below the limit" stays for the cells without a rate.
  - COMBO's rate queue adds its own delay to the ping, so its delay and jitter are calibrated in an extra cell, COMBO's netem parameters without the rate (COMBO-norate), at the same load point and population. COMBO itself is calibrated on its rate and queueing delay.
- **Rev 5.3** answers the design check of rev 5.2:
  - The profile's close counters are a sanity check on the lifecycle log, not its equal: each must be at least the log's count of its causes, and the excess is reported (§ 7).
  - `error` is a server decision and needs a client close, as in the analysis.
  - `reorderedPct` is measured per load point and per population, and D50J10 isn't read as jitter alone (§ 7).
  - The join sample's `serverPlayer` is a required client change (§ 9), checked in the smoke.
  - A missing input fails the criterion that needs it; nothing is skipped or read as 0 (§ 7).
- **Rev 5.2:**
  - Criterion 2 reads each session's server-side cause from the lifecycle log's `sessionJoined` and `sessionClosed` lines (#265), not from warning logs. A client close is paired with its session through the join sample's `serverPlayer`.
  - On the measurement host the acceptance smoke's step E found out-of-order replies, so the pfifo child doesn't keep order with jitter. D50J10 and COMBO therefore run as jitter with reordering (§ 1): they are labelled so in the tables, and the calibration capture reports the reordering rate rather than gating on it.
- **Rev 5.1:** `sockstatMem` is host-wide and covers both ends, so the per-namespace socket memory is the `ss` queue sums (`socketQueues`, § 5), including closing sockets that still hold a backlog.
- **Rev 5:**
  - the upstream `priomap` sends unclassified traffic, ARP included, to the unshaped band, and the smoke flushes the neighbour caches during the outage check;
  - the stale check is suspended while a slow reader is paused;
  - stale closes are judged per profile;
  - rate cells record the measured queueing delay.
- **Rev 4** answers the design check of rev 3:
  - M's upstream is split by source, so healthy clients are never shaped;
  - a client-side stale-connection check, so a reconnect isn't gated by the old socket's TCP backoff;
  - land re-creation in U-BO75, stated and recorded;
  - a per-session recovery band with the same statistic, and a null check on P0;
  - netem's shared drop counter, backlog sampling, and a rate-cell queue limit;
  - a fallback for jitter reordering, tested in the acceptance smoke;
  - a false-positive control on P0, and segment-level isolation;
  - RSS leak check hard and the return to baseline characterisation;
  - half-open sessions, and the slow reader's pause from the maximum pause → 4010 (sync-lag tracking, #332);
  - checklist fixes: a teardown trap, avg instead of median, and the new kernel options.
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

- **`Notes/solutions/2026-11-05-load-tool-is-the-bottleneck.md`.** Extra latency makes the client hold more pending requests and timers. Each run records the worst worker's loop-delay p99 over the run and the client's CPU, as before. Per 1 s window, each worker records its event-loop utilization (ELU, the share of the span its loop was busy) over spans of about 1 s, read on the CPU sampler's existing tick, so no timer is added and the loop-delay histogram is untouched. A window that a worker's span with ELU above 0.9 overlaps is *client-bound*, and its latency isn't read as the server's. The 0.9 gate leaves over 4× headroom above the throughput sweep's highest point that wasn't client-bound (about 233 % client CPU over 12 workers, about 0.2 of a core per worker); below it a loop still has idle time each second. It doesn't see a single long block in an otherwise idle second, which the per-window send-lag p99 (`sentAt − intendedAt`) reports beside it. The first sweep validates the gate: a run whose run-wide loop-delay p99 is over 20 ms with no client-bound window means the gate is set too high, and the table flags it; each worker's largest span ELU is reported, below the gate too.
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
- **Upstream** (client → server) is shaped on `veth-s1`'s egress, inside `lt-router`. That egress carries every client namespace's upstream, so it is split by source (below), and only `lt-client`'s traffic reaches the netem.
- Neither TCP endpoint's own egress carries a netem qdisc. That avoids the distortion the netem man page warns about when a qdisc sits on the sending TCP endpoint (TCP Small Queues).
- `lt-router` forwards with `net.ipv4.ip_forward=1`, a sysctl local to its namespace.
- The load client connects to `ws://10.200.0.1:8080/game/hero-defense`. The scenario's `serverUrl` already takes this.
- Population M (§ 4) adds a second client namespace, `lt-good` (10.202.0.0/24), attached to `lt-router` through its own veth pair `veth-g0` / `veth-g1`. Its downstream qdisc on `veth-g1` stays at P0, and its upstream takes the unshaped band on `veth-s1`.

**Offloads.** TSO, GSO and GRO are off on every veth end, with MTU 1500, so netem sees wire-sized packets. The smoke checks the effective state with `ethtool -k`, and doesn't rely on the commands' exit codes.

**The qdisc trees** are attached once, before the run, and stay for the whole run.

- **Downstream (`veth-c1`, and `veth-g1` in M):**
  - root: `netem` with an explicit `limit` (see below);
  - child: a `pfifo` with its own explicit limit. With jitter, this is the FIFO composition the netem man page gives for jitter without reordering. Whether it keeps packets in order on this kernel is checked in the acceptance smoke (§ 10, step 4), before engineering depends on it.
- **Upstream (`veth-s1`):**
  - root: a 2-band `prio` with every priority mapped to band 1 (`priomap` all 0), so unclassified traffic, including ARP and the router's own packets, is never shaped;
  - band 1 (`1:1`): a `pfifo` for everything except `lt-client`'s upstream, so `lt-good`'s upstream and the router's neighbour discovery are never shaped;
  - band 2 (`1:2`): the `netem` and its `pfifo` child, for `lt-client`'s upstream only;
  - a `u32` filter that sends source 10.201.0.0/24 to `1:2`, and one that sends 10.202.0.0/24 to `1:1` explicitly.

  Strict priority between the bands doesn't matter here, because the upstream has no rate limit: the veth is never the bottleneck. The acceptance smoke checks the split: with 100 % loss on `1:2`, a ping from `lt-good` must still answer, also after the neighbour caches of the router and the container namespace have been flushed, so ARP must pass during an outage.
- **The same trees are used in every cell.** In U, `lt-good` isn't created, and its band stays empty.
- **If the pfifo child doesn't keep order** on this kernel, D50J10 and COMBO run as **jitter with reordering**. They are relabelled so in the tables, and the measured reordering rate is reported. No other in-order mechanism is substituted without a design revision.

**Profile changes happen in place.** A profile is applied and lifted with `tc qdisc change`, never `del` or `replace`, so queued packets and counters survive the boundary.

- Lifting means changing back to P0's parameters. Packets already delayed still drain with their old delay; the timeline records the change time, and recovery is measured from it.
- An outage (100 % loss) drops at enqueue, so nothing is queued behind it.

**Queue limits.** netem's default limit is 1000 packets. At 1500 connections with 50 ms of delay, it can overflow and add loss that no profile asked for. Each shaped interface instead gets:

```
limit = max(10000, 4 × packets per second × (delay + 4 × jitter) in seconds)
```

- **The packet rate** is P0's measured peak per-second packet rate on that interface.
- **Drop counting.** netem counts its loss drops and its queue-overflow drops in one `dropped` counter; only the pfifo child's drops are counted apart. The acceptance smoke confirms this on the host's kernel. Therefore:
  - in delay-only and jitter cells, netem's `dropped` must stay 0, and a run with any drop is invalid and rerun with a larger limit;
  - in every cell without a rate, netem's `backlog`, sampled once per second, must stay below its limit, so overflow can't be mistaken for loss;
  - in a rate cell (RATE, COMBO) the rate is below the offered load, so the queue fills to its limit by construction and tail-drops the excess. There, the peak of netem's `backlog` bytes ÷ rate (the queueing delay) must stay at most the nominal 500 ms, and the tail-drop share (drops over offered packets) is reported as a result of the impairment, not as a failure;
  - loss is calibrated only in a cell without a rate (L5);
  - COMBO's drops are reported as combined: loss plus any overflow.
- **RATE and COMBO's rate.** When the rate shapes, the queue in front of it, the limit × packet size ÷ rate, sets the added latency and how soon backlogs build. So a rate cell's limit is set for a stated maximum queueing delay of 500 ms instead: `limit = max(100, rate in bytes/s × 0.5 ÷ 1500)`. The limit is in packets, so the 500 ms holds only for full-size packets; with ACKs and small frames the real bound is lower. The cell's config records the limit, that nominal maximum delay, and the measured peak of netem's `backlog` bytes ÷ rate, which is the actual queueing delay.
- **BO75 and SR keep P0's limits** (10000 each way): BO75's blackout drops every packet, so its queue can't fill, and SR is a client-side slow read with its namespace at P0, so nothing is shaped.
- **Fairness.** 1500 flows share one pfifo, unfairly: which flows reach the backlog bound first tells which flows lost the shared queue, not which clients were slowest. The per-client case is SR.

**Rejected alternatives:**

- **netem on each TCP endpoint's egress** (rev 1): the TCP Small Queues confound above.
- **Receiver ingress through IFB:** equivalent to the router for this purpose, and it also separates upstream by source. It needs the `ifb` module and the `mirred` action as well, and it is harder to check by eye. The prio-and-u32 split does the same with fewer kernel options.
- **Filtered `lo`:** it shares the loopback's segment sizes and puts the client's and the server's sockets in one namespace.
- **Two containers on a Docker bridge:** a valid option. It changes the container layout relative to the baseline, which a forwarding namespace inside one container doesn't.

**What the topology itself changes.** Even with zero impairment, traffic crosses three veth hops and a forwarding namespace instead of `lo`. The control profile P0 measures that cost on the same topology. No number is compared directly with the localhost rerun.

### Verifying the impairment

**Pre-sweep calibration**, once per profile and load point, under load:

- **Delay:** 600 pings at 0.1 s intervals (`ping -i 0.1 -c 600`) from `lt-client` to the server, during a load run of the cell, and the same during a P0 run, with the RTTs parsed per reply.
  - The **added median** (the cell's median minus P0's median) must be within ±2 ms of the configured added RTT. For D50J10 that is 100 ms.
  - The **added p10–p90 spread** (the cell's minus P0's) is reported next to the spread the netem distribution predicts for the configured jitter, both directions combined; the distribution table is the one netem uses by default, stated in the calibration notes.
  - **A cell with a rate** isn't delay-calibrated itself: its rate queue adds up to the queueing delay to every ping, and drops pings with the rest of the tail. COMBO's delay and jitter are calibrated in **COMBO-norate** (`impair.sh` profile `COMBO_NORATE`), COMBO's netem parameters without the rate, at the same load point and population: its added median must be within ±2 ms of COMBO's configured 80 ms, and netem must not overflow. Its `reorderedPct` is not COMBO's, since the rate queue changes what netem holds; COMBO's own capture gives COMBO's.
- **Loss:**
  - The netem loss-drop delta over *offered* packets (sent + dropped) must be within ±0.2 points of the configured rate. It is measured over at least 200,000 offered packets, which puts a 1 % rate's 95 % binomial interval at about ±0.04 points.
  - The burst-loss profile is checked against its model's mean loss rate.
- **Rate:**
  - The qdisc's dequeued bytes per second (`tc -s`, including headers, ACKs and retransmissions) must be within ±5 % of the configured rate during the throttle window.
  - The peak queueing delay (netem's `backlog` bytes ÷ rate) must be at most the nominal 500 ms; the tail-drop share is reported next to it.
  - Application payload bytes per second are reported next to it, from the client report.
  - Every load point and population with a RATE cell is calibrated separately.
- **Order:** the acceptance smoke checks ICMP order through the trees before engineering starts (§ 10). Then, for 10 s of each jitter cell (D50J10, COMBO) under load, at each load point and population it runs in, a capture (`tcpdump -w`, receiving side of each direction, in the router namespace) is checked for TCP sequence numbers that decrease within a flow, excluding retransmissions.
  - **In order** (the smoke's step E found none): both directions must show none.
  - **Jitter with reordering** (step E found some): the same capture measures the reordering instead, as the share of data segments out of order in each direction. It is recorded as the cell's `reorderedPct` and reported, not gated. The run records `jitterReorders`. How many packets netem holds at once, and so how often they pass each other, grows with the packet rate, so `reorderedPct` is measured per load point and per population, never carried over from another.
- **Extension blocks** (§ 8) run at load points and populations the planned matrix doesn't, so each brings its own calibration of the checks above for its cells.

**Per run**, before and after each boundary:

- `tc -s qdisc show` on every shaped interface, and netem's `backlog` once per second during the run;
- `ethtool -k` on every veth end;
- `ss -tn` in each client namespace at steady-state start, which must show every load connection to `10.200.0.1:8080`.

All of these go into the run's provenance; a run with a failed check is invalid.

## 2. Load points

**Client settings:** the rerun's defaults, which are `--layout rooms`, 5 players per room, `--send spread`, `--connect ramp` at 1000/s, 12 workers, 1 action per player per second, and Hero Defense. Plus `--input-latency on --move-to-rate 1`, so input-to-visible has samples, and `--input-latency-min-seen 0`: the client's one phase holds the impairment, so the seen-share gate is the analysis's, on the baseline (§ 7).

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
  - **BO75:** must close every impaired session that stays silent. It is the guaranteed server-side activation cell.
- **The client side of an outage.**
  - **The client's TCP backoff.** Neither end gets a packet through after the lift until its next retransmission timeout fires, and those timeouts have doubled since the outage began. With a 200 ms base, retransmits fall at about 0.2, 0.6, 1.4 … 51 s, then 102 s. After a 75 s outage, the old connection's first packet after the lift can come anywhere from about 0 to 50 s later. The server's close frame and FIN wait behind the same backoff.
  - **A client-side liveness check.** So that recovery doesn't measure that backoff, every client runs a **stale-connection check**, `--stale-after 10s`, a new option: a connection with no frame from the server for 10 s is abandoned by the client and reconnected. The server sends a sync every 100 ms, so in a healthy cell it never fires, which P0 verifies. Its close is client-initiated, and is recorded with its detection time.
  - **Suspended while a slow reader is paused.** A slow reader sees no frames while its reading is paused, by design. Its stale check is suspended for the pause and restarts its timer when reading resumes. Otherwise it would abandon the socket 10 s into the pause, before the 4010, and SR would lose its guaranteed activation. The SR smoke (10 rooms, pause 25 s, `srsmoke.py`) asserts that every slow reader gets one resync, then a server-side 4010, and none a stale close.
  - **The reconnect.** A reconnect uses a new socket, whose connection attempts aren't gated by the old socket's backoff. Its retries run until 60 s after the lift (§ 9).
  - **What `downtimeMs` contains** for each reconnect: the detection (the stale check or a close), the failed attempts during the outage, and the reconnect after the lift. The parts are recorded separately. An `ss -ti` snapshot of each impaired socket's RTO and backoff at the lift backs the attribution.
- **Land lifetime.** Hero Defense destroys an empty land 5 s after it empties (`DestroyWhenEmpty(after: .seconds(5))`).
  - **In U-BO75,** every session of every room is closed 20–50 s into the outage: by the pong timeout on the server, and by the stale check on the client. So every land empties and is destroyed before the lift. The reconnects join a **recreated land** with fresh state, or get a retryable denial while the old one drains and then retry. U-BO75 therefore measures re-creation and rejoin, not the recovery of an existing room, and its tables say so.
  - **In M-BO75,** the mixed rooms keep their four healthy players, so their lands survive. That cell measures rejoin into a surviving room.
  - Each land's instance identity or creation time is recorded (§ 9), so the analysis tells a recreated land from a surviving one.
- **Backlog bound.** The 30 s unwritable timer starts only when the channel becomes unwritable (above the 64 KiB high watermark, after the kernel's socket buffers have filled), and it resets when the channel is writable again. It isn't an outage timer.
  - RATE and COMBO are characterisation: how many sessions became unwritable, for how long, and how many reached 4008.
  - **Sync-lag tracking (#332) closes the slow reader first.** It keeps sending, so its inbound frames keep cancelling the pong deadline. Its acks (every 1 s, unchanged while paused) stop advancing, so 3 s into the pause the server sends it a resync, and 10 s later, the ack timeout, closes it with 4010 (slow consumer): about 13–14.5 s, well before the backlog's 30 s unwritable timer. So SR's guaranteed activation is the 4010, and a 4008 is reported if seen. A slow reader that sent no acks while paused is closed by 4011 (unresponsive) instead, and SR's criterion fails it as a missing precondition. Its pause is calibrated to exceed the maximum pause → 4010 plus 10 s.

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
| S1 | One impaired client in one room; everyone else healthy | The single bad client. **Extension, not planned.** A group of one client can't reach the 50-sample window minimum, so its recovery is judged per session only |
| SR | Like M, but the impaired players are slow readers (below) rather than netem-shaped. Their namespace stays at P0, so SR's control is M's P0: the same topology, rooms and instances | Per-client backlog with independent clients, and guaranteed 4008 activation |

**Slow reader** (`--slow-read <start>:<duration>`, a new client option): the client stops reading its socket for the duration (`pause()` on the underlying TCP socket) and keeps sending its actions on schedule. The duration is the **maximum** pause → 4010 over the slow-reader sessions of a calibration run at 300 rooms, in population SR (`SR-CAL`), plus 10 s (`srpause.py`, which refuses a calibration where a slow reader closed otherwise, got other than one resync or sent no acks while paused). It is not the mean, and not a 10-room smoke. At the end, the client resumes reading, or finds itself closed.

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

**Sync-lag tracking (#332).** The client records each resync it receives (`resync`, with its arrival time) and tags each full update `firstSync` or `resync`. Its close records carry the connection's `resyncs`, `acksSent`, `acksSentWhilePaused`, `lastAckedSeq` and `lastReceivedSeq`, counted per connection. The transport profile carries, per window and summed per land, `syncLagResyncs`, `syncLagResyncsAlongside`, `syncLagPendingMarks`, `syncLagKeyScopeResets`, `syncLagKeyScopeResetBytes`, `syncLagDroppedEvents`, `syncLagSlowConsumerCloses`, `syncLagUnresponsiveCloses` and `syncLagDroppedAcks`. The lifecycle log records a sync-lag close as `serverClose` with its code, and the analysis splits it by code: 4010 slow consumer, 4011 unresponsive. The clients' resyncs must equal `syncLagResyncs` plus `syncLagResyncsAlongside`, and the log's 4010 and 4011 counts the two close counters; key-scope reset bytes are reported land-wide.

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
| `sockstatMem` per second | Kernel TCP buffer memory, pages (`/proc/net/sockstat` TCP `mem`), with the orphaned socket count. **Host-wide**: the kernel counts them once for all namespaces, so they are sampled once per second. They cover the load client's sockets as well as the server's, so they aren't a server-only figure | sample time | **new** sampler (`sockstat-main.js`), pinned to the client CPUs (8–11) like the other samplers |
| `socketQueues` per second, per namespace | Over a namespace's non-listening TCP sockets (`ss -tnH exclude listening`), the count and the summed and largest `Recv-Q` (received, not read by the application) and `Send-Q` (sent, not acknowledged), for the established sockets and separately for each other state; with `/proc/net/sockstat`'s per-namespace `inuse` and `tw`. A server close with data still queued (4008, a pong timeout) leaves its socket in `FIN-WAIT-1` or `LAST-ACK`, and that Send-Q is the backlog draining | sample time | **new**, same sampler |
| `clientLoopDelayP99`, `clientCpu` per segment | As in `METRICS.md`, the worst worker per segment | sample time | existing, **new**: per segment |

**`sendBufferedBytesMax`** samples NIO's buffer after writes. A value of 0 doesn't show that the socket's kernel buffer or the qdisc is empty; the server namespace's `Send-Q` (`socketQueues`), `sockstatMem` and the qdisc backlog cover those.

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

**False-positive control.** The healthy-window test and `recoveryMs` are also run on every P0 repeat, against leave-one-out bands built from the other two repeats. That gives how often a quiet run fails them; the README reports it next to every impaired cell's result. With a p95 band, some P0 windows exceed it by construction. That is why recovery needs 5 consecutive windows, and why isolation (§ 7) is judged on segments, not on single windows.

**`recoveryMs`** for a group runs from the impairment's lift (the `tc qdisc change` time in the timeline) to the start of the first run of **5 consecutive healthy windows**, all inside the recovery segment. If no such run fits, the group has not recovered. It is reported per group and per repeat; the README gives the median and range over repeats.

**Per-session recovery** for an impaired session means, by the end of the recovery segment:

- it is open on its original connection or on a reconnect;
- it has a `firstSync`, if it reconnected;
- its last 10 s update-gap p99 is within the **per-session band**.

Sessions that survived on their original connection and sessions rebuilt by a `firstSync` are counted separately.

- **The per-session band** uses the same statistic: one session's update-gap p99 over a 10 s window. From the P0 repeats of the same cell, that statistic is computed for every session and every 10 s window of the quiet segments. The band's upper edge is the maximum over them.
- **Null check:** P0 itself must pass the per-session criterion, with each repeat tested against a band built from the other two (leave-one-out). If it doesn't, the criterion is too tight and is revised before the sweep is read.

**Revised 2026-11-09 (core round, step 6): each session against its own baseline.** This replaces the per-session band above. A session has recovered when all of these hold:
- its state converged: its land, or its own connection, in the convergence check (§ 6);
- over the last 10 s of the recovery segment, it is joined and receives an update in every 1 s slot. A reconnect still needs a `firstSync`;
- its update-gap p99 over those 10 s is at most its own baseline gap p99 plus one sync interval (100 ms).

A session without baseline gaps fails. P0 is checked the same way, as the control, and no repeat needs another, so the leave-one-out null check is gone.

The criterion was tried on the held 2026-11-08 data before the change:
- after the lift, every session of every cell recovered;
- over the last 10 s of the impaired segment instead, L5, RATE, the BO75 impaired groups, part of COMBO and the paused SR-CAL readers failed, and P0 passed.

It doesn't see a constant delay (D50J10): that shifts every arrival alike. Delay shows in the latency metrics.

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

**How the driver reaches the instances:** each client instance serves a control channel on a Unix socket (`--control-socket`). A pathname Unix socket is reachable from every network namespace on the host, since they share the filesystem, so the driver's traffic never crosses the shaped path. The tool's own decode stays for the metrics and the SDK decodes each frame again for the view; the formal smoke measures that cost with a 300-room P0 pair, reconstruction on and off.

**Coverage is every room and every expected connection.**

- A connection that is expected but absent (closed, not reconnected) is `missingClients`, and the room isn't converged.
- Zero rooms checked fails the run.
- **The roster is the run's, not the driver's.** The report lists each instance's connections per room, and the analysis compares that with `params.convergenceRoster`: a client instance left out of the check, or a room short of connections, fails criterion 3 even when every room it saw converged.
- The coordinator's time is budgeted: about 15 waves of 20 rooms at 300 rooms, at about 0.3–1 s per wave in the common case (the 200 ms quiet wait), so well under the 45 s tail. The worst case, every room differing to the 5 s cap of § 7, is about 15 × 5.3 s ≈ 80 s, more than the tail. So the driver gets a deadline (`--deadline-s 35`): it starts no room check after 35 s, the last one ends by about 41 s, before the tail's end closes the connections, and the rooms left are errors. A run that slow fails criterion 3 visibly instead of comparing closed connections: its row shows the rooms checked before the deadline and the pass's wall time, and such a cell is rerun with a longer tail.

**Reconnects.** A reconnected connection is compared like any other, and reported in its own row. A `firstSync` rebuild converging shows that recovery works. It doesn't show continuity of the original connection's diff stream, which the survivors' row does.

## 7. What "pass" means

Disconnects are expected under outages and throttles, so the zero-disconnect bar doesn't apply by design. Instead:

- **Hard criteria** must hold. A failure is reported as a finding and the cell is marked failed, not tuned away.
- **Isolation criteria** apply to the healthy groups.
- **Everything else** is characterisation.

**Hard criteria, every cell:**

1. **No crash, no decode error.** No server crash or restart. No undecodable frame in any group.
2. **Every close has a cause.** Each server-initiated close the client saw is matched to exactly one server-side cause for that session:
   - **The server-side cause** comes from the lifecycle log (`LAND_LIFECYCLE_LOG_PATH`), which works at the runs' `LOG_LEVEL=error`. No warning-level logging is needed, which would change the measured config and log heavily on the paths being measured.
     - The session's `sessionClosed` line gives the cause: `backlogBytes` or `backlogUnwritable` (4008), `pongTimeout` (1001), `clientClose`, `serverClose` or `connectionLost`. A `serverClose` with code 4010 is a slow-consumer close and with 4011 an unresponsive one (sync-lag tracking, § 5).
     - The `sessionJoined` line, paired by `sessionID`, maps the session to its player, land and instance. The pairing ignores order: a close decided on the event loop can be logged before a join read ahead of it completes in its land. A session's close applies to every `sessionJoined` with its `sessionID`, which is unique per connection.
     - The `clientClose` and `connectionLost` causes are server-side observations, not server decisions: they match client closes the client or the network caused. `error` is a server decision, since the server closes the connection on it, so it needs a client close like the others.
     - **The counters are a sanity check, not the comparison.** The comparison is per cause, from the log. The profile's `pongTimeoutCloses` must be at least the log's `pongTimeout` count, and `sendBacklogCloses` at least its `backlogBytes` plus `backlogUnwritable`; the excess is reported. They can't be equal in general: a backlog breach after a pong close was decided still counts, the counters count sessions that never joined, and a profile window and a close can fall on different sides of a segment edge.
     - **The join sample maps each client connection to its session**, by `serverPlayer` and land. A join without `serverPlayer`, or one that maps to no `sessionJoined`, fails the criterion. A server-decided close no client close matched is found over the whole log within the run, not only among mapped sessions.
   - **The client-side code** may be 4008, 1001 or 1006: a 4008 close frame queues behind the backlog it reacts to, and the channel closes at once, so a non-draining client usually sees 1006.
   - **Counter overlap:** `closeFrameTimeouts` is a mechanism counter that can overlap the causes, not a separate category. The counters are summed per cause, and a session counted under two causes is reported once, by its first cause.
   - **Pass:** every client close is matched, and every server cause has a client close or a still-open session.
   - **Still open** is judged from both sides at the end of the recovery segment. The server reports the session as connected (admin session list, or no close or leave line for it), and the client has the connection open and receiving frames. A session open on only one side, half-open, fails criterion 2.
   - **The client's own stale-check closes** (§ 3) are client-initiated, and are listed separately. What they must match depends on the profile:

     | Profile | A stale close |
     |---|---|
     | P0, D50J10 | is a failure: with frames every 100 ms, it should never fire |
     | BO75 | must match a server-side pong-timeout, backlog or 4011 cause for the same session, by the end of the recovery segment |
     | L5, RATE, COMBO | is its own reported category, characterisation. A flow starved in the shared queue, or in retransmission backoff for over 10 s, can trigger it while the upstream still works, so the server logs an ordinary client disconnect |
     | SR | is a failure for a slow reader, since its check is suspended (§ 3), and is reported for everyone else |
3. **Every room converged.** `mismatched = 0` and `missingClients = 0` over every room, after the one retry for inconclusive rooms. A room still inconclusive is reported, and the cell is marked inconclusive, not passed.
   - **A difference is final only at the cap, 5 s after the freeze.** The quiet window (200 ms with no frame) isn't proof that the last frame arrived: Linux's minimum TCP retransmission timeout is 200 ms, and with the impairments' delay and jitter a tail loss waits about 300–400 ms for its tail-loss probe or retransmit. 5 s covers one retransmit and one backoff under COMBO's delay. The room stays frozen and its projections fixed, and a differing connection's state is read again until it matches or the cap passes.
   - A difference that went away is **converged late**: reported in its own column with its delay per room and connection, not a fail. Only a difference that lasts to the cap is `mismatched`.
   - A resume that fails twice is an error: a room left frozen stops its game for the rest of the run.
4. **Every session recovered.** Every impaired session recovered, per session (§ 5), by the end of the recovery segment.
5. **Memory:**
   - **Per session:** `sendBufferedBytesMax` never exceeds 8 MiB plus one write. This tests the bound itself.
   - **Process, leak check (hard):** over the last 30 s of the recovery segment, server RSS doesn't grow: its least-squares slope is at most P0's own slope over the same segment plus 1 MiB/s.
   - **Process, return to baseline (characterisation):** how far RSS is above P0's peak at the end of recovery. glibc keeps freed arenas, and RATE can grow the backlogs by gigabytes, so RSS staying high isn't a leak by itself.
   - The peak during the impairment is reported, not bounded. The 8 MiB bound covers NIO's per-session outbound buffer, not the process's other allocations, kernel socket memory (`sockstatMem`, reported) or the qdisc.

**Hard criteria by profile:**

With jitter with reordering (§ 1), D50J10 and COMBO keep the criteria below. TCP restores order, so reordering is expected and isn't a failure on its own. The added retransmissions and delay show in the latency, closes and recovery that are judged here.

| Profile | Also required |
|---|---|
| P0 | Zero server-initiated closes; `unanswered` = 0 outside the impaired segment; no resync, and no 4008, 4010 or 4011 |
| D50J10 (D50 and ASYM in the extension) | Zero server-initiated closes; `unanswered` = 0 outside the impaired segment. A resync is a finding, not a fail |
| L1, GE (extension) | Zero server-initiated closes |
| L5 (BO45 in the extension) | Closes allowed only if matched to a bound (criterion 2). A resync is a finding, not a fail |
| RATE, COMBO | Closes allowed only if matched to a bound (criterion 2). Both throttle below P0's demand by design: in the impaired window, resyncs, apply → first resync, 4010 closes and rejoins are reported per session and never fail, and a 4011 is a finding, reported with the client's CPU, as is a 4008 with its count and times. Recovery: over the last 10 s, no resync, 4010, 4011 or rejoin, and every target session joined and converged at the end (no resync in 10 s bounds each session's server-side lag at 3 s). Each session's last frame within 1.1 s of the end is reported. A recovery shorter than the last 4010 → rejoin → firstSync → 10 s quiet is inconclusive, not failed. A rate cell whose calibration the sync-lag frames make stale (over 20 % added downstream, at 90 B/s per shaped connection) is refused before it runs |
| BO10 (extension) | Zero server-initiated closes; `recoveryMs` finite for every group |
| BO75 | Every impaired session silent through the outage is closed inside the outage by the pong timeout, the backlog bound or 4011 on the server side, the client's own close isn't 4011, and it reconnects with a `firstSync` within 60 s of the lift. In U, the rejoin is into a recreated land (§ 3), reported as such. In M, the mixed rooms' lands must survive, and the rejoin is into the surviving land |
| SR | Every slow reader sent acks while paused (the precondition), gets exactly one resync, then reaches 4010 (server-side cause, about 13–14.5 s into the pause), and reconnects with a `firstSync`. The healthy sessions get no resync and no server close. A 4008 is reported if seen |

**Missing inputs fail.** A hard criterion whose input is missing fails as "fail (missing: ...)", naming the input: the lifecycle log, a transport profile covering under 95 % of the run's 1 s windows, a group's worker files, a group whose distinct joins fall short of its target, a missing or zero send target. A per-session check without its P0 control fails as "fail (no control)". Nothing is skipped, shown as "–" or read as 0. SR's control is M's P0 (§ 4).

**Windows and bounds.**
- Each segment's 1 s windows start at that segment's own start, the recovery's at the lift, and a segment's last partial window is dropped. No window straddles the apply or the lift.
- An action counts in `sendsAchieved` by its actual send time (`sentAt`), and in the RTT, unanswered and late counts by its intended time, the RTT's origin (§ 5).
- Client closes and reconnects count only within the run, from the baseline's start to the recovery's end, like the server's counts. A teardown close after the run matches nothing.
- A close during a join, before the connection joined, goes through criterion 2's matching like any other close: it passes with a server-decided cause in the lifecycle log and a matching client close, and fails if unmatched on either side. It has no join sample, and a never-joined session's server line has no player, so it pairs by close code and time: each server-initiated close a client saw during a join pairs one-to-one, in time order, with a server-decided close no client close matched, with the same code and at most 5 s apart (the close frame's bound plus the client's detection). That server close is a session that never joined, or one whose JoinResponse crossed the close. Leftovers on either side are unmatched. Two closes with one code within 5 s of each other in one run can't be told apart; the table reports each run's never-joined server closes by code and the client closes with more than one candidate ("ambiguous"), and a run with an ambiguous pair reads "pending (n ambiguous pairs)" in criterion 2, never "pass", until a per-connection key (the remote port in the server's close line, the local port in the client's) tells them apart. A client's own join timeouts are counted, not matched. The join checks (a `serverPlayer`, a `sessionJoined`) cover joins before the recovery's end; a teardown join after the run fails nothing.
- The profiles that allow no server-initiated close (P0, D50J10, L1; D50, ASYM, GE and BO10 in the extension) are gated by their own row: any server-decided close in the log within the run, of a joined or a joining session, or any server-initiated close a client saw, fails. P0 and D50J10 also fail on an unanswered action outside the impaired segment. Criterion 2 doesn't forbid closes; these rows do.
- The memory, leak and isolation criteria follow "missing inputs fail": a run without memory samples, a leak check without P0 slopes, and an isolation check without impaired windows or a P0 band each fail, never show "–". So does a criterion whose P0 control lacks an input (a worker file, its population), since the band would come from fewer samples. The leak slope needs the whole 30 s: its first RSS sample within 2 s of the window's start, its last within 2 s of its end, and no gap over 5 s, for the run and for its controls.
- Isolation's "Closes" criterion is its own row per healthy group: any close in the run, joined or during a join, or any unanswered action, fails it.
- An action still unanswered because the load test's last phase ended (`phaseEnd`) within `LATE_MS` (5 s) of the recovery's end isn't counted unanswered, in any criterion: its answer had no time to arrive. Earlier `phaseEnd` actions, and actions on a closed connection, still count.

**Reordering:** on a host where jitter reorders (§ 1), D50J10 measures jitter with reordering, not jitter alone, and is labelled so; its results don't stand for an in-order jitter path.

**Isolation criteria,** for M and SR (and S1 in the extension). These are predeclared; a failure is the finding.

- **Closes:** every healthy group has zero closes and zero unanswered actions.
- **Same-room and cross-room effect:** in the impaired segment, each healthy group's segment-level input-to-visible p99 and update-gap p99 (all of the segment's samples pooled, not per window) stay within the band of the same statistic. That band is the maximum, over the P0 repeats, of the same statistic over segments of the same length at every offset in P0's quiet segments. Its false-positive rate is reported, as in § 5. The effect against P0 is reported with its range over the three repeats. Within the band, it is called "no detectable effect at this repeat count"; it is not called isolation proven.
- **Client-bound windows** (§ 2): they don't count either way, and how many there were is reported. Isolation leaves them out of the impaired segment's pooled statistics and out of P0's quiet windows for the band; recovery treats them as insufficient (neither healthy nor unhealthy, breaking a run of healthy windows) and leaves them out of the band. A group fails as missing when any of its workers' `loop` spans, every worker file counted, leave a gap over 2 s in the run: a stopped sampler would otherwise read as a worker that was never busy. When more than 20 % of a segment's windows are client-bound, the verdict drawn from the rest isn't one: isolation reads "inconclusive (n % client-bound)" when the impaired segment or a control's quiet windows are over that share, and so does recovery when the recovery segment is. Inconclusive is not a pass.

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
| Quiescence and convergence | under 10 s typically; at most about 41 s (the driver's 35 s deadline plus one check to its cap), inside the 45 s tail |
| Leave | 5 s |
| TIME_WAIT drain | 0–60 s |
| Server restart | 10 s |

That is about 5 min on average, and about 4.5 min for P0.

**Budgets, kept separate:**

| Stage | Estimate | Basis |
|---|---|---|
| Engineering (§ 9) | about 1.5–2 days of agent time. The trim removes cells, not tools: reconnect, shared rooms, reconstruction, the convergence coordinator, the exports, the slow reader and the analysis are all still needed | actual PR cadence |
| Host checklist (§ 10) | about 1 h of the measurement host's time, including the container recreate and the acceptance smoke | |
| Calibration (§ 1) | about 1–1.5 h. At 300 rooms: delay and jitter (D50J10, and COMBO through COMBO-norate), loss (L5), rate and queueing delay (RATE in U, COMBO in M), order (D50J10, COMBO), and SR's time-to-unwritable | measured during the smoke, then fixed |
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
   - **Retry schedule:** after a server-initiated close, or the client's own stale check (`--stale-after`, § 3), wait 1 s, then try one connect and join, with a 5 s timeout per attempt. Attempts are serial, never overlapping, and the next one is 1 s after the previous fails. Retrying is cancelled 60 s after the impairment's lift, which leaves at least 30 s of the 90 s recovery segment for 5 healthy windows.
   - **Identity:** the join message doesn't carry the configured `playerId` today, and the server assigns the player. So a reconnect is a **new join to the same land**, not a resumption of the same player; resumption is out of scope (§ 11). The tool keeps the configured slot key as the client-side identity across the reconnect, so the analysis can follow a slot.
   - It records the timings of § 5.
   - **Required:** the join sample carries `serverPlayer`, the playerID of the server's JoinResponse, which criterion 2 needs to map a connection to its session (§ 7). The smoke checks that every join sample has it.
5. **State reconstruction and the convergence coordinator** (§ 6): the per-connection SDK state view, a stop-sending command, the per-land freeze, settle and projection protocol across instances, and `normalizeForConvergence` shared with `Tools/CLI`.
6. **Exports and readers:**
   - the per-event and per-window raw samples of § 5, retained in the result set;
   - close aggregation by code and group;
   - the report reading `pongTimeoutCloses`;
   - the socket memory sampler: `sockstatMem` host-wide, and `socketQueues` per namespace (§ 5). Only `inuse` and `tw` of `/proc/net/sockstat` are per namespace; its `mem` is host-wide.
7. **Slow reader** (`--slow-read`), and the **stale-connection check** (`--stale-after`), suspended while that connection's reading is paused and restarted on resume. Both record detection times: the client's own close detection, whether by close frame, socket close or stale check, with its cause.
8. **The upstream split** in `impair.sh`: the prio, u32 and netem tree on `veth-s1` (§ 1), the `lt-good` namespace and veth, and an `ss -ti` snapshot of every impaired socket at the lift.
9. **Land instance identity:** each land's creation time or instance ID, from the admin API or the server log, recorded once per second and at every reconnect. If neither exposes it, adding a log line on land creation and destruction is a core change, made first.
10. **The analysis** in `regenerate.py`: segments, bands (with the per-session and segment-level bands), the healthy windows, `recoveryMs`, per-session recovery, close reconciliation, the false-positive control on P0, the client-bound flag, and the pass tables of § 7.

**Server side.** Nothing here changes the server, unless the smoke shows one of these is missing:

- the session-to-player mapping in the log (the close-cause warning lines already exist);
- land creation and destruction in the log, or land identity in the admin API;
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
ls /proc/config.gz && zcat /proc/config.gz | grep -E 'CONFIG_NET_SCH_NETEM|CONFIG_NET_SCH_FIFO|CONFIG_NET_SCH_PRIO|CONFIG_NET_CLS_U32|CONFIG_VETH|CONFIG_NET_NS'
```

- **All six `=y`:** continue.
- **Any `=m`:** the modules have to be loaded in the WSL distribution, outside the container. That is the maintainer's step; stop and report which options are `=m`.
  - Load them with **`modprobe -a`**. Plain `modprobe` loads only the first name and treats the rest as module parameters:

    ```bash
    sudo modprobe -a sch_netem sch_prio cls_u32      # the =m ones; add any other =m module the same way
    lsmod | grep -E '^(sch_netem|sch_prio|cls_u32) '   # one line per module, or it isn't loaded
    ```
  - **Loaded modules don't survive `wsl --shutdown` or a Windows restart.** Step 4 checks `/proc/modules` first, every time it runs, and the runs' driver does the same before each sweep session.
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

This builds the topology of § 1 with both client namespaces. It then checks:

- delay in both directions;
- the in-place change;
- the upstream split by source;
- packet order under jitter;
- the qdisc trees and drop counters;
- the offloads.

A trap tears everything down even when a step fails, and the script removes any leftovers first, so it can be rerun.

```bash
#!/usr/bin/env bash
set -euo pipefail
R="sudo ip netns exec lt-router"; C="sudo ip netns exec lt-client"; G="sudo ip netns exec lt-good"
teardown() {
  sudo ip route del 10.201.0.0/24 via 10.200.0.2 2>/dev/null || true
  sudo ip route del 10.202.0.0/24 via 10.200.0.2 2>/dev/null || true
  for ns in lt-client lt-good lt-router; do sudo ip netns del $ns 2>/dev/null || true; done
  sudo ip link del veth-s0 2>/dev/null || true
}
# Modules that the kernel builds as =m must be loaded (they don't survive a WSL restart; step 1).
for pair in sch_netem:NET_SCH_NETEM sch_prio:NET_SCH_PRIO cls_u32:NET_CLS_U32; do
  m=${pair%%:*}; opt=${pair#*:}
  if zcat /proc/config.gz | grep -q "^CONFIG_$opt=m" && ! grep -q "^$m " /proc/modules; then
    echo "module $m is not loaded: see step 1 (modprobe -a)"; exit 1
  fi
done
teardown; trap teardown EXIT

sudo ip netns add lt-client; sudo ip netns add lt-good; sudo ip netns add lt-router
sudo ip link add veth-s0 type veth peer name veth-s1; sudo ip link set veth-s1 netns lt-router
sudo ip link add veth-c0 type veth peer name veth-c1; sudo ip link set veth-c0 netns lt-client; sudo ip link set veth-c1 netns lt-router
sudo ip link add veth-g0 type veth peer name veth-g1; sudo ip link set veth-g0 netns lt-good;   sudo ip link set veth-g1 netns lt-router
sudo ip addr add 10.200.0.1/24 dev veth-s0; sudo ip link set veth-s0 up
$R ip addr add 10.200.0.2/24 dev veth-s1; $R ip addr add 10.201.0.1/24 dev veth-c1; $R ip addr add 10.202.0.1/24 dev veth-g1
for d in veth-s1 veth-c1 veth-g1 lo; do $R ip link set $d up; done
$R sysctl -qw net.ipv4.ip_forward=1
$C ip addr add 10.201.0.2/24 dev veth-c0; $C ip link set veth-c0 up; $C ip link set lo up; $C ip route add default via 10.201.0.1
$G ip addr add 10.202.0.2/24 dev veth-g0; $G ip link set veth-g0 up; $G ip link set lo up; $G ip route add default via 10.202.0.1
sudo ip route add 10.201.0.0/24 via 10.200.0.2; sudo ip route add 10.202.0.0/24 via 10.200.0.2
sudo ethtool -K veth-s0 tso off gso off gro off
for d in veth-s1 veth-c1 veth-g1; do $R ethtool -K $d tso off gso off gro off; done
$C ethtool -K veth-c0 tso off gso off gro off; $G ethtool -K veth-g0 tso off gso off gro off

# Downstream trees: netem + pfifo child on the shaped client veth, pfifo on the healthy one.
$R tc qdisc add dev veth-c1 root handle 1: netem delay 50ms limit 10000
$R tc qdisc add dev veth-c1 parent 1:1 pfifo limit 10000
$R tc qdisc add dev veth-g1 root pfifo limit 10000
# Upstream tree: prio; band 1:1 unshaped (lt-good), band 1:2 netem (lt-client), split by source.
$R tc qdisc add dev veth-s1 root handle 1: prio bands 2 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
$R tc qdisc add dev veth-s1 parent 1:1 handle 10: pfifo limit 10000
$R tc qdisc add dev veth-s1 parent 1:2 handle 20: netem delay 50ms limit 10000
$R tc qdisc add dev veth-s1 parent 20:1 pfifo limit 10000
$R tc filter add dev veth-s1 parent 1: protocol ip prio 1 u32 match ip src 10.201.0.0/24 flowid 1:2
$R tc filter add dev veth-s1 parent 1: protocol ip prio 1 u32 match ip src 10.202.0.0/24 flowid 1:1

echo "A"; $C ping -c 20 -q 10.200.0.1 | tail -1     # rtt avg about 100 ms
echo "B"; $G ping -c 20 -q 10.200.0.1 | tail -1     # rtt avg under 1 ms: lt-good is not shaped
$R tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 50ms loss 100% limit 10000
$R ip neigh flush all; sudo ip neigh flush all    # neighbour entries must be re-resolved during the outage
echo "C"; $G ping -c 10 -q 10.200.0.1 | tail -2     # 0% loss: lt-good still answers, ARP included
echo "D"; $C ping -c 10 -q -W 1 10.200.0.1 | tail -2 || true   # 100% loss for lt-client
$R tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 50ms 10ms limit 10000
$R tc qdisc change dev veth-c1 root handle 1: netem delay 50ms 10ms limit 10000
echo "E"; $C ping -i 0.005 -c 400 10.200.0.1 | awk -F'icmp_seq=' '/icmp_seq=/{split($2,a," "); if (a[1]+0 < last) out++; last=a[1]+0} END {print "out-of-order replies:", out+0}'
$R tc qdisc change dev veth-c1 root handle 1: netem delay 0ms limit 10000
$R tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 0ms limit 10000
echo "F"; $C ping -c 20 -q 10.200.0.1 | tail -1     # rtt avg under 1 ms after the in-place change
echo "G"; $R tc -s qdisc show dev veth-c1; $R tc -s qdisc show dev veth-s1; $R tc -s filter show dev veth-s1
echo "H"; $C ethtool -k veth-c0 | grep -E 'tcp-segmentation-offload|generic-(segmentation|receive)-offload'
echo "I"; nproc; taskset -p $$
```

After the script exits, the trap has torn everything down. Then:

```bash
ip link show | grep -c veth || true   # J: expect 0
```

**Pass:**

- A: `rtt min/avg/max/mdev` avg about 100 ms (± 3 ms). ping prints the average, not the median.
- B: avg under 1 ms.
- C: 0 % packet loss, after the neighbour caches were flushed, so ARP isn't shaped.
- D: 100 % packet loss.
- E: prints `out-of-order replies: N`. N = 0 means the pfifo child keeps order with jitter on this kernel. If N > 0, report N. The design then runs D50J10 and COMBO as jitter with reordering (§ 1); that is not a host failure.
- F: avg under 1 ms.
- G: `veth-c1` shows `netem 1:` with a `pfifo` child, and `veth-s1` shows `prio 1:` with `pfifo 10:`, `netem 20:` and its `pfifo`. Report the `dropped` counters: after D, netem `20:`'s `dropped` should have grown by the lost pings, which confirms loss and overflow share one counter.
- H: all three offloads off.
- I: shows the 12 logical CPUs the pinning shims expect.
- J: 0.

**Failures:**

- **`module ... is not loaded`, or `Specified qdisc kind is unknown`:** step 1 is incomplete, or the modules were lost in a WSL restart.
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

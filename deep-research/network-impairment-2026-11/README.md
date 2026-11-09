# Network impairment under multi-room load

Status: **one set, with results at commit `d8321fde`** (`results/`, Results below). In it, the group recoveryMs of the groups whose sessions reconnect is unmeasured (ws-loadtest #422; the Results lead-in names the rows). The design, with every metric's semantics and the pass criteria, is `Notes/plans/2026-11-07-network-impairment-experiment-design.md`.

`regenerate.py` already builds these tables, tested on synthetic runs in `test_analysis.py`:
- `recoveryMs` per group, against the cell's P0 band, with each P0 repeat tested against the other two. A group that was fully joined for five windows in a row, but never had five fully joined windows in a row with enough inputs sent (at least 50 inputs and 95 % of the send target), can't be judged and is marked insufficient. If the group reconnected and its run's commit predates ws-loadtest's fix f90471d4, the label names #422. "Not recovered" means the band wasn't met with enough inputs sent, or the group was never fully joined for five windows in a row;
- per-session recovery, each session against its own baseline, with survivors and firstSync rebuilds counted apart. A session has recovered after the lift when all of these hold:
  - its state converged: its land converged in the convergence check, or its own connection did;
  - over the last 10 s of the recovery segment, it was joined and received an update in every 1 s slot. If it reconnected, a firstSync rebuilt it;
  - its update-gap p99 over those 10 s is at most its own baseline gap p99 plus one sync interval (100 ms).

  A session with no baseline gaps can't be compared, so it fails. The P0 repeats are checked the same way, as the control. The criterion sees gaps, not delay: a constant added delay (D50J10) shifts every arrival by the same amount and leaves the gaps as they were. Delay shows in the latency rows;
- closes and server causes, as counts;
- every close has a cause (§ 7 criterion 2), per session. Each client close is paired with its session's `sessionClosed` cause from `land-lifecycle.jsonl`. A connection's join sample carries the server's playerID (`serverPlayer`), which maps it to a `sessionJoined` line in its land. A close belongs to the connection's latest join before it. The criterion fails on a client close with no server cause, on a server-decided close (`pongTimeout`, `backlogBytes`, `backlogUnwritable`, `serverClose`, `error`) anywhere in the run's log that no client close matches, on a join that maps to no server session, or when a profile counter is below the log's count of its causes (a counter above it is reported);
- the per-profile criteria (§ 7) for the sessions each impaired group had open at the apply. Server closes are split by their code: 4010 is a slow-consumer close, 4011 an unresponsive one and 4012 an unencodable view (3 failed resync snapshot encodes in a row; sync-lag tracking, #332), 4008 the backlog bound. None of 4010, 4011 and 4012 makes the client rejoin on its own.
  - In BO75, each must be closed on the server inside the outage by a pong timeout, the backlog bound or 4011, the client's own close must not be 4011 (it would not rejoin on its own), and it must be rebuilt by a firstSync within 60 s of the lift. Every stale close in the run must match a pong, backlog or 4011 close of its session.
  - In SR, each slow reader must get exactly one resync, then be closed with 4010 (about 13–14.5 s into the pause: 3 s to the resync, then the 10 s ack timeout), and be rebuilt by a firstSync by the end of recovery. Its precondition is that it sent acks while paused (`acksSentWhilePaused` > 0); without them the 4010 can't be told from a 4011, and the row fails as missing. A session's resyncs are counted on the client's side, up to its connection's close as the client logged it, and must equal that close record's own `resyncs`. When they differ, `analysis.py ingest` refuses, naming both numbers, and the sweep stops at "step ingest: analysis.py ingest failed"; the run's raw data stays in `data/` for a re-ingest. A 4008 is reported, "if seen", and fails the row.

  A group with fewer such sessions than its target fails;
- isolation of the healthy groups. In SR, the healthy sessions must also get no resync and no server close; under COMBO the same counts are reported only;
- sync-lag tracking per run: the clients' resyncs against the server's `syncLagResyncs` plus `syncLagResyncsAlongside`, the log's 4010, 4011 and 4012 counts against `syncLagSlowConsumerCloses`, `syncLagUnresponsiveCloses` and `syncLagUnencodableCloses`, and at least 3 `syncLagSnapshotEncodeFailures` per 4012; a mismatch fails. The exception is RATE and COMBO. Under the throttle, a session's close, whatever its cause, drops the frames still queued behind it. The server keeps at most one resync unacked per session. So fewer clients' resyncs than the server's, by at most the number of sessions closed in the run, are reported as in flight at close; a larger shortfall fails. The server counts resyncs per run, not per connection, so the difference is the totals', not attributed per connection. P0 must have no resync and no 4008, 4010, 4011 or 4012. In every other cell a 4012 is a finding. In D50J10 and L5 a resync is a finding, not a fail. Key-scope reset bytes (`syncLagKeyScopeResetBytes`) are reported land-wide, not gated. A run whose profile never carried the counters fails as missing;
- RATE and COMBO, which throttle below P0's demand by design. The impaired window is reported per session and never fails: sessions resynced, resyncs, the apply → first resync times (client arrival), 4010 closes, rejoins and the rejoin rate per session; a 4011 is a finding, reported with the client's CPU, as is a 4008 (the writer ceiling fired before tracking acted), with its count and times. Snapshot and firstSync bytes are reported as a share of the downstream (the downstream is shaped in aggregate, so resync bytes of one session compete with others). The recovery gate is the last 10 s: no resync, 4010, 4011 or rejoin, and every target session joined and converged at the end. No resync in 10 s already bounds each session's server-side lag at 3 s. Each session's last frame within 1.1 s of the end is reported, not gated. A recovery shorter than the last 4010 → rejoin → firstSync → 10 s quiet is inconclusive, not a fail. The staleness row repeats `plan.py`'s check, below;
- memory: the RSS leak check against P0's slope, and the peaks of RSS, host TCP memory and the server's Send-Q;
- convergence (§ 6, criterion 3): every room of the run checked, with no mismatched room, no missing client and no errored room after the one retry of an inconclusive room. A room still inconclusive marks the run inconclusive. A room whose difference went away within 5 s of the freeze converged late: reported in its own column with its largest delay, not a fail. The check's roster, connections per room per client instance, must match the run's `params.convergenceRoster`. Survivors' and reconnected connections' results are reported apart.

A missing input fails the criterion that needs it, as "fail (missing: ...)", the stale rule of P0, D50J10 and SR included: the lifecycle log, a profile covering under 95 % of the run's windows or never carrying `pongTimeoutCloses` or `sendBacklogCloses`, a group's worker files, a group short of its target joins (ingest records each group's `manifest`), or a missing or zero `sendTargetPerS`, or a group whose baseline sent fewer than 50 input-to-visible samples or saw under 95 % of them (unimpaired, every input is seen; fewer means the matcher missed the echo's wire shape). The load client's own phase gate, `--input-latency-min-seen`, is set to 0 in these runs, since its one phase holds the impairment. Without its P0 control a recovery check fails as "fail (no control)". Per-session recovery needs no control, but fails without the convergence check ("fail (missing: convergence)"). SR's control is M's P0.

## Question

When the client–server network is delayed, jittered, lossy, throttled or cut for a while, what happens to the server?

1. How far do input-to-visible latency and the server's send backlog grow?
2. How long does each take to come back after the impairment ends?
3. Does every client end in the server's state?
4. Are clients whose own network is fine affected, in the same room or in other rooms?

The answers cover the synthetic conditions tested here, netem profiles on one host. They are not a claim about any particular real network.

## Environment

The tables open with their provenance: the full commit, its dirty flag, the Swift (pinned 6.2.4)
and Node versions and the build configuration, which `regenerate.py` writes from the runs' `meta`
and refuses for runs with no commit or from more than one (`--check` verifies the line). Still to
be filled from the runs' `meta` when the sweep's data lands:
- the Linux container and kernel;
- the CPU pinning of server, clients and samplers.

Server flags, every run: `HOST=0.0.0.0`, `LOG_LEVEL=error`, `ENABLE_REEVALUATION=false`, and `ENABLE_DEBUG_STATE_ROUTES=true` for the convergence check. That flag only registers the admin freeze, projection and resume routes (`NIOAdminRoutes`). The freeze checks those routes reach run on every tick and sync whether or not the routes are registered, so until a route is called, a run with the flag does the same work as one without, and its P0 compares with runs that don't set it.

## Command(s)

Per run, from `Examples/GameDemo/ws-loadtest`, as root in the measurement container.

1. **Topology:** run once per run. `--with-good` is for populations M and SR.

   ```
   bash scripts/impair.sh setup --limit-down <N> --limit-up <N> [--with-good]
   ```

2. **The server, in the server namespace:**

   ```
   TRANSPORT_PROFILE_JSONL_PATH=<run>/profile.jsonl LAND_LIFECYCLE_LOG_PATH=<run>/land-lifecycle.jsonl \
     HOST=0.0.0.0 ENABLE_REEVALUATION=false ENABLE_DEBUG_STATE_ROUTES=true LOG_LEVEL=error GameServer &
   ```

3. **One client instance per client namespace:**

   ```
   ip netns exec lt-client bash scripts/run-ws-loadtest.sh --external-server <pid> \
     --external-profile <run>/profile.jsonl --samples-dir <run>/samples/lt-client \
     --stale-after 10 --reconnect on-server-close --reconstruct --control-socket /tmp/sst-ctl-lt-client.sock ...
   ```

   `--reconstruct` rebuilds client states with the SDK's state view, in every run, P0 included, so its cost is in every measurement. It does so for a sample of the connections (`--reconstruct-slots`), and the convergence check covers exactly that sample:
   - **U:** per room, slots 0–1.
   - **M and SR:** every impaired player, one healthy player in each mixed room (slot 1), and slot 0 of each healthy room.
   - lt-client gets 2 of the 12 workers. The control socket is a Unix socket, reachable from the container namespace without crossing the shaped path. Its path must stay under 104 bytes, so it lives in `/tmp`, not in the run directory.

4. **The impairment, at the timeline's offsets:**

   ```
   bash scripts/impair.sh schedule <profile> --at <epoch ms> --for <s> --timeline <run>/impairment-timeline.json
   ```

5. **Convergence, at the end of the recovery segment** (the scenario's 45 s tail holds it), from the server namespace:

   ```
   node dist/converge-main.js --control lt-client=/tmp/sst-ctl-lt-client.sock [--control lt-good=/tmp/sst-ctl-lt-good.sock] \
     --admin-url http://10.200.0.1:8080 --api-key <admin key> --deadline-s 35 --out <run>/convergence.json
   ```

   It stops every instance's sends, then checks every room, at most 20 at a time: freeze, a quiet barrier over the room's connections, a projection per player, the comparison, resume. A connection that differs is read again until it matches or 5 s after the freeze have passed (the projection stays fixed while the room is frozen). `--deadline-s 35` starts no room check later than 35 s in, so the last one ends before the tail's end closes the connections; a room left unchecked is an error. Criterion 3's row shows the rooms checked before the deadline and the pass's wall time: a run that checked fewer than all reads "fail (n of N rooms checked before the deadline)" and is rerun with a longer tail.

6. **Afterwards:** `bash scripts/impair.sh teardown`.

**The sweep driver: `run.sh`** runs these steps for every run of the matrix, in § 8's order: U, then M, each repeat starting with its P0 and rotating the rest; the SR calibration once (`SR-CAL`); then SR. Each run is `cell.py`, steps 1–6 plus the TIME_WAIT wait (at most 200 on port 8080 over every namespace), the stale control sockets, the samplers, the shared `--start-at`, `--room-slots` and the worker split, and run.json with every `params` field the analysis needs; then `analysis.py ingest` and `stopcheck.py`. `run.sh`'s header lists every option.
- **It stops**, naming the run and the step, when:
  - a step fails;
  - a table reads "missing" for the run;
  - a P0 run fails a hard criterion, convergence included;
  - SR is reached without `SR_PAUSE`, which you compute from `SR-CAL`.
- **The calibration** is a table in `calibration.py`: the 2026-11-07 values, run at server `12d3b01b`.
  - Limits are 10000/10000 except U-RATE at 1050/10000 and M-COMBO at 168/10000.
  - RATE runs at `25218749bit` and COMBO at `4047216bit`.
  - `reorderedPct` is `{"down": 0.614, "up": 0.386}` for D50J10 and `{"down": 16.13, "up": 0.843}` for COMBO.
  - RATE's and COMBO's rates are fractions of P0's downstream, and #301 and #308 shrank the frames. So a rate cell is refused unless its calibration ran the sweep's wire form.
  - Sync-lag tracking adds frames the calibration may not have carried: about 90 B/s down per shaped connection, and 65 B/s of acks up, which isn't shaped. `plan.py order` refuses a rate cell when the added downstream is over 20 % of the calibrated P0 downstream (the rate over the cell's fraction), with "recalibrate: #344 frames add N % to the calibrated demand"; `regenerate.py` reports the same numbers per run (`calibration.rate_staleness`). The built-in calibration adds about 2 %.
  - `MODE=calibrate bash run.sh` runs U-P0 and M-P0 at the current commit and writes `data/<RUN_ID>/calibration.json`, which a sweep reads with `CALIBRATION=<file>`.
  - The fixed limits and the jitter cells' reordering, which doesn't depend on payload size, carry over.
- **`MEASURING.lock` is the host agent's.** `run.sh` doesn't create, remove or read it.
- **The host procedure:** three RUN_IDs under one held lock, each a whole invocation, and never `OVERWRITE`, run from this topic's directory (`cd deep-research/network-impairment-2026-11`). `run.sh` resolves a relative `CALIBRATION` (and every other file-valued input) against the directory it was started from and refuses a missing file before any run; before that, a relative path was read from `Examples/GameDemo`, where `cell.py` runs, and failed there:
  0. As root, `modprobe -a sch_netem sch_prio cls_u32`, where the kernel builds them as modules. A loaded module doesn't survive a WSL restart, so load them again after one. `run.sh` checks this before the build and stops, exit 1, naming the missing modules; `impair.sh` setup refuses the same way.
     Also check that the topic holds nothing untracked: `git status --porcelain -- .` from this directory prints nothing (an earlier sweep's `results/` or `data/` files would otherwise ride along; see "What counts as dirty").
  1. `MODE=calibrate RUN_ID=<CAL> bash run.sh` exits 0.
  2. `CALIBRATION=data/<CAL>/calibration.json RUN_ID=<SWEEP> bash run.sh` runs U, M and SR-CAL. It exits **3** when it stops before SR as planned: every earlier run passed and `SR_PAUSE` isn't set.
  3. `SR_PAUSE=$(python3 srpause.py data/<SWEEP>-SR-CAL)`, stopping if it refuses, then `CALIBRATION=… CELLS=SR SR_PAUSE=$SR_PAUSE RUN_ID=<SR> bash run.sh` exits 0.

  Exit 1 is a failure. Exit 2 is a bad option, including `CELLS` naming SR without `SR_PAUSE`. Exit 3 is only the whole plan's stop before SR. `CELLS=`/`REPEATS=` per cell are for smokes only.
- **`srpause.py`** prints SR's pause: the slow readers' maximum pause → 4010 in SR-CAL, plus 10 s (§ 4). It takes each slow reader's first server close during the pause. It refuses, with a non-zero exit and the reason, when an input is missing, when the run isn't SR-CAL, when a send-backlog variable is set, when a healthy player closed, when fewer or more slow readers closed than the run has, when a close isn't a 4010, when a slow reader's first close in the pause isn't that of its connection open at the apply, when a resync falls before the apply, when that connection didn't get exactly one resync, or when it sent no acks while paused. The resync is counted as the SR row counts it: on the client's side, up to the connection's close as the client logged it, and equal to that close record's own `resyncs`; a connection without such a record, or a record without the count, is refused. It isn't bounded by the server's 4010: a paused reader handles its buffered frames only when its connection closes, so its resync line comes just before its own close and up to a second after the server's 4010, though the server sent it about 3 s into the pause. Each reconnect pauses for what is left of the window and cycles through its own resync and 4010 (about every 16 s); only each reader's first close sets the pause. On stderr it reports the basis: the slowest and fastest pause → 4010.
- **The SR smoke** runs first, before the 300-room SR-CAL, at 10 rooms with the pause fixed at 25 s: `ROOMS=10 CELLS=SR REPEATS=1 SR_PAUSE=25 RUN_ID=smoke-sr bash run.sh`, then `python3 srsmoke.py data/smoke-sr-SR-r1`. It passes when every slow reader paused, acked while paused, got one resync, was closed with 4010 during the pause and was rebuilt by a firstSync after that close, by the end of recovery (the client reconnects about 1 s after the 4010, inside the pause), no slow reader was closed by the stale check during the pause, and no healthy session got a resync or a server or stale close.
- **The gated close codes are reachable only under `--slow-read`.** A client that reads keeps its acks fresh, so 4010 and 4011 need a reader that stops; only SR and SR-CAL pass `--slow-read` (`test_topic.py` checks that every other cell's command line lacks it). Elsewhere a 4010 or 4011 is the shaped link starving a session (RATE, COMBO) or the outage (BO75).
- **The pre-sweep smoke** checks the mechanics only, so it passes the 2026-11-07 COMBO settings as overrides: `ROOMS=10 CELLS=M-COMBO REPEATS=1 RATE=4047216bit LIMITS=168:10000 RUN_ID=smoke-m-combo bash run.sh`. With `DRY_RUN=1`, the same line prints every command first.
- **The client must not be the bottleneck** (`clientload.py`; design § 2). Each run's `meta` records two figures per segment (baseline, impaired, recovery), from every worker's `loop` spans:
  - `clientCpu`: the workers' CPU demand on the pinned client CPUs, against the recorded mask. Only the worker processes are measured: not each instance's parent process, nor the sockstat and backlog samplers on the same CPUs.
  - `clientElu`: each worker's mean ELU, the largest over workers.

  Every worker of every instance (its configured count) must cover each segment for at least 95 % of it. A worker missing from the start, or one whose process or sampler stopped mid-run, makes both figures missing (`clientLoadMissing` names it), so it can't drop out and understate the demand.

  `stopcheck.py` stops the sweep, and `regenerate.py` refuses the run, when any segment's workers' CPU demand reaches 70 %, when any worker's ELU is over 0.5, or when a figure is missing (an unpinned run included). A demand over 100 % is reported as a broken measurement.
- **When the sweep stops** (`stopcheck.py`, after every run): on a missing input in any run, and on any hard-criterion failure in a P0 run (§ 8), the per-session verdict included: each session is held to its own baseline, so a P0 that fails it is an unhealthy control, and the sweep doesn't run past it.
- **Smoke runs stay out of the tables.** An invocation is a smoke when any of these is set: a calibration override (`RATE`, `LIMITS`, `JITTER_REORDERS`, `REORDERED_PCT`), `ROOMS=10`, or `REPEATS`. The M-COMBO and SR smoke lines are both smokes. A smoke's runs are ingested into their own `data/<run-id>/result.json`, which is ignored, never into `results/`, and their stop check reads them from there, so a smoke can't reach the tables. Any other invocation must be one of the host procedure's own: `MODE=calibrate`, the whole plan (no `CELLS`), `CELLS=SR` with `SR_PAUSE`, or `CELLS=SR-CAL` (never ingested). `run.sh` refuses anything else (exit 2) rather than guess where its results go.
- **Stopping a sweep.** Send `TERM` (or `INT`, `HUP`) to `run.sh`. It passes the signal to the running `cell.py`, which stops every process group it started (the load clients with their workers, the GameServer, the samplers, the schedule), runs `impair.sh teardown`, records the run's failure as step `stopped`, and exits 128 + the signal. `run.sh` then records the run as `stopped: stopped by SIG<name>` and exits 1. A `TERM` sent to `cell.py` itself, or to `run.sh`'s whole process group (Ctrl-C), does the same teardown; the sweep then stops. Nothing needs cleaning up by hand after `TERM`, `INT` or `HUP`. After a `KILL` to `cell.py` there is no teardown, and its children run on in their own sessions: as root, run `bash Examples/GameDemo/ws-loadtest/scripts/impair.sh teardown`, then stop what is left by name (`pkill -f run-ws-loadtest.sh`, `pkill -f GameServer`, `pkill -f sockstat-main.js`, `pkill -f 'impair.sh'`).
- **What counts as dirty.** Each `RUN_ID` records `git.dirty` at its start (`runmeta.py`, by `deep-research/gitstate.py`): any tracked change, or any untracked file outside this topic's `raw/`, `data/` and `results/`. So step 2's ingested `results/` don't mark step 3 dirty, while an uncommitted source, or a changed committed result, does. The cost: a stale untracked file left in `results/` by an aborted earlier sweep doesn't mark the next run dirty. Each result keeps its own run's commit and provenance refuses results from more than one commit, and before step 0/1 the host checks that `results/` and `data/` hold nothing untracked (`git status --porcelain -- deep-research/network-impairment-2026-11` empty). `INGEST=0` skips ingest and the stop check altogether. As a backstop, `regenerate.py` and `stopcheck.py` refuse a run with calibration overrides, a test hook, a sweep that didn't build (`BUILD=0`), or a dirty tree (`git.dirty` other than false).
- `python3 test_topic.py` tests the plan, the calibration, the stop rules, the dry run and `cell.py`/`run.sh` against fakes.

**Analysis:**

```
python3 analysis.py ingest data/<run-id>      # -> results/<run-id>.json
python3 regenerate.py                         # tables
python3 regenerate.py --check                 # OK when README matches
python3 -m unittest test_analysis             # analysis tests on synthetic fixtures
```

`data/<run-id>/` holds:
- `run.json`: `meta`, `params` and `groups`, see `analysis.py`. `params.jitterReorders` is set when the host's netem reorders with jitter (the acceptance smoke's step E). `params.reorderedPct` then holds the calibration capture's reordering per direction, as `{"down": %, "up": %}`, and the tables label D50J10 and COMBO as jitter with reordering. The run also records the calibration's fixed values it ran with: the netem limits and, for RATE and COMBO, the rate. `params.convergenceRoster` gives the connections the convergence check must list, per client instance, as rooms per connection count: `{"lt-client": {"2": 300}}` for U, `{"lt-client": {"1": 150}, "lt-good": {"1": 300}}` for M and SR, the reconstructed sample. Each group records `loopDelayP99Ms`, the worst worker's loop-delay p99 from its client instance's report, which validates the client-bound gate. The samples include each worker's `loop` spans (event-loop utilization), the gate's input;
- `impairment-timeline.json`;
- `samples/<instance>/`;
- `profile.jsonl`;
- `land-lifecycle.jsonl`;
- `system-metrics.json` (the server process's samples);
- `sockstat.jsonl` (`node dist/sockstat-main.js`; namespace `-` is the server's);
- `convergence.json` (`node dist/converge-main.js`).

**Where the data lives.** `results/<run-id>.json` (the ingest output) and the tables are here. The raw run directories are too large for this repository, so they are archived elsewhere, one gzipped tar per run (each under 50 MB), and `MANIFEST` here lists each archive's name, size and sha256 (`sha256sum`), so every result can be traced to the raw data it came from. `analysis.py ingest` on an unpacked archive reproduces its `results/<run-id>.json`.

## Parameter matrix

Planned: 300 rooms (1500 connections), three repeats per cell.

| Population | Profiles |
|---|---|
| U (all clients impaired) | P0, D50J10, L5, RATE, BO75 |
| M (one impaired player in each of half the rooms) | P0, COMBO, BO75 |
| SR (slow readers in M's layout; control: M's P0) | SR |

## Results

Provenance, from the results' meta: commit `d8321fde724be328614394b28fe4c9846f1d04a4`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

**Unmeasured rows.** Measured before f90471d4: reconnected sessions sent no inputs in ws-loadtest's spread and event send modes (#422). For an impaired group whose sessions reconnected, the recovery sends, RTT samples, unanswered counts and upstream bytes after its reconnects come only from the sessions that never reconnected. Its group recoveryMs couldn't be judged, because its recovery windows had too few inputs, so the Recovery table marks it insufficient, not "not recovered": M BO75 impaired, SR SR impaired, U BO75 impaired, U RATE impaired. Measured, at reduced room input load: M BO75 healthy-mixed, SR SR healthy-mixed. These healthy sessions didn't reconnect, but the impaired players in their rooms stopped sending after their reconnects, and they are judged against P0's band from full-load rooms, which leans toward passing. Not affected: per-session recovery (received updates and firstSyncs), the closes and their causes, the per-profile criteria and convergence.

### Recovery (recoveryMs, from the lift)

| rooms | population | profile | group | median | per repeat |
|---|---|---|---|---|---|
| 300 | M | BO75 | healthy-mixed | – | not recovered, 1000, 1000 |
| 300 | M | BO75 | healthy-rooms | – | not recovered, 1000, 1000 |
| 300 | M | BO75 | impaired | – | insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422) |
| 300 | M | COMBO (reordering) | healthy-mixed | 0 | 0, 0, 0 |
| 300 | M | COMBO (reordering) | healthy-rooms | 0 | 0, 0, 0 |
| 300 | M | COMBO (reordering) | impaired | 0 | 0, 1000, 0 |
| 300 | M | P0 | healthy-mixed | 0 | 0, 0, 0 |
| 300 | M | P0 | healthy-rooms | 0 | 0, 0, 0 |
| 300 | M | P0 | impaired | 0 | 0, 0, 4000 |
| 300 | SR | SR | healthy-mixed | 3000 | 1000, 6000, 3000 |
| 300 | SR | SR | healthy-rooms | 3000 | 1000, 7000, 3000 |
| 300 | SR | SR | impaired | – | insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422) |
| 300 | U | BO75 | impaired | – | insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422) |
| 300 | U | D50J10 (reordering) | impaired | 1000 | 1000, 1000, 1000 |
| 300 | U | L5 | impaired | 0 | 0, 0, 0 |
| 300 | U | P0 | impaired | 0 | 0, 0, 0 |
| 300 | U | RATE | impaired | – | insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422), insufficient (no inputs from reconnected sessions; ws-loadtest #422) |

### Per-session recovery (end of the recovery segment)

| run | profile | group | survived | rebuilt (firstSync) | not recovered | not recovered, by reason | verdict |
|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sr-SR-r1 | SR | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sr-SR-r1 | SR | impaired | 0 | 150 | 0 | – | pass |
| imp-20261109-sr-SR-r2 | SR | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sr-SR-r2 | SR | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sr-SR-r2 | SR | impaired | 0 | 150 | 0 | – | pass |
| imp-20261109-sr-SR-r3 | SR | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sr-SR-r3 | SR | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sr-SR-r3 | SR | impaired | 0 | 150 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | impaired | 0 | 150 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | impaired | 0 | 150 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | impaired | 0 | 150 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | impaired | 150 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | impaired | 150 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | impaired | 150 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r1 | P0 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r1 | P0 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r1 | P0 | impaired | 150 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | impaired | 150 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | impaired | 150 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-BO75-r1 | BO75 | impaired | 0 | 1500 | 0 | – | pass |
| imp-20261109-sweep-U-BO75-r2 | BO75 | impaired | 0 | 1500 | 0 | – | pass |
| imp-20261109-sweep-U-BO75-r3 | BO75 | impaired | 0 | 1500 | 0 | – | pass |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-L5-r1 | L5 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-L5-r2 | L5 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-L5-r3 | L5 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-P0-r1 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-P0-r2 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-P0-r3 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261109-sweep-U-RATE-r1 | RATE | impaired | 848 | 652 | 0 | – | pass |
| imp-20261109-sweep-U-RATE-r2 | RATE | impaired | 845 | 655 | 0 | – | pass |
| imp-20261109-sweep-U-RATE-r3 | RATE | impaired | 848 | 652 | 0 | – | pass |

### Closes and server causes (counts)

| run | profile | server-initiated (client) | pong timeout (server) | backlog 4008 (server) | stale (client) | stale rule | sendBufferedBytesMax |
|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | 150 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sr-SR-r2 | SR | 150 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sr-SR-r3 | SR | 150 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-M-BO75-r1 | BO75 | 0 | 0 | 0 | 150 | reported | 0 |
| imp-20261109-sweep-M-BO75-r2 | BO75 | 0 | 0 | 0 | 150 | reported | 0 |
| imp-20261109-sweep-M-BO75-r3 | BO75 | 0 | 0 | 0 | 150 | reported | 0 |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261109-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-BO75-r1 | BO75 | 0 | 0 | 0 | 1500 | reported | 0 |
| imp-20261109-sweep-U-BO75-r2 | BO75 | 0 | 0 | 0 | 1500 | reported | 0 |
| imp-20261109-sweep-U-BO75-r3 | BO75 | 0 | 0 | 0 | 1500 | reported | 0 |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-L5-r1 | L5 | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261109-sweep-U-L5-r2 | L5 | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261109-sweep-U-L5-r3 | L5 | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261109-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261109-sweep-U-RATE-r1 | RATE | 324 | 0 | 0 | 430 | reported | 0 |
| imp-20261109-sweep-U-RATE-r2 | RATE | 314 | 0 | 0 | 452 | reported | 0 |
| imp-20261109-sweep-U-RATE-r3 | RATE | 297 | 0 | 0 | 466 | reported | 0 |

### Every close has a cause (per session)

| run | profile | client closes | with server cause | client close, no cause | server close, no client close | joins without a server session | server closes during a join | never-joined server closes by code | causes | counter minus log | criterion 2 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sr-SR-r2 | SR | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sr-SR-r3 | SR | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-BO75-r1 | BO75 | 1500 | 1500 | 0 | 0 | 0 | 0 | 0 | serverClose 1500 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-BO75-r2 | BO75 | 1500 | 1500 | 0 | 0 | 0 | 0 | 0 | serverClose 1500 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-BO75-r3 | BO75 | 1500 | 1500 | 0 | 0 | 0 | 0 | 0 | serverClose 1500 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-L5-r1 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-L5-r2 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-L5-r3 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-RATE-r1 | RATE | 754 | 754 | 0 | 0 | 0 | 0 | 0 | connectionLost 383, serverClose 371 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-RATE-r2 | RATE | 766 | 766 | 0 | 0 | 0 | 0 | 0 | connectionLost 408, serverClose 358 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261109-sweep-U-RATE-r3 | RATE | 763 | 763 | 0 | 0 | 0 | 0 | 0 | connectionLost 414, serverClose 349 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |

### Every room converged (after recovery)

| run | profile | rooms checked before the deadline | converged | converged late (≤ 5 s) | mismatched | missing clients | inconclusive | errors | survivors converged | reconnected converged | check (s) | criterion 3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.6 | pass |
| imp-20261109-sr-SR-r2 | SR | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261109-sr-SR-r3 | SR | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.8 | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.6 | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.8 | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-M-P0-r1 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-U-BO75-r1 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 0/0 | 600/600 | 3.5 | pass |
| imp-20261109-sweep-U-BO75-r2 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 0/0 | 600/600 | 3.4 | pass |
| imp-20261109-sweep-U-BO75-r3 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 0/0 | 600/600 | 3.4 | pass |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.9 | pass |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-U-L5-r1 | L5 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.8 | pass |
| imp-20261109-sweep-U-L5-r2 | L5 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-U-L5-r3 | L5 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-U-P0-r1 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.9 | pass |
| imp-20261109-sweep-U-P0-r2 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.8 | pass |
| imp-20261109-sweep-U-P0-r3 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261109-sweep-U-RATE-r1 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 346/346 | 254/254 | 4.2 | pass |
| imp-20261109-sweep-U-RATE-r2 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 342/342 | 258/258 | 3.8 | pass |
| imp-20261109-sweep-U-RATE-r3 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 350/350 | 250/250 | 3.8 | pass |

### Profiles without server closes (P0, D50J10, L1)

| run | profile | server-decided closes (log) | server-initiated closes (clients) | unanswered outside the impaired segment | verdict |
|---|---|---|---|---|---|
| imp-20261109-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | pass |

### Per-profile criteria (BO75, SR)

| run | profile | group | open at the apply | closed as the profile requires | rebuilt by a firstSync in time | stale closes without pong, backlog or 4011 | server close kinds; details | verdict |
|---|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | impaired | 150 | 150 | 150 | – | slowConsumer 150; resyncs per reader {1: 150}; no acks while paused: 0; 4008 (if seen): 0 | pass |
| imp-20261109-sr-SR-r2 | SR | impaired | 150 | 150 | 150 | – | slowConsumer 150; resyncs per reader {1: 150}; no acks while paused: 0; 4008 (if seen): 0 | pass |
| imp-20261109-sr-SR-r3 | SR | impaired | 150 | 150 | 150 | – | slowConsumer 150; resyncs per reader {1: 150}; no acks while paused: 0; 4008 (if seen): 0 | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | impaired | 150 | 150 | 150 | 0 | unresponsive 150; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | impaired | 150 | 150 | 150 | 0 | unresponsive 150; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | impaired | 150 | 150 | 150 | 0 | unresponsive 150; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261109-sweep-U-BO75-r1 | BO75 | impaired | 1500 | 1500 | 1500 | 0 | unresponsive 1500; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261109-sweep-U-BO75-r2 | BO75 | impaired | 1500 | 1500 | 1500 | 0 | unresponsive 1500; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261109-sweep-U-BO75-r3 | BO75 | impaired | 1500 | 1500 | 1500 | 0 | unresponsive 1500; client got 4011: 0; closed after the lift: 0 | pass |

### Healthy sessions beside slow readers (SR gated, COMBO reported)

| run | profile | group | sessions | with a resync | with a server or stale close | verdict |
|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | healthy-mixed | 600 | 0 | 0 | pass |
| imp-20261109-sr-SR-r1 | SR | healthy-rooms | 750 | 0 | 0 | pass |
| imp-20261109-sr-SR-r2 | SR | healthy-mixed | 600 | 0 | 0 | pass |
| imp-20261109-sr-SR-r2 | SR | healthy-rooms | 750 | 0 | 0 | pass |
| imp-20261109-sr-SR-r3 | SR | healthy-mixed | 600 | 0 | 0 | pass |
| imp-20261109-sr-SR-r3 | SR | healthy-rooms | 750 | 0 | 0 | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | reported |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | reported |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | reported |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | reported |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | reported |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | reported |

### RATE and COMBO under sync-lag tracking

| run | profile | group | sessions resynced | resyncs (impaired) | apply → first resync (ms, client arrival) | 4010 (impaired) | rejoins | rejoins per session per min | full views' share of the downstream | calibration staleness | tail events (last 10 s) | not joined or converged at the end | findings | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | impaired | 0/150 | 0 | – | 0 | 0 | 0.0 | impaired 0.0%, recovery 0.0% | 2.1% (down), up 9750 B/s unshaped | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | impaired | 0/150 | 0 | – | 0 | 0 | 0.0 | impaired 0.0%, recovery 0.0% | 2.1% (down), up 9750 B/s unshaped | 0 | 0 | – | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | impaired | 0/150 | 0 | – | 0 | 0 | 0.0 | impaired 0.0%, recovery 0.0% | 2.1% (down), up 9750 B/s unshaped | 0 | 0 | – | pass |
| imp-20261109-sweep-U-RATE-r1 | RATE | impaired | 824/1500 | 1367 | 4353–60034 | 271 | 674 | 0.449 | impaired 1.4%, recovery 0.1% | 2.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×42 (workers' max ELU {'w0': 0.184, 'w1': 0.19, 'w10': 0.202, 'w11': 0.175, 'w2': 0.19, 'w3': 0.181, 'w4': 0.183, 'w5': 0.188, 'w6': 0.18, 'w7': 0.189, 'w8': 0.182, 'w9': 0.198}) | pass |
| imp-20261109-sweep-U-RATE-r2 | RATE | impaired | 807/1500 | 1322 | 4368–60027 | 275 | 715 | 0.476 | impaired 1.4%, recovery 0.1% | 2.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×42 (workers' max ELU {'w0': 0.212, 'w1': 0.205, 'w10': 0.215, 'w11': 0.191, 'w2': 0.2, 'w3': 0.195, 'w4': 0.209, 'w5': 0.185, 'w6': 0.245, 'w7': 0.205, 'w8': 0.197, 'w9': 0.193}) | pass |
| imp-20261109-sweep-U-RATE-r3 | RATE | impaired | 778/1500 | 1249 | 4329–59916 | 260 | 710 | 0.473 | impaired 1.4%, recovery 0.1% | 2.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×46 (workers' max ELU {'w0': 0.178, 'w1': 0.195, 'w10': 0.204, 'w11': 0.188, 'w2': 0.196, 'w3': 0.194, 'w4': 0.194, 'w5': 0.192, 'w6': 0.19, 'w7': 0.178, 'w8': 0.191, 'w9': 0.195}) | pass |

### Sync-lag tracking (#332): clients against the server

| run | profile | resyncs (clients) | resyncs (server, incl. alongside) | 4008 | 4010 | 4011 | 4012 | failed snapshot encodes | key-scope reset bytes (land-wide, includes the resyncs' key resets) | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | 444 | 444 | 0 | 150 | 0 | 0 | 0 | 734715 | pass |
| imp-20261109-sr-SR-r2 | SR | 446 | 446 | 0 | 150 | 0 | 0 | 0 | 727625 | pass |
| imp-20261109-sr-SR-r3 | SR | 443 | 443 | 0 | 150 | 0 | 0 | 0 | 730270 | pass |
| imp-20261109-sweep-M-BO75-r1 | BO75 | 0 | 0 | 0 | 0 | 150 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-BO75-r2 | BO75 | 0 | 0 | 0 | 0 | 150 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-BO75-r3 | BO75 | 0 | 0 | 0 | 0 | 150 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-BO75-r1 | BO75 | 0 | 0 | 0 | 0 | 1500 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-BO75-r2 | BO75 | 0 | 0 | 0 | 0 | 1500 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-BO75-r3 | BO75 | 0 | 0 | 0 | 0 | 1500 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-L5-r1 | L5 | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 4125 | finding (2 resyncs) |
| imp-20261109-sweep-U-L5-r2 | L5 | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 2940 | finding (2 resyncs) |
| imp-20261109-sweep-U-L5-r3 | L5 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 2090 | finding (1 resyncs) |
| imp-20261109-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261109-sweep-U-RATE-r1 | RATE | 1676 | 2107 | 0 | 329 | 42 | 0 | 0 | 3250579 | in flight at close: 431 of at most 765 (server 2107 − clients 1676; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261109-sweep-U-RATE-r2 | RATE | 1595 | 2054 | 0 | 316 | 42 | 0 | 0 | 3207090 | in flight at close: 459 of at most 771 (server 2054 − clients 1595; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261109-sweep-U-RATE-r3 | RATE | 1560 | 2025 | 0 | 303 | 46 | 0 | 0 | 3171749 | in flight at close: 465 of at most 771 (server 2025 − clients 1560; at most one unacked resync per closed session; totals, not attributable per connection) |

### Jitter with reordering

| run | profile | reordered data segments (%, per direction) |
|---|---|---|
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | 16.13 down, 0.843 up |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | 16.13 down, 0.843 up |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | 16.13 down, 0.843 up |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 0.614 down, 0.386 up |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 0.614 down, 0.386 up |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 0.614 down, 0.386 up |

### Memory

| run | profile | peak RSS impaired (MiB) | RSS slope, last 30 s (MiB/s) | leak check | end RSS above P0 peak (MiB) | host TCP mem peak (pages) | server Send-Q peak (bytes) |
|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | 102.27 | 0.712 | pass | -10.3 | 362 | 13435 |
| imp-20261109-sr-SR-r2 | SR | 102.91 | 0.706 | pass | -9.8 | 109 | 13112 |
| imp-20261109-sr-SR-r3 | SR | 102.61 | 0.715 | pass | -9.9 | 118 | 13518 |
| imp-20261109-sweep-M-BO75-r1 | BO75 | 105.79 | 0.06 | pass | -4.1 | 838 | 561178 |
| imp-20261109-sweep-M-BO75-r2 | BO75 | 103.6 | 0.064 | pass | -4.1 | 853 | 549279 |
| imp-20261109-sweep-M-BO75-r3 | BO75 | 105.09 | 0.098 | pass | -3.3 | 854 | 551382 |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | 104.21 | 0.061 | pass | -5.2 | 323 | 46808 |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | 104.25 | 0.084 | pass | -4.3 | 341 | 44644 |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | 104.63 | 0.078 | pass | -4.4 | 339 | 44320 |
| imp-20261109-sweep-M-P0-r1 | P0 | 105.28 | 0.063 | pass | -4.3 | 322 | 12533 |
| imp-20261109-sweep-M-P0-r2 | P0 | 104.08 | 0.076 | pass | -4.6 | 78 | 9374 |
| imp-20261109-sweep-M-P0-r3 | P0 | 104.58 | 0.268 | pass | 4.3 | 85 | 15515 |
| imp-20261109-sweep-U-BO75-r1 | BO75 | 102.53 | 0.0 | pass | -32.7 | 4821 | 4398359 |
| imp-20261109-sweep-U-BO75-r2 | BO75 | 102.36 | 0.0 | pass | -32.6 | 4855 | 4414266 |
| imp-20261109-sweep-U-BO75-r3 | BO75 | 103.61 | 0.001 | pass | -31.0 | 4390 | 4453462 |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | 103.86 | 0.069 | pass | -6.2 | 2241 | 341508 |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | 104.23 | 0.088 | pass | -7.2 | 1784 | 355281 |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | 105.2 | 0.087 | pass | -6.0 | 1829 | 347207 |
| imp-20261109-sweep-U-L5-r1 | L5 | 104.23 | 0.071 | pass | -6.2 | 1486 | 250768 |
| imp-20261109-sweep-U-L5-r2 | L5 | 104.6 | 0.085 | pass | -6.0 | 1250 | 247089 |
| imp-20261109-sweep-U-L5-r3 | L5 | 104.69 | 0.061 | pass | -6.1 | 1585 | 246528 |
| imp-20261109-sweep-U-P0-r1 | P0 | 105.43 | 0.089 | pass | -6.1 | 0 | 16192 |
| imp-20261109-sweep-U-P0-r2 | P0 | 104.27 | 0.262 | pass | 6.0 | 216 | 12527 |
| imp-20261109-sweep-U-P0-r3 | P0 | 103.81 | 0.08 | pass | -6.9 | 271 | 13401 |
| imp-20261109-sweep-U-RATE-r1 | RATE | 102.88 | 0.206 | pass | -8.8 | 4824 | 8834483 |
| imp-20261109-sweep-U-RATE-r2 | RATE | 102.6 | 0.189 | pass | -9.5 | 4592 | 8381289 |
| imp-20261109-sweep-U-RATE-r3 | RATE | 102.85 | 0.192 | pass | -9.5 | 4898 | 9087816 |

### Client-bound windows (excluded from isolation and recovery)

| run | profile | group | client-bound windows (ELU > 0.9) | largest span ELU per worker | largest window send-lag p99 (ms) | run-wide loop-delay p99 (ms) | gate check |
|---|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.14, w1 0.142, w2 0.137, w3 0.136, w4 0.141, w5 0.141, w6 0.137, w7 0.142, w8 0.139, w9 0.135 | 3.58251953125 | 0.93 | consistent |
| imp-20261109-sr-SR-r1 | SR | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.14, w1 0.142, w2 0.137, w3 0.136, w4 0.141, w5 0.141, w6 0.137, w7 0.142, w8 0.139, w9 0.135 | 3.8701171875 | 0.93 | consistent |
| imp-20261109-sr-SR-r1 | SR | impaired | baseline 0, impaired 0, recovery 0 | w0 0.417, w1 0.443 | 73.575927734375 | 0.94 | consistent |
| imp-20261109-sr-SR-r2 | SR | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.148, w1 0.137, w2 0.142, w3 0.139, w4 0.145, w5 0.144, w6 0.141, w7 0.141, w8 0.143, w9 0.142 | 2.98291015625 | 0.92 | consistent |
| imp-20261109-sr-SR-r2 | SR | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.148, w1 0.137, w2 0.142, w3 0.139, w4 0.145, w5 0.144, w6 0.141, w7 0.141, w8 0.143, w9 0.142 | 3.732177734375 | 0.92 | consistent |
| imp-20261109-sr-SR-r2 | SR | impaired | baseline 0, impaired 0, recovery 0 | w0 0.405, w1 0.409 | 37.164794921875 | 0.96 | consistent |
| imp-20261109-sr-SR-r3 | SR | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.147, w1 0.144, w2 0.144, w3 0.156, w4 0.154, w5 0.156, w6 0.148, w7 0.144, w8 0.155, w9 0.151 | 13.76025390625 | 0.97 | consistent |
| imp-20261109-sr-SR-r3 | SR | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.147, w1 0.144, w2 0.144, w3 0.156, w4 0.154, w5 0.156, w6 0.148, w7 0.144, w8 0.155, w9 0.151 | 12.399658203125 | 0.97 | consistent |
| imp-20261109-sr-SR-r3 | SR | impaired | baseline 0, impaired 0, recovery 0 | w0 0.429, w1 0.417 | 42.203857421875 | 0.97 | consistent |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.179, w1 0.185, w2 0.375, w3 0.334, w4 0.349, w5 0.367, w6 0.194, w7 0.199, w8 0.317, w9 0.182 | 71.945556640625 | 1.1 | consistent |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.179, w1 0.185, w2 0.375, w3 0.334, w4 0.349, w5 0.367, w6 0.194, w7 0.199, w8 0.317, w9 0.182 | 69.530517578125 | 1.1 | consistent |
| imp-20261109-sweep-M-BO75-r1 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.255, w1 0.239 | 2.9599609375 | 1.12 | consistent |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.209, w1 0.158, w2 0.241, w3 0.166, w4 0.206, w5 0.235, w6 0.16, w7 0.161, w8 0.17, w9 0.166 | 13.395751953125 | 0.99 | consistent |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.209, w1 0.158, w2 0.241, w3 0.166, w4 0.206, w5 0.235, w6 0.16, w7 0.161, w8 0.17, w9 0.166 | 19.33642578125 | 0.99 | consistent |
| imp-20261109-sweep-M-BO75-r2 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.217, w1 0.22 | 3.615478515625 | 0.97 | consistent |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.262, w1 0.263, w2 0.174, w3 0.31, w4 0.256, w5 0.171, w6 0.169, w7 0.165, w8 0.265, w9 0.273 | 75.0009765625 | 1.01 | consistent |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.262, w1 0.263, w2 0.174, w3 0.31, w4 0.256, w5 0.171, w6 0.169, w7 0.165, w8 0.265, w9 0.273 | 51.9736328125 | 1.01 | consistent |
| imp-20261109-sweep-M-BO75-r3 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.219, w1 0.225 | 7.942626953125 | 1 | consistent |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.171, w1 0.182, w2 0.277, w3 0.183, w4 0.155, w5 0.199, w6 0.248, w7 0.234, w8 0.278, w9 0.296 | 3.038330078125 | 0.96 | consistent |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.171, w1 0.182, w2 0.277, w3 0.183, w4 0.155, w5 0.199, w6 0.248, w7 0.234, w8 0.278, w9 0.296 | 3.47021484375 | 0.96 | consistent |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.261, w1 0.248 | 3.52978515625 | 0.98 | consistent |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.271, w1 0.166, w2 0.297, w3 0.33, w4 0.183, w5 0.338, w6 0.31, w7 0.29, w8 0.16, w9 0.288 | 3.51318359375 | 0.99 | consistent |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.271, w1 0.166, w2 0.297, w3 0.33, w4 0.183, w5 0.338, w6 0.31, w7 0.29, w8 0.16, w9 0.288 | 4.275146484375 | 0.99 | consistent |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.347, w1 0.26 | 4.87109375 | 0.99 | consistent |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.222, w1 0.199, w2 0.163, w3 0.158, w4 0.303, w5 0.281, w6 0.288, w7 0.274, w8 0.267, w9 0.158 | 3.91455078125 | 0.98 | consistent |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.222, w1 0.199, w2 0.163, w3 0.158, w4 0.303, w5 0.281, w6 0.288, w7 0.274, w8 0.267, w9 0.158 | 3.902099609375 | 0.98 | consistent |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.25, w1 0.241 | 4.738525390625 | 0.99 | consistent |
| imp-20261109-sweep-M-P0-r1 | P0 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.219, w1 0.177, w2 0.187, w3 0.162, w4 0.172, w5 0.163, w6 0.16, w7 0.165, w8 0.155, w9 0.171 | 8.489990234375 | 0.98 | consistent |
| imp-20261109-sweep-M-P0-r1 | P0 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.219, w1 0.177, w2 0.187, w3 0.162, w4 0.172, w5 0.163, w6 0.16, w7 0.165, w8 0.155, w9 0.171 | 10.2626953125 | 0.98 | consistent |
| imp-20261109-sweep-M-P0-r1 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.228, w1 0.228 | 26.66162109375 | 0.99 | consistent |
| imp-20261109-sweep-M-P0-r2 | P0 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.234, w1 0.148, w2 0.242, w3 0.238, w4 0.152, w5 0.234, w6 0.154, w7 0.158, w8 0.161, w9 0.164 | 4.91015625 | 0.96 | consistent |
| imp-20261109-sweep-M-P0-r2 | P0 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.234, w1 0.148, w2 0.242, w3 0.238, w4 0.152, w5 0.234, w6 0.154, w7 0.158, w8 0.161, w9 0.164 | 4.043212890625 | 0.96 | consistent |
| imp-20261109-sweep-M-P0-r2 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.221, w1 0.222 | 10.899658203125 | 0.98 | consistent |
| imp-20261109-sweep-M-P0-r3 | P0 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.219, w1 0.154, w2 0.228, w3 0.169, w4 0.166, w5 0.162, w6 0.157, w7 0.164, w8 0.164, w9 0.161 | 6.2880859375 | 0.98 | consistent |
| imp-20261109-sweep-M-P0-r3 | P0 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.219, w1 0.154, w2 0.228, w3 0.169, w4 0.166, w5 0.162, w6 0.157, w7 0.164, w8 0.164, w9 0.161 | 5.089599609375 | 0.98 | consistent |
| imp-20261109-sweep-M-P0-r3 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.226, w1 0.229 | 3.983154296875 | 1.01 | consistent |
| imp-20261109-sweep-U-BO75-r1 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.132, w1 0.127, w10 0.096, w11 0.128, w2 0.096, w3 0.101, w4 0.096, w5 0.125, w6 0.135, w7 0.108, w8 0.093, w9 0.109 | 3.10693359375 | 0.87 | consistent |
| imp-20261109-sweep-U-BO75-r2 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.099, w1 0.099, w10 0.098, w11 0.098, w2 0.1, w3 0.1, w4 0.098, w5 0.099, w6 0.098, w7 0.101, w8 0.097, w9 0.101 | 4.255859375 | 0.84 | consistent |
| imp-20261109-sweep-U-BO75-r3 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.091, w1 0.101, w10 0.096, w11 0.089, w2 0.096, w3 0.092, w4 0.095, w5 0.1, w6 0.095, w7 0.094, w8 0.091, w9 0.095 | 3.3486328125 | 0.84 | consistent |
| imp-20261109-sweep-U-D50J10-r1 | D50J10 (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.174, w1 0.187, w10 0.194, w11 0.187, w2 0.185, w3 0.181, w4 0.186, w5 0.188, w6 0.193, w7 0.196, w8 0.181, w9 0.183 | 5.886962890625 | 1.04 | consistent |
| imp-20261109-sweep-U-D50J10-r2 | D50J10 (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.193, w1 0.203, w10 0.204, w11 0.203, w2 0.202, w3 0.184, w4 0.189, w5 0.185, w6 0.2, w7 0.187, w8 0.202, w9 0.191 | 5.355224609375 | 1.07 | consistent |
| imp-20261109-sweep-U-D50J10-r3 | D50J10 (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.195, w1 0.192, w10 0.2, w11 0.185, w2 0.215, w3 0.205, w4 0.183, w5 0.214, w6 0.191, w7 0.201, w8 0.205, w9 0.199 | 7.4951171875 | 1.06 | consistent |
| imp-20261109-sweep-U-L5-r1 | L5 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.191, w1 0.197, w10 0.195, w11 0.194, w2 0.193, w3 0.195, w4 0.188, w5 0.201, w6 0.186, w7 0.177, w8 0.193, w9 0.199 | 5.20947265625 | 1.02 | consistent |
| imp-20261109-sweep-U-L5-r2 | L5 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.228, w1 0.226, w10 0.216, w11 0.198, w2 0.206, w3 0.191, w4 0.184, w5 0.21, w6 0.201, w7 0.204, w8 0.199, w9 0.193 | 10.837890625 | 1.01 | consistent |
| imp-20261109-sweep-U-L5-r3 | L5 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.184, w1 0.189, w10 0.183, w11 0.195, w2 0.186, w3 0.197, w4 0.202, w5 0.197, w6 0.183, w7 0.193, w8 0.185, w9 0.21 | 4.80322265625 | 1.02 | consistent |
| imp-20261109-sweep-U-P0-r1 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.203, w1 0.199, w10 0.226, w11 0.205, w2 0.208, w3 0.198, w4 0.193, w5 0.204, w6 0.211, w7 0.222, w8 0.192, w9 0.193 | 7.8544921875 | 1.11 | consistent |
| imp-20261109-sweep-U-P0-r2 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.191, w1 0.199, w10 0.193, w11 0.195, w2 0.192, w3 0.204, w4 0.203, w5 0.199, w6 0.191, w7 0.187, w8 0.195, w9 0.192 | 5.48388671875 | 1.05 | consistent |
| imp-20261109-sweep-U-P0-r3 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.193, w1 0.195, w10 0.193, w11 0.186, w2 0.187, w3 0.192, w4 0.193, w5 0.186, w6 0.188, w7 0.196, w8 0.202, w9 0.196 | 4.544921875 | 1.02 | consistent |
| imp-20261109-sweep-U-RATE-r1 | RATE | impaired | baseline 0, impaired 0, recovery 0 | w0 0.184, w1 0.19, w10 0.202, w11 0.175, w2 0.19, w3 0.181, w4 0.183, w5 0.188, w6 0.18, w7 0.189, w8 0.182, w9 0.198 | 8.019287109375 | 1.08 | consistent |
| imp-20261109-sweep-U-RATE-r2 | RATE | impaired | baseline 0, impaired 0, recovery 0 | w0 0.212, w1 0.205, w10 0.215, w11 0.191, w2 0.2, w3 0.195, w4 0.209, w5 0.185, w6 0.245, w7 0.205, w8 0.197, w9 0.193 | 10.8447265625 | 1.07 | consistent |
| imp-20261109-sweep-U-RATE-r3 | RATE | impaired | baseline 0, impaired 0, recovery 0 | w0 0.178, w1 0.195, w10 0.204, w11 0.188, w2 0.196, w3 0.194, w4 0.194, w5 0.192, w6 0.19, w7 0.178, w8 0.191, w9 0.195 | 4.40478515625 | 1.06 | consistent |

### Isolation (healthy groups, impaired segment)

| run | profile | group | statistic | value (ms) | P0 band (ms) | within |
|---|---|---|---|---|---|---|
| imp-20261109-sr-SR-r1 | SR | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sr-SR-r1 | SR | healthy-mixed | inputP99 | 99 | 100 | yes |
| imp-20261109-sr-SR-r1 | SR | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sr-SR-r1 | SR | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sr-SR-r1 | SR | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sr-SR-r1 | SR | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sr-SR-r2 | SR | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sr-SR-r2 | SR | healthy-mixed | inputP99 | 100 | 100 | yes |
| imp-20261109-sr-SR-r2 | SR | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sr-SR-r2 | SR | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sr-SR-r2 | SR | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sr-SR-r2 | SR | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sr-SR-r3 | SR | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sr-SR-r3 | SR | healthy-mixed | inputP99 | 99 | 100 | yes |
| imp-20261109-sr-SR-r3 | SR | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sr-SR-r3 | SR | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sr-SR-r3 | SR | healthy-rooms | inputP99 | 99 | 100 | yes |
| imp-20261109-sr-SR-r3 | SR | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-mixed | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-BO75-r1 | BO75 | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-mixed | inputP99 | 99 | 100 | yes |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-BO75-r2 | BO75 | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-mixed | inputP99 | 99 | 100 | yes |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-BO75-r3 | BO75 | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | inputP99 | 99 | 100 | yes |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | inputP99 | 99 | 100 | yes |
| imp-20261109-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | gapP99 | 101 | 101 | yes |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | inputP99 | 100 | 100 | yes |
| imp-20261109-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | gapP99 | 101 | 101 | yes |

## Conclusion

None yet: no runs.

## Caveats

**Fixed:**
- messagepack encoding;
- Hero Defense at 1 action/s;
- 5 players per room;
- the server's bounds at their defaults: backlog 8 MiB / 30 s, ping 30 s, pong 20 s;
- sync-lag tracking at its defaults: resync after 3 s of lag, ack timeout 10 s, ack freshness 2 s, slow consumer at 3 resyncs in 60 s (recorded in `params.syncLag`, the variables unset in `meta.syncLagEnv`);
- the load client's reconnect timing at ws-loadtest's defaults: 1000 ms between attempts, 5000 ms per attempt (`params.reconnectDelayMs`, `params.reconnectAttemptTimeoutMs`);
- the impaired window runs with sync-lag tracking at its defaults (resyncs, 4010 and rejoins under the throttle); it is not comparable with sets recorded before tracking; the recovery criterion and aggregate delivered bytes are;
- in-turn sync as the baseline rerun ran it;
- one host, with server and clients on separate pinned CPUs;
- one load point, 300 rooms.

**Known limitation of this set:** measured before f90471d4, so reconnected sessions sent no inputs in ws-loadtest's spread and event send modes (#422). This affects the impaired groups that reconnected: every session of SR and BO75, and 652–655 of RATE's 1500. Their recovery sends, RTT samples, unanswered counts and upstream bytes after the reconnects come only from the sessions that never reconnected, and their group recoveryMs is unmeasured. COMBO's impaired group and every healthy group didn't reconnect. The mixed-room healthy groups of SR and M-BO75 are measured, but at reduced room input load, against P0's band from full-load rooms. Per-session recovery reads received updates and firstSyncs, so it is unaffected.

**Observed, not explained:** in every run of this set, P0 included, the healthy groups' and U's impaired group's RTT p99 rises over the recovery segment. Its median is about 2.0 ms in the baseline and 3.5–6.9 ms in the recovery's last 10 s. recoveryMs is read from the first run of five in-band windows after the lift, so it doesn't show this rise. M-BO75 r1's healthy groups have no such run: 4 and 5 of their 90 recovery windows are healthy, none five in a row, and every window had enough inputs sent. So their "not recovered" is a band result, not too few inputs. r2 and r3 start in band and read 1000. r1's client figures are a little higher than r2's and r3's, and inside the client-bound gate: client CPU max 47.0 % (42.2 and 42.6 %), client ELU max 0.185 (0.167, 0.169), loop delay p99 1.1 ms (0.99, 1.01).

**Not covered:**
- real WAN paths or measured traces;
- per-client independent netem links: per-client conditions are covered only by the slow reader;
- session resumption by the same player;
- other kernels' TCP stacks;
- clients on separate machines.

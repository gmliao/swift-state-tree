# Network impairment under multi-room load

Status: **one set without the spawn ramp, at commit `48962fae`** (`results/`, Results below), and **#490's re-run of U-P0 and U-RATE at `03d65381`** (`results/rerun-490/`, its own section below the Results: 6 runs after a calibration, all 8 run directories stationary). The 48962fae set: 24 sweep runs and 3 SR runs, after a calibration taken under the same workload (`imp-20261110-noramp-cal`), and every run's live monster load stationary from the baseline's start to the recovery's end (`stationarity.py`, at `48dd1725`, on all 30 run directories, the calibration's and SR-CAL's included). The host activity that overlapped it is under Caveats. The earlier set, at commit `d8321fde`, ran Hero Defense's spawn ramp, so its monster load grew across every run's segments (#425); it is archived in `results/d8321fde/`, outside the tables, `stopcheck.py` and provenance, which read only `results/*.json`, so this set is compared only with its own runs. `python3 regenerate.py --results results/d8321fde` prints its tables, as published until this move. In that set, the group recoveryMs of the groups whose sessions reconnect is unmeasured (ws-loadtest #422; its tables' lead-in names the rows). The design, with every metric's semantics and the pass criteria, is `Notes/plans/2026-11-07-network-impairment-experiment-design.md`.

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
and refuses for runs with no commit or from more than one (`--check` verifies the line).

The 48962fae set ran in a Docker container from `swift:6.2.4-noble` (`CAP_NET_ADMIN` and `CAP_SYS_ADMIN`, no CPU or memory
limits, 12 CPUs) on **WSL2 kernel 6.18.54.1-microsoft-standard-WSL2**, the kernel the earlier sets ran on, with the host's power
plan at High performance (the measurement host's notes). Windows Update moved the host to WSL 3.0.5.0 and kernel 6.18.58.1 at
09:40:39Z on 2026-11-10, after this set ended: a later set on the new kernel records it, and isn't like for like with this one
until shown to be. CPU pinning, from each run's `meta` (`serverCpus`, `clientCpus`): the server on CPUs 0-7, the load clients
on 8-11; the sockstat and backlog samplers share the clients' CPUs.

**The sync path (#468).** `cell.py` starts the server without the sync-path and wire switches (`USE_SNAPSHOT_FOR_SYNC`, `IN_TURN_SYNC`, `USE_SYNC_TABLES`, `ROW_ADDRESSING`, `SYNC_STRATEGY`, and the send bounds `OUTBOUND_WRITER_MAX_BYTES` and `JOIN_FLIP_BUDGET`; `server_environ`), so a run takes the shipped sync path whatever the shell had, and `meta.syncPathEnv` records the shell's values. The 48962fae set predates that, and ran the default path: in-turn sync was on, since every one of its 30 run directories' server profiles has sync folds (0.27–0.42 per sync cycle), which only in-turn sync makes; and none of the first three was set in the container's environment, the measurement chain's scripts or the runner shell, whose own gate refuses `USE_SNAPSHOT_FOR_SYNC` and `IN_TURN_SYNC` and passed at the set's start.

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
     HERO_DEFENSE_STATS_PATH=<run>/land-stats.jsonl HERO_DEFENSE_SPAWN_RAMP_TICKS=0 \
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

  `stopcheck.py` stops the sweep, and `regenerate.py` refuses the run, when any segment's workers' CPU demand reaches 70 %, when any worker's ELU over a segment (the time-weighted mean of its spans, not a single span's) is over 0.5, or when a figure is missing (an unpinned run included). A demand over 100 % is reported as a broken measurement.
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
- `land-stats.jsonl`: each land's tick, live monster count, base health and players, and its monster flows so far (spawned, killed, reached the base), as of its last tick in each 1 s window (`HeroDefenseStats` in `Examples/GameDemo`; from commits that have it);
- `system-metrics.json` (the server process's samples);
- `sockstat.jsonl` (`node dist/sockstat-main.js`; namespace `-` is the server's);
- `convergence.json` (`node dist/converge-main.js`).

**Where the data lives.** `results/<run-id>.json` (the ingest output) and the tables are here; an earlier set's results move to `results/<commit>/` (the d8321fde set, `results/d8321fde/`). The raw run directories are too large for this repository, so they are archived elsewhere, one gzipped tar per run (each under 50 MB), and `MANIFEST` here lists the 48962fae set's archives (sha256, size and run; the stored files carry a host-side prefix, and the sha256 identifies each), `results/rerun-490/MANIFEST` the #490 re-run's, so every result can be traced to the raw data it came from. The earlier d8321fde set's archives have no list here. `analysis.py ingest` on an unpacked archive reproduces its `results/<run-id>.json`.

## Parameter matrix

Planned: 300 rooms (1500 connections), three repeats per cell.

| Population | Profiles |
|---|---|
| U (all clients impaired) | P0, D50J10, L5, RATE, BO75 |
| M (one impaired player in each of half the rooms) | P0, COMBO, BO75 |
| SR (slow readers in M's layout; control: M's P0) | SR |

## Results

Provenance, from the results' meta: commit `48962faea5bb47044620a5ee0e41505c6d9e77c1`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

### Recovery (recoveryMs, from the lift)

| rooms | population | profile | group | median | per repeat |
|---|---|---|---|---|---|
| 300 | M | BO75 | healthy-mixed | 2000 | 1000, 7000, 2000 |
| 300 | M | BO75 | healthy-rooms | 2000 | 1000, 8000, 2000 |
| 300 | M | BO75 | impaired | 7000 | 7000, 8000, 2000 |
| 300 | M | COMBO (reordering) | healthy-mixed | 0 | 0, 0, 1000 |
| 300 | M | COMBO (reordering) | healthy-rooms | 0 | 0, 0, 1000 |
| 300 | M | COMBO (reordering) | impaired | 8000 | 8000, 2000, 10000 |
| 300 | M | P0 | healthy-mixed | 0 | 0, 0, 0 |
| 300 | M | P0 | healthy-rooms | 0 | 0, 0, 0 |
| 300 | M | P0 | impaired | 0 | 0, 0, 0 |
| 300 | SR | SR | healthy-mixed | 2000 | 2000, 2000, 2000 |
| 300 | SR | SR | healthy-rooms | 2000 | 0, 2000, 2000 |
| 300 | SR | SR | impaired | 2000 | 3000, 2000, 2000 |
| 300 | U | BO75 | impaired | 3000 | 3000, 7000, 3000 |
| 300 | U | D50J10 (reordering) | impaired | 1000 | 2000, 1000, 1000 |
| 300 | U | L5 | impaired | 1000 | 10000, 1000, 1000 |
| 300 | U | P0 | impaired | 0 | 0, 0, 2000 |
| 300 | U | RATE | impaired | 6000 | 24000, 5000, 6000 |

### Per-session recovery (end of the recovery segment)

| run | profile | group | survived | rebuilt (firstSync) | not recovered | not recovered, by reason | verdict |
|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r1 | SR | impaired | 0 | 150 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | impaired | 0 | 150 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | impaired | 0 | 150 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | impaired | 0 | 150 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | impaired | 0 | 150 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | impaired | 0 | 150 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | impaired | 8 | 142 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | impaired | 8 | 142 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | impaired | 6 | 144 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | impaired | 150 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | impaired | 150 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | healthy-mixed | 600 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | healthy-rooms | 750 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | impaired | 150 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | impaired | 0 | 1500 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | impaired | 0 | 1500 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | impaired | 0 | 1500 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | impaired | 9 | 1491 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | impaired | 7 | 1493 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | impaired | 7 | 1493 | 0 | – | pass |

### Closes and server causes (counts)

| run | profile | server-initiated (client) | pong timeout (server) | backlog 4008 (server) | stale (client) | stale rule | sendBufferedBytesMax |
|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | 150 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sr-SR-r2 | SR | 150 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sr-SR-r3 | SR | 150 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | 0 | 0 | 0 | 150 | reported | 0 |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | 0 | 0 | 0 | 150 | reported | 0 |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | 0 | 0 | 0 | 150 | reported | 0 |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 220 | 0 | 0 | 2 | reported | 0 |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 226 | 0 | 0 | 1 | reported | 0 |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 221 | 0 | 0 | 2 | reported | 0 |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | 0 | 0 | 0 | 1500 | reported | 0 |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | 0 | 0 | 0 | 1500 | reported | 0 |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | 0 | 0 | 0 | 1500 | reported | 0 |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | 0 | 0 | 0 | 0 | reported | 0 |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | 1040 | 13 | 0 | 2065 | reported | 84095 |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | 1081 | 8 | 0 | 2014 | reported | 81979 |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | 1156 | 9 | 0 | 1908 | reported | 0 |

### Every close has a cause (per session)

| run | profile | client closes | with server cause | client close, no cause | server close, no client close | joins without a server session | server closes during a join | never-joined server closes by code | causes | counter minus log | criterion 2 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | serverClose 150 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 222 | 222 | 0 | 0 | 0 | 0 | 0 | connectionLost 2, serverClose 220 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 227 | 227 | 0 | 0 | 0 | 0 | 0 | connectionLost 1, serverClose 226 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 223 | 223 | 0 | 0 | 0 | 0 | 0 | connectionLost 2, serverClose 221 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | 1500 | 1500 | 0 | 0 | 0 | 0 | 0 | serverClose 1500 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | 1500 | 1500 | 0 | 0 | 0 | 0 | 0 | serverClose 1500 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | 1500 | 1500 | 0 | 0 | 0 | 0 | 0 | serverClose 1500 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | 3105 | 3105 | 0 | 16 | 0 | 0 (pongTimeout 13) | 1001 ×13 | connectionLost 1535, serverClose 1570 | pongTimeoutCloses +0, sendBacklogCloses +0 | fail |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | 3095 | 3095 | 0 | 9 | 0 | 0 (pongTimeout 8) | 1001 ×8 | connectionLost 1474, serverClose 1621 | pongTimeoutCloses +0, sendBacklogCloses +0 | fail |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | 3064 | 3064 | 0 | 11 | 0 | 0 (pongTimeout 9) | 1001 ×9 | connectionLost 1472, serverClose 1592 | pongTimeoutCloses +0, sendBacklogCloses +0 | fail |

### Every room converged (after recovery)

| run | profile | rooms checked before the deadline | converged | converged late (≤ 5 s) | mismatched | missing clients | inconclusive | errors | survivors converged | reconnected converged | check (s) | criterion 3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.6 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 300/300 | 150/150 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 308/308 | 142/142 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 308/308 | 142/142 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 306/306 | 144/144 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 4.0 | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 450/450 | 0/0 | 3.7 | pass |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 0/0 | 600/600 | 4.0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 0/0 | 600/600 | 3.8 | pass |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 0/0 | 600/600 | 3.9 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.8 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.9 | pass |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.6 | pass |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.9 | pass |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.8 | pass |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 2/2 | 598/598 | 3.9 | pass |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 1/1 | 599/599 | 3.8 | pass |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 1/1 | 599/599 | 3.9 | pass |

### Profiles without server closes (P0, D50J10)

| run | profile | server-decided closes (log) | server-initiated closes (clients) | unanswered outside the impaired segment | verdict |
|---|---|---|---|---|---|
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | pass |

### Per-profile criteria (BO75, SR)

| run | profile | group | open at the apply | closed as the profile requires | rebuilt by a firstSync in time | stale closes without pong, backlog or 4011 | server close kinds; details | verdict |
|---|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | impaired | 150 | 150 | 150 | – | slowConsumer 150; resyncs per reader {1: 150}; no acks while paused: 0; 4008 (if seen): 0 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | impaired | 150 | 150 | 150 | – | slowConsumer 150; resyncs per reader {1: 150}; no acks while paused: 0; 4008 (if seen): 0 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | impaired | 150 | 150 | 150 | – | slowConsumer 150; resyncs per reader {1: 150}; no acks while paused: 0; 4008 (if seen): 0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | impaired | 150 | 150 | 150 | 0 | unresponsive 150; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | impaired | 150 | 150 | 150 | 0 | unresponsive 150; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | impaired | 150 | 150 | 150 | 0 | unresponsive 150; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | impaired | 1500 | 1500 | 1500 | 0 | unresponsive 1500; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | impaired | 1500 | 1500 | 1500 | 0 | unresponsive 1500; client got 4011: 0; closed after the lift: 0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | impaired | 1500 | 1500 | 1500 | 0 | unresponsive 1500; client got 4011: 0; closed after the lift: 0 | pass |

### Healthy sessions beside slow readers (SR gated, COMBO reported)

| run | profile | group | sessions | with a resync | with a server or stale close | verdict |
|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-mixed | 600 | 0 | 0 | pass |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-rooms | 750 | 0 | 0 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-mixed | 600 | 0 | 0 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-rooms | 750 | 0 | 0 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-mixed | 600 | 0 | 0 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-rooms | 750 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | reported |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | reported |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | reported |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | reported |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | 600 | 0 | 0 | reported |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | 750 | 0 | 0 | reported |

### RATE and COMBO under sync-lag tracking

| run | profile | group | sessions resynced | resyncs (impaired) | apply → first resync (ms, client arrival) | 4010 (impaired) | rejoins | rejoins per session per min | full views' share of the downstream | calibration staleness | tail events (last 10 s) | not joined or converged at the end | findings | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | impaired | 148/150 | 486 | 4959–52786 | 217 | 219 | 1.46 | impaired 3.4%, recovery 0.1% | 1.1% (down), up 9750 B/s unshaped | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | impaired | 150/150 | 511 | 5174–48670 | 224 | 225 | 1.5 | impaired 3.6%, recovery 0.1% | 1.1% (down), up 9750 B/s unshaped | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | impaired | 148/150 | 473 | 5297–57919 | 212 | 214 | 1.426 | impaired 3.3%, recovery 0.1% | 1.1% (down), up 9750 B/s unshaped | 0 | 0 | – | pass |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | impaired | 1036/1500 | 2165 | 4786–59989 | 1136 | 2937 | 1.957 | impaired 3.8%, recovery 0.3% | 1.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×332 (workers' max ELU {'w0': 0.528, 'w1': 0.597, 'w10': 0.93, 'w11': 0.475, 'w2': 0.541, 'w3': 0.489, 'w4': 0.558, 'w5': 0.903, 'w6': 0.537, 'w7': 0.576, 'w8': 0.513, 'w9': 0.582}) | pass |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | impaired | 1047/1500 | 2185 | 3845–59954 | 1147 | 2896 | 1.929 | impaired 3.8%, recovery 0.3% | 1.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×347 (workers' max ELU {'w0': 0.908, 'w1': 0.911, 'w10': 0.718, 'w11': 0.748, 'w2': 0.845, 'w3': 0.787, 'w4': 0.795, 'w5': 0.905, 'w6': 0.893, 'w7': 0.815, 'w8': 0.926, 'w9': 0.929}) | pass |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | impaired | 1043/1500 | 2151 | 4365–59821 | 1095 | 2871 | 1.912 | impaired 3.7%, recovery 0.3% | 1.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×369 (workers' max ELU {'w0': 0.557, 'w1': 0.72, 'w10': 0.742, 'w11': 0.898, 'w2': 0.682, 'w3': 0.88, 'w4': 0.796, 'w5': 0.836, 'w6': 0.657, 'w7': 0.737, 'w8': 0.728, 'w9': 0.76}) | pass |

### Sync-lag tracking (#332): clients against the server

| run | profile | resyncs (clients) | resyncs (server, incl. alongside) | 4008 | 4010 | 4011 | 4012 | failed snapshot encodes | key-scope reset bytes (land-wide, includes the resyncs' key resets) | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | 448 | 448 | 0 | 150 | 0 | 0 | 0 | 2261915 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | 444 | 444 | 0 | 150 | 0 | 0 | 0 | 2223690 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | 448 | 448 | 0 | 150 | 0 | 0 | 0 | 2249895 | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | 0 | 0 | 0 | 0 | 150 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | 0 | 0 | 0 | 0 | 150 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | 0 | 0 | 0 | 0 | 150 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 521 | 529 | 0 | 220 | 0 | 0 | 0 | 2678510 | in flight at close: 8 of at most 223 (server 529 − clients 521; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 545 | 551 | 0 | 226 | 0 | 0 | 0 | 2779820 | in flight at close: 6 of at most 230 (server 551 − clients 545; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 503 | 510 | 0 | 221 | 0 | 0 | 0 | 2581935 | in flight at close: 7 of at most 225 (server 510 − clients 503; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | 0 | 0 | 0 | 0 | 1500 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | 0 | 0 | 0 | 0 | 1500 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | 0 | 0 | 0 | 0 | 1500 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 6265 | finding (1 resyncs) |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | 2794 | 4882 | 0 | 1238 | 335 | 0 | 0 | 20575296 | in flight at close: 2088 of at most 3441 (server 4882 − clients 2794; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | 2776 | 4839 | 0 | 1274 | 348 | 0 | 0 | 20533203 | in flight at close: 2063 of at most 3427 (server 4839 − clients 2776; at most one unacked resync per closed session; totals, not attributable per connection) |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | 2776 | 4818 | 0 | 1223 | 371 | 0 | 0 | 20342588 | fail (4010: log 1223, counter 1224) |

### Jitter with reordering

| run | profile | reordered data segments (%, per direction) |
|---|---|---|
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 16.13 down, 0.843 up |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 16.13 down, 0.843 up |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 16.13 down, 0.843 up |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 0.614 down, 0.386 up |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 0.614 down, 0.386 up |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 0.614 down, 0.386 up |

### Memory

| run | profile | peak RSS impaired (MiB) | RSS slope, last 30 s (MiB/s) | leak check | end RSS above P0 peak (MiB) | host TCP mem peak (pages) | server Send-Q peak (bytes) |
|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | 128.84 | 0.002 | pass | -4.0 | 1037 | 80602 |
| imp-20261110-noramp-sr-SR-r2 | SR | 133.7 | 0.009 | pass | -8.1 | 1038 | 99449 |
| imp-20261110-noramp-sr-SR-r3 | SR | 132.21 | 0.01 | pass | -10.0 | 786 | 75998 |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | 133.38 | 0.005 | pass | -5.3 | 1539 | 2790274 |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | 135.46 | 0.0 | pass | -3.3 | 1549 | 2784457 |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | 136.07 | 0.0 | pass | -6.7 | 1326 | 2808372 |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 133.95 | 0.013 | pass | -2.1 | 1030 | 3083082 |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 129.59 | 0.024 | pass | -11.5 | 801 | 2951899 |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 129.29 | 0.03 | pass | -8.9 | 1071 | 3053068 |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 139.24 | 0.005 | pass | 0.2 | 259 | 45220 |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 134.03 | 0.131 | pass | -1.1 | 3 | 53813 |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 137.28 | 0.001 | pass | -5.8 | 41 | 49049 |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | 130.27 | 0.027 | pass | 0.7 | 10962 | 27554921 |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | 128.07 | 0.034 | pass | -8.5 | 10327 | 27633629 |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | 130.5 | 0.01 | pass | 0.3 | 10988 | 27885101 |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 138.09 | 0.005 | pass | 3.8 | 1889 | 1510019 |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 137.64 | 0.001 | pass | 2.4 | 1870 | 1227871 |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 138.46 | 0.001 | pass | -0.5 | 1775 | 1221505 |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | 141.2 | -0.0 | pass | 3.0 | 1378 | 885594 |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | 140.15 | 0.0 | pass | 0.8 | 1242 | 888987 |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | 135.75 | -0.0 | pass | 0.9 | 1521 | 894494 |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 137.56 | 0.022 | pass | 1.9 | 84 | 57047 |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 135.16 | -0.008 | pass | -3.4 | 469 | 212538 |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 134.65 | 0.004 | pass | -4.1 | 97 | 53967 |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | 127.84 | 0.029 | pass | -1.7 | 46673 | 154032435 |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | 129 | 0.012 | pass | -5.2 | 45757 | 150649115 |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | 133.05 | 0.008 | pass | -2.3 | 44862 | 146802566 |

### Client-bound windows (excluded from isolation and recovery)

| run | profile | group | client-bound windows (ELU > 0.9) | largest span ELU per worker | largest window send-lag p99 (ms) | run-wide loop-delay p99 (ms) | gate check |
|---|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.243, w1 0.305, w2 0.266, w3 0.257, w4 0.259, w5 0.279, w6 0.277, w7 0.239, w8 0.266, w9 0.274 | 104.528564453125 | 1.56 | consistent |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.243, w1 0.305, w2 0.266, w3 0.257, w4 0.259, w5 0.279, w6 0.277, w7 0.239, w8 0.266, w9 0.274 | 93.6875 | 1.56 | consistent |
| imp-20261110-noramp-sr-SR-r1 | SR | impaired | baseline 0, impaired 1, recovery 2 | w0 0.757, w1 0.953 | 1617.4228515625 | 1.49 | consistent |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.207, w1 0.192, w2 0.22, w3 0.194, w4 0.201, w5 0.18, w6 0.194, w7 0.189, w8 0.203, w9 0.193 | 8.640380859375 | 1.42 | consistent |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.207, w1 0.192, w2 0.22, w3 0.194, w4 0.201, w5 0.18, w6 0.194, w7 0.189, w8 0.203, w9 0.193 | 8.36181640625 | 1.42 | consistent |
| imp-20261110-noramp-sr-SR-r2 | SR | impaired | baseline 0, impaired 1, recovery 2 | w0 0.986, w1 0.781 | 1553.737548828125 | 1.35 | consistent |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.186, w1 0.19, w2 0.204, w3 0.218, w4 0.203, w5 0.203, w6 0.185, w7 0.193, w8 0.18, w9 0.182 | 10.63525390625 | 1.46 | consistent |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.186, w1 0.19, w2 0.204, w3 0.218, w4 0.203, w5 0.203, w6 0.185, w7 0.193, w8 0.18, w9 0.182 | 13.111572265625 | 1.46 | consistent |
| imp-20261110-noramp-sr-SR-r3 | SR | impaired | baseline 0, impaired 1, recovery 0 | w0 0.939, w1 0.824 | 1555.1845703125 | 1.38 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.211, w1 0.18, w2 0.198, w3 0.192, w4 0.174, w5 0.184, w6 0.176, w7 0.233, w8 0.198, w9 0.211 | 12.538818359375 | 1.31 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.211, w1 0.18, w2 0.198, w3 0.192, w4 0.174, w5 0.184, w6 0.176, w7 0.233, w8 0.198, w9 0.211 | 23.47607421875 | 1.31 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.234, w1 0.248 | 33.12841796875 | 1.33 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.226, w1 0.203, w2 0.238, w3 0.224, w4 0.209, w5 0.227, w6 0.207, w7 0.203, w8 0.214, w9 0.206 | 17.5068359375 | 1.41 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.226, w1 0.203, w2 0.238, w3 0.224, w4 0.209, w5 0.227, w6 0.207, w7 0.203, w8 0.214, w9 0.206 | 18.322998046875 | 1.41 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.351, w1 0.348 | 36.45166015625 | 1.42 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.181, w1 0.174, w2 0.197, w3 0.266, w4 0.269, w5 0.176, w6 0.28, w7 0.176, w8 0.208, w9 0.19 | 12.1591796875 | 1.28 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.181, w1 0.174, w2 0.197, w3 0.266, w4 0.269, w5 0.176, w6 0.28, w7 0.176, w8 0.208, w9 0.19 | 20.931396484375 | 1.28 | consistent |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.246, w1 0.241 | 15.4091796875 | 1.28 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.171, w1 0.207, w2 0.173, w3 0.172, w4 0.175, w5 0.265, w6 0.177, w7 0.184, w8 0.296, w9 0.181 | 12.3203125 | 1.47 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.171, w1 0.207, w2 0.173, w3 0.172, w4 0.175, w5 0.265, w6 0.177, w7 0.184, w8 0.296, w9 0.181 | 39.144775390625 | 1.47 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.346, w1 0.384 | 28.94970703125 | 1.53 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.259, w1 0.253, w2 0.23, w3 0.234, w4 0.23, w5 0.303, w6 0.218, w7 0.243, w8 0.274, w9 0.201 | 18.853515625 | 1.51 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.259, w1 0.253, w2 0.23, w3 0.234, w4 0.23, w5 0.303, w6 0.218, w7 0.243, w8 0.274, w9 0.201 | 18.211669921875 | 1.51 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.405, w1 0.361 | 28.3828125 | 1.62 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.292, w1 0.174, w2 0.316, w3 0.182, w4 0.228, w5 0.309, w6 0.218, w7 0.315, w8 0.322, w9 0.186 | 68.869140625 | 1.42 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.292, w1 0.174, w2 0.316, w3 0.182, w4 0.228, w5 0.309, w6 0.218, w7 0.315, w8 0.322, w9 0.186 | 61.238037109375 | 1.42 | consistent |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.392, w1 0.447 | 74.71337890625 | 1.48 | consistent |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.306, w1 0.227, w2 0.209, w3 0.234, w4 0.257, w5 0.247, w6 0.238, w7 0.303, w8 0.355, w9 0.312 | 24.86328125 | 1.53 | consistent |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.306, w1 0.227, w2 0.209, w3 0.234, w4 0.257, w5 0.247, w6 0.238, w7 0.303, w8 0.355, w9 0.312 | 29.962890625 | 1.53 | consistent |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.321, w1 0.343 | 28.066650390625 | 1.62 | consistent |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.168, w1 0.174, w2 0.183, w3 0.191, w4 0.189, w5 0.164, w6 0.173, w7 0.203, w8 0.177, w9 0.231 | 5.700439453125 | 1.34 | consistent |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.168, w1 0.174, w2 0.183, w3 0.191, w4 0.189, w5 0.164, w6 0.173, w7 0.203, w8 0.177, w9 0.231 | 6.58056640625 | 1.34 | consistent |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.243, w1 0.25 | 8.73388671875 | 1.36 | consistent |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | healthy-mixed | baseline 0, impaired 0, recovery 0 | w0 0.183, w1 0.265, w2 0.186, w3 0.176, w4 0.17, w5 0.178, w6 0.252, w7 0.181, w8 0.182, w9 0.194 | 7.27880859375 | 1.41 | consistent |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | healthy-rooms | baseline 0, impaired 0, recovery 0 | w0 0.183, w1 0.265, w2 0.186, w3 0.176, w4 0.17, w5 0.178, w6 0.252, w7 0.181, w8 0.182, w9 0.194 | 10.373291015625 | 1.41 | consistent |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.249, w1 0.244 | 11.61328125 | 1.47 | consistent |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.324, w1 0.321, w10 0.294, w11 0.286, w2 0.262, w3 0.281, w4 0.302, w5 0.262, w6 0.267, w7 0.261, w8 0.279, w9 0.261 | 22.98779296875 | 2.17 | consistent |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.292, w1 0.367, w10 0.254, w11 0.295, w2 0.294, w3 0.298, w4 0.263, w5 0.281, w6 0.31, w7 0.283, w8 0.31, w9 0.287 | 39.76904296875 | 1.86 | consistent |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.291, w1 0.307, w10 0.299, w11 0.283, w2 0.338, w3 0.353, w4 0.301, w5 0.323, w6 0.282, w7 0.334, w8 0.308, w9 0.299 | 27.2880859375 | 1.69 | consistent |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.405, w1 0.426, w10 0.444, w11 0.394, w2 0.427, w3 0.41, w4 0.488, w5 0.409, w6 0.43, w7 0.368, w8 0.435, w9 0.418 | 58.28955078125 | 2.81 | consistent |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.253, w1 0.235, w10 0.254, w11 0.244, w2 0.258, w3 0.249, w4 0.246, w5 0.246, w6 0.26, w7 0.246, w8 0.253, w9 0.242 | 16.3603515625 | 1.99 | consistent |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | impaired | baseline 0, impaired 0, recovery 0 | w0 0.311, w1 0.267, w10 0.288, w11 0.291, w2 0.307, w3 0.296, w4 0.298, w5 0.29, w6 0.287, w7 0.273, w8 0.285, w9 0.298 | 17.216552734375 | 2.29 | consistent |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.342, w1 0.334, w10 0.378, w11 0.35, w2 0.346, w3 0.348, w4 0.346, w5 0.377, w6 0.391, w7 0.323, w8 0.338, w9 0.355 | 35.46240234375 | 2.58 | consistent |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.441, w1 0.514, w10 0.527, w11 0.475, w2 0.456, w3 0.477, w4 0.425, w5 0.43, w6 0.48, w7 0.494, w8 0.463, w9 0.521 | 78.28564453125 | 2.41 | consistent |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.222, w1 0.225, w10 0.224, w11 0.241, w2 0.25, w3 0.231, w4 0.226, w5 0.26, w6 0.221, w7 0.226, w8 0.242, w9 0.234 | 16.0458984375 | 2.12 | consistent |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.311, w1 0.268, w10 0.312, w11 0.29, w2 0.261, w3 0.248, w4 0.298, w5 0.301, w6 0.299, w7 0.252, w8 0.25, w9 0.267 | 21.2265625 | 1.98 | consistent |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.382, w1 0.366, w10 0.445, w11 0.441, w2 0.369, w3 0.365, w4 0.302, w5 0.324, w6 0.314, w7 0.372, w8 0.28, w9 0.358 | 51.1689453125 | 2.42 | consistent |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.234, w1 0.222, w10 0.222, w11 0.211, w2 0.211, w3 0.217, w4 0.216, w5 0.247, w6 0.201, w7 0.211, w8 0.224, w9 0.193 | 8.426025390625 | 1.94 | consistent |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | impaired | baseline 0, impaired 0, recovery 2 | w0 0.528, w1 0.597, w10 0.93, w11 0.475, w2 0.541, w3 0.489, w4 0.558, w5 0.903, w6 0.537, w7 0.576, w8 0.513, w9 0.582 | 262.260986328125 | 2.43 | consistent |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | impaired | baseline 0, impaired 0, recovery 2 | w0 0.908, w1 0.911, w10 0.718, w11 0.748, w2 0.845, w3 0.787, w4 0.795, w5 0.905, w6 0.893, w7 0.815, w8 0.926, w9 0.929 | 432.305908203125 | 1.94 | consistent |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | impaired | baseline 0, impaired 0, recovery 0 | w0 0.557, w1 0.72, w10 0.742, w11 0.898, w2 0.682, w3 0.88, w4 0.796, w5 0.836, w6 0.657, w7 0.737, w8 0.728, w9 0.76 | 431.29296875 | 2.15 | consistent |

### Client load (the gate: each run is refused over it)

| run | profile | workers' CPU demand, largest segment (% of the pinned client CPUs; under 70) | worker ELU, largest segment mean (time-weighted over the segment's spans, largest over workers; at most 0.5) | verdict |
|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | 49.8 (4 CPUs) | 0.234 | pass |
| imp-20261110-noramp-sr-SR-r2 | SR | 49.6 (4 CPUs) | 0.23 | pass |
| imp-20261110-noramp-sr-SR-r3 | SR | 48.5 (4 CPUs) | 0.222 | pass |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | 49.1 (4 CPUs) | 0.214 | pass |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | 49.1 (4 CPUs) | 0.218 | pass |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | 49.1 (4 CPUs) | 0.213 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | 49.4 (4 CPUs) | 0.222 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | 49.3 (4 CPUs) | 0.223 | pass |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | 49.8 (4 CPUs) | 0.22 | pass |
| imp-20261110-noramp-sweep-M-P0-r1 | P0 | 49.4 (4 CPUs) | 0.22 | pass |
| imp-20261110-noramp-sweep-M-P0-r2 | P0 | 48.7 (4 CPUs) | 0.212 | pass |
| imp-20261110-noramp-sweep-M-P0-r3 | P0 | 49.1 (4 CPUs) | 0.212 | pass |
| imp-20261110-noramp-sweep-U-BO75-r1 | BO75 | 54.8 (4 CPUs) | 0.191 | pass |
| imp-20261110-noramp-sweep-U-BO75-r2 | BO75 | 53.3 (4 CPUs) | 0.187 | pass |
| imp-20261110-noramp-sweep-U-BO75-r3 | BO75 | 53.0 (4 CPUs) | 0.181 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r1 | D50J10 (reordering) | 64.2 (4 CPUs) | 0.232 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r2 | D50J10 (reordering) | 63.2 (4 CPUs) | 0.215 | pass |
| imp-20261110-noramp-sweep-U-D50J10-r3 | D50J10 (reordering) | 63.3 (4 CPUs) | 0.217 | pass |
| imp-20261110-noramp-sweep-U-L5-r1 | L5 | 57.5 (4 CPUs) | 0.203 | pass |
| imp-20261110-noramp-sweep-U-L5-r2 | L5 | 57.6 (4 CPUs) | 0.212 | pass |
| imp-20261110-noramp-sweep-U-L5-r3 | L5 | 56.5 (4 CPUs) | 0.191 | pass |
| imp-20261110-noramp-sweep-U-P0-r1 | P0 | 54.0 (4 CPUs) | 0.184 | pass |
| imp-20261110-noramp-sweep-U-P0-r2 | P0 | 55.5 (4 CPUs) | 0.193 | pass |
| imp-20261110-noramp-sweep-U-P0-r3 | P0 | 54.5 (4 CPUs) | 0.187 | pass |
| imp-20261110-noramp-sweep-U-RATE-r1 | RATE | 57.8 (4 CPUs) | 0.208 | pass |
| imp-20261110-noramp-sweep-U-RATE-r2 | RATE | 57.6 (4 CPUs) | 0.205 | pass |
| imp-20261110-noramp-sweep-U-RATE-r3 | RATE | 58.4 (4 CPUs) | 0.211 | pass |

### Isolation (healthy groups, impaired segment)

| run | profile | group | statistic | value (ms) | P0 band (ms) | within |
|---|---|---|---|---|---|---|
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-mixed | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-mixed | gapP99 | 104 | 104 | yes |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-rooms | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sr-SR-r1 | SR | healthy-rooms | gapP99 | 104 | 104 | yes |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-mixed | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-mixed | gapP99 | 103 | 104 | yes |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-rooms | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sr-SR-r2 | SR | healthy-rooms | gapP99 | 103 | 104 | yes |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-mixed | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-mixed | gapP99 | 104 | 104 | yes |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-rooms | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sr-SR-r3 | SR | healthy-rooms | gapP99 | 103 | 104 | yes |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-mixed | inputP99 | 100 | 101 | yes |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-mixed | gapP99 | 103 | 103 | yes |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-rooms | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sweep-M-BO75-r1 | BO75 | healthy-rooms | gapP99 | 102 | 103 | yes |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-mixed | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-mixed | gapP99 | 103 | 103 | yes |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-rooms | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sweep-M-BO75-r2 | BO75 | healthy-rooms | gapP99 | 103 | 103 | yes |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-mixed | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-mixed | gapP99 | 102 | 103 | yes |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-rooms | inputP99 | 100 | 101 | yes |
| imp-20261110-noramp-sweep-M-BO75-r3 | BO75 | healthy-rooms | gapP99 | 102 | 103 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | inputP99 | 102 | 101 | no |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-mixed | gapP99 | 103 | 103 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | inputP99 | 100 | 101 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r1 | COMBO (reordering) | healthy-rooms | gapP99 | 103 | 104 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | inputP99 | 103 | 101 | no |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-mixed | gapP99 | 106 | 103 | no |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | inputP99 | 103 | 101 | no |
| imp-20261110-noramp-sweep-M-COMBO-r2 | COMBO (reordering) | healthy-rooms | gapP99 | 106 | 104 | no |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-mixed | gapP99 | 103 | 103 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | closes, unanswered | 0, 0 | 0, 0 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | inputP99 | 101 | 101 | yes |
| imp-20261110-noramp-sweep-M-COMBO-r3 | COMBO (reordering) | healthy-rooms | gapP99 | 103 | 104 | yes |

## Re-run of U-P0 and U-RATE with the close pairing (#490)

`RERUN=490` (run.sh): a calibration at the re-run's commit (`MODE=calibrate`), then U-P0 and U-RATE, three repeats each, interleaved (U-P0 then U-RATE in each repeat), ingested to `results/rerun-490/`. Its server logs `sessionOpened` and `syncLagCloseDecided` (#495) and its clients write one `socket` record per socket (#494), so criterion 2 pairs each server close with the client socket it was, and the sync-lag check names each decided close's session. Its runs record the analysis.py they are judged by (`meta.analysisSha256`), and `regenerate.py` judges them by that rule: the analysis.py at their commit, read from git and checked against the hash, so a later analysis.py change can't move these tables. A copy of the repository without its git history can't regenerate this section. It is its own set: nothing here is compared with the 48962fae tables above.

Provenance, from the results' meta: commit `03d6538110cb4ada93d0ccfde9e735d873cdfbeb`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

### Recovery (recoveryMs, from the lift)

| rooms | population | profile | group | median | per repeat |
|---|---|---|---|---|---|
| 300 | U | P0 | impaired | 0 | 0, 0, 0 |
| 300 | U | RATE | impaired | 6000 | 5000, 6000, 6000 |

### Per-session recovery (end of the recovery segment)

| run | profile | group | survived | rebuilt (firstSync) | not recovered | not recovered, by reason | verdict |
|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | impaired | 1500 | 0 | 0 | – | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | impaired | 8 | 1492 | 0 | – | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | impaired | 12 | 1488 | 0 | – | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | impaired | 3 | 1497 | 0 | – | pass |

### Closes and server causes (counts)

| run | profile | server-initiated (client) | pong timeout (server) | backlog 4008 (server) | stale (client) | stale rule | sendBufferedBytesMax |
|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | pass | 0 |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 1042 | 11 | 0 | 2024 | reported | 90294 |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 1140 | 15 | 0 | 1982 | reported | 0 |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 1108 | 11 | 0 | 2008 | reported | 0 |

### Every close has a cause (per session)

| run | profile | client closes | with server cause | client close, no cause | server close, no client close | joins without a server session | server closes during a join | never-joined server closes by code | causes | counter minus log | criterion 2 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | – | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 3066 | 3066 | 0 | 0 | 0 | 0 (pongTimeout 11) | 1001 ×11 | connectionLost 1492, serverClose 1574 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 3122 | 3122 | 0 | 0 | 0 | 0 (pongTimeout 15) | 1001 ×15 | connectionLost 1543, serverClose 1579 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 3116 | 3116 | 0 | 0 | 0 | 0 (pongTimeout 11) | 1001 ×11 | connectionLost 1568, serverClose 1548 | pongTimeoutCloses +0, sendBacklogCloses +0 | pass |

### Server closes of sockets the client had given up on (#490)

| run | profile | liveness closes of abandoned sockets | liveness closes of phaseEnd sockets | server-only closes left | of those, no client socket | sockets left without a record | verdict |
|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | pongTimeout 1001 ×11, serverClose 4011 ×8 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | pongTimeout 1001 ×15, serverClose 4011 ×3 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | pongTimeout 1001 ×11, serverClose 4011 ×5 | 0 | 0 | 0 | 0 | pass |

### Every room converged (after recovery)

| run | profile | rooms checked before the deadline | converged | converged late (≤ 5 s) | mismatched | missing clients | inconclusive | errors | survivors converged | reconnected converged | check (s) | criterion 3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.9 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.8 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 600/600 | 0/0 | 3.7 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 2/2 | 598/598 | 3.9 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 3/3 | 597/597 | 3.9 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 300/300 | 300 | 0 | 0 | 0 | 0 | 0 | 2/2 | 598/598 | 3.9 | pass |

### Profiles without server closes (P0)

| run | profile | server-decided closes (log) | server-initiated closes (clients) | unanswered outside the impaired segment | verdict |
|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 0 | 0 | 0 | pass |

### RATE and COMBO under sync-lag tracking

| run | profile | group | sessions resynced | resyncs (impaired) | apply → first resync (ms, client arrival) | 4010 (impaired) | rejoins | rejoins per session per min | full views' share of the downstream | calibration staleness | tail events (last 10 s) | not joined or converged at the end | findings | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | impaired | 1056/1500 | 2194 | 4453–59889 | 1129 | 2878 | 1.917 | impaired 3.8%, recovery 0.3% | 1.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×337 (workers' max ELU {'w0': 0.983, 'w1': 0.663, 'w10': 0.805, 'w11': 0.849, 'w2': 0.757, 'w3': 0.875, 'w4': 0.544, 'w5': 0.973, 'w6': 0.983, 'w7': 0.986, 'w8': 0.714, 'w9': 0.969}) | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | impaired | 1041/1500 | 2111 | 4418–60021 | 1102 | 2943 | 1.96 | impaired 3.8%, recovery 0.3% | 1.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×377 (workers' max ELU {'w0': 0.923, 'w1': 0.827, 'w10': 0.9, 'w11': 0.989, 'w2': 0.987, 'w3': 0.889, 'w4': 0.975, 'w5': 0.799, 'w6': 0.943, 'w7': 0.639, 'w8': 0.81, 'w9': 0.975}) | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | impaired | 995/1500 | 1993 | 4283–60044 | 1084 | 2945 | 1.961 | impaired 3.7%, recovery 0.3% | 1.1% (down), up 97500 B/s unshaped | 0 | 0 | 4011 ×378 (workers' max ELU {'w0': 0.826, 'w1': 0.92, 'w10': 0.887, 'w11': 0.801, 'w2': 0.848, 'w3': 0.97, 'w4': 0.949, 'w5': 0.977, 'w6': 0.929, 'w7': 0.762, 'w8': 0.975, 'w9': 0.953}) | pass |

### Sync-lag tracking (#332): clients against the server

| run | profile | resyncs (clients) | resyncs (server, incl. alongside) | 4008 | 4010 | 4011 | 4012 | failed snapshot encodes | key-scope reset bytes (land-wide, includes the resyncs' key resets) | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 2796 | 4845 | 0 | 1237 | 345 | 0 | 0 | 20268411 | in flight at close: 2049 of at most 3408 (server 4845 − clients 2796; at most one unacked resync per closed session; totals, not attributable per connection) |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 2725 | 4863 | 0 | 1202 | 380 | 0 | 0 | 20468820 | in flight at close: 2138 of at most 3433 (server 4863 − clients 2725; at most one unacked resync per closed session; totals, not attributable per connection) |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 2591 | 4801 | 0 | 1170 | 383 | 0 | 0 | 20504883 | in flight at close: 2210 of at most 3430 (server 4801 − clients 2591; at most one unacked resync per closed session; totals, not attributable per connection) |

### Sync-lag close decisions per session (#490)

| run | profile | code | decided | landed | superseded (by cause) | no close | verdict |
|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 4010 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 4011 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 4012 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 4010 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 4011 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 4012 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 4010 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 4011 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 4012 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 4010 | 1238 | 1237 | connectionLost 1 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 4011 | 345 | 345 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 4012 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 4010 | 1202 | 1202 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 4011 | 380 | 380 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 4012 | 0 | 0 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 4010 | 1171 | 1170 | connectionLost 1 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 4011 | 383 | 383 | 0 | 0 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 4012 | 0 | 0 | 0 | 0 | pass |

### Memory

| run | profile | peak RSS impaired (MiB) | RSS slope, last 30 s (MiB/s) | leak check | end RSS above P0 peak (MiB) | host TCP mem peak (pages) | server Send-Q peak (bytes) |
|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 136.66 | 0.008 | pass | -5.0 | 298 | 72161 |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 137.8 | 0.001 | pass | 4.9 | 148 | 58336 |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 136.25 | 0.006 | pass | -5.5 | 271 | 77152 |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 127.79 | 0.012 | pass | -5.1 | 46857 | 154819702 |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 132.48 | 0.007 | pass | -3.8 | 45959 | 151579956 |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 128.45 | 0.02 | pass | -5.9 | 46062 | 153351987 |

### Client-bound windows (excluded from isolation and recovery)

| run | profile | group | client-bound windows (ELU > 0.9) | largest span ELU per worker | largest window send-lag p99 (ms) | run-wide loop-delay p99 (ms) | gate check |
|---|---|---|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.234, w1 0.228, w10 0.219, w11 0.221, w2 0.229, w3 0.226, w4 0.217, w5 0.271, w6 0.227, w7 0.219, w8 0.222, w9 0.266 | 9.665283203125 | 2.21 | consistent |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.223, w1 0.217, w10 0.216, w11 0.249, w2 0.234, w3 0.235, w4 0.222, w5 0.231, w6 0.223, w7 0.226, w8 0.218, w9 0.233 | 9.972900390625 | 2.53 | consistent |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | impaired | baseline 0, impaired 0, recovery 0 | w0 0.217, w1 0.217, w10 0.214, w11 0.221, w2 0.217, w3 0.215, w4 0.217, w5 0.235, w6 0.22, w7 0.217, w8 0.211, w9 0.228 | 27.106201171875 | 1.98 | consistent |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | impaired | baseline 0, impaired 0, recovery 2 | w0 0.983, w1 0.663, w10 0.805, w11 0.849, w2 0.757, w3 0.875, w4 0.544, w5 0.973, w6 0.983, w7 0.986, w8 0.714, w9 0.969 | 443.779541015625 | 2.22 | consistent |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | impaired | baseline 0, impaired 0, recovery 2 | w0 0.923, w1 0.827, w10 0.9, w11 0.989, w2 0.987, w3 0.889, w4 0.975, w5 0.799, w6 0.943, w7 0.639, w8 0.81, w9 0.975 | 298.556884765625 | 2.12 | consistent |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | impaired | baseline 0, impaired 0, recovery 2 | w0 0.826, w1 0.92, w10 0.887, w11 0.801, w2 0.848, w3 0.97, w4 0.949, w5 0.977, w6 0.929, w7 0.762, w8 0.975, w9 0.953 | 338.74755859375 | 2.05 | consistent |

### Client load (the gate: each run is refused over it)

| run | profile | workers' CPU demand, largest segment (% of the pinned client CPUs; under 70) | worker ELU, largest segment mean (time-weighted over the segment's spans, largest over workers; at most 0.5) | verdict |
|---|---|---|---|---|
| rerun490-20261111T035144Z-U-P0-r1 | P0 | 54.2 (4 CPUs) | 0.183 | pass |
| rerun490-20261111T035144Z-U-P0-r2 | P0 | 54.6 (4 CPUs) | 0.187 | pass |
| rerun490-20261111T035144Z-U-P0-r3 | P0 | 53.1 (4 CPUs) | 0.179 | pass |
| rerun490-20261111T035144Z-U-RATE-r1 | RATE | 57.0 (4 CPUs) | 0.205 | pass |
| rerun490-20261111T035144Z-U-RATE-r2 | RATE | 56.9 (4 CPUs) | 0.206 | pass |
| rerun490-20261111T035144Z-U-RATE-r3 | RATE | 57.8 (4 CPUs) | 0.207 | pass |

## The #490 re-run's provenance and stationarity

The commit, toolchain versions and analysis hash below are in the results' meta. The GameServer binary's sha256, the per-second host sampling and the stationarity verdicts come from the host's records; they aren't in the JSON (`meta.gameserverBin` is null: run.sh built the binary).

- **Runs:** the calibration `cal-rerun490-20261111T035144Z` (U-P0 and M-P0, `MODE=calibrate`: U-RATE `49194516bit`, limits `2049:10000`, against the 48962fae set's `49257701bit`, `2052:10000`), then the sweep `rerun490-20261111T035144Z` (`RERUN=490 CELLS="U-P0 U-RATE"`), on 2026-11-11, both exit 0, under one lock window.
- **Build:** commit `03d6538110cb4ada93d0ccfde9e735d873cdfbeb` (#494 merged), a fresh clone with no build cache, clean tree. run.sh built GameServer (release; sha256 `76accba1bf619b9e6f04aad89fad04e16536ba54e6e364689181a668fa0caec1`, the same after the sweep) and ws-loadtest. Swift 6.2.4 (`swift-6.2.4-RELEASE`) in the `swift:6.2.4-noble` image, Node v24.22.2.
- **Host:** AMD Ryzen 5 7600X, Windows with WSL2, kernel `6.18.58.1-microsoft-standard-WSL2` (the 48962fae set ran on `6.18.54.1`). The server is pinned to CPUs 0–7 and the clients to 8–11. The sync-path variables were unset for every run.
- **Host activity:** sampled once per second through both steps. The page-out rule found no window with pages output, and the memory stop never fired. Windows Update, Delivery Optimization, Update Orchestrator and BITS were stopped before the steps and after each.
- **The analysis rule:** every run records `analysisSha256` `94c14f45e7116925e572f6df7b7d181a586191176ee9aebcad64380e4a8d28bd`, this commit's analysis.py; `regenerate.py` refuses another.
- **Stationarity:** `stationarity.py` at `03d65381`, run by the host on all 8 run directories (the calibration's two included): **8 STATIONARY**, 0 not. run.sh at this commit doesn't run it.
- **What differs from the 48962fae set:**
  - the server code differs only by #495's two lifecycle-log lines (`sessionOpened`, `syncLagCloseDecided`);
  - the client writes #494's `socket` records, and since #461 each ws-loadtest worker reads its event-loop utilization every 500 ms (`client-elu.ts`), client work the old set didn't do;
  - since #489, `cell.py` unsets, records and refuses the sync-path switches, a check the old set didn't run;
  - neither #461 nor #489 changes the server;
  - the kernel differs (6.18.58.1 against 6.18.54.1), and the calibration was taken again.
- **Raw data:** one gzipped tar per run directory, and the sweep's and calibration's records, archived outside this repository. `results/rerun-490/MANIFEST` lists each one's sha256, size and name.

## Conclusion

From the Results at `48962fae` (27 runs: 300 rooms, 3 repeats per cell; netem profiles on one
host, not any real network):

1. **Backlog:** the server's Send-Q peak is 45,220–212,538 bytes under P0. SR's (75,998–99,449)
   stays inside that range; the other profiles raise it, to about 0.89 MB (L5), 1.2–1.5 MB
   (D50J10), 2.8 MB (M-BO75), 3.0 MB (COMBO), 27.6–27.9 MB (U-BO75) and 146.8–154.0 MB (RATE). Peak RSS stays at 127.84–141.2 MiB, and the leak check passes in every run. The
   tables give input latency for the healthy groups only (item 4), not for the impaired ones.
2. **Recovery** (median recoveryMs from the lift, impaired group): P0 0, D50J10 and L5 1000, SR
   2000, U-BO75 3000, RATE 6000, M-BO75 7000, COMBO 8000. Single repeats spread wider: RATE r1
   24000 (median 6000), L5 r1 10000 (median 1000), COMBO r3 10000 (median 8000). At the end of the recovery segment every session survived or was rebuilt by a
   firstSync; none was left unrecovered.
3. **Convergence:** every room converged in every run, 300/300, with 0 mismatched.
4. **Healthy clients:** beside the slow readers (SR), the healthy sessions got no resync and no
   server close, and the healthy groups' isolation statistics stay within P0's band in every SR
   and BO75 run. Under COMBO, 5 of 18 (reported, not gated) are just outside it (inputP99 102–103
   ms against 101, gapP99 106 against 103–104).

**Failed criteria:** under RATE, "every close has a cause" fails in all 3 repeats (16, 9 and 11
server closes with no client close), and RATE r3's sync-lag check fails (4010: log 1223, counter
1224). Their cause is diagnosed from the archived raw data (#490). Under RATE's tail-dropping
downstream queue, a client that gave up on a reconnect attempt couldn't get its FIN out (the
server's ACKs were lost), so the server closed those sessions by its liveness timers, and the
client had no close to record. The 4010 counter counts decisions, one of which a connection loss
superseded before its close landed. The verdicts above stand. The re-run section above judges U-P0
and U-RATE again, with the logs that pair each close. There, criterion 2 passes in every RATE repeat
(3,066, 3,122 and 3,116 client closes, each with its server cause). The server's liveness closes
(pongTimeout 11, 15, 11; 4011 8, 3, 5) all pair with sockets the client had given up on, and no
server-only close is left. The sync-lag check finds no mismatch (its RATE verdicts report the
resyncs in flight at close): every counter equals its decisions, 1 of 1,238 and 1 of 1,171 decided
4010 closes were superseded by a connection loss, and the rest landed. Every session recovered, and
every room converged.

**Findings** (reported, not gated): L5 r3's sync-lag check reads "finding (1 resyncs)", and RATE's
impaired groups got 4011 ×332, ×347 and ×369 in r1–r3, with the load clients' workers' max ELU at
0.93, 0.929 and 0.898.

## Caveats

**Fixed:**
- messagepack encoding;
- Hero Defense at 1 PlayAction and 1 MoveTo per player per second (`cell.py` runs every load client with `--move-to-rate 1`: each MoveTo sets the player's target to a random point in the world, so players move; `--input-latency on` times each move until a frame shows it);
- 5 players per room;
- the server's bounds at their defaults: backlog 8 MiB / 30 s, ping 30 s, pong 20 s;
- sync-lag tracking at its defaults: resync after 3 s of lag, ack timeout 10 s, ack freshness 2 s, slow consumer at 3 resyncs in 60 s (recorded in `params.syncLag`, the variables unset in `meta.syncLagEnv`). A server built before the close grace of #339 closes a 4010, 4011 or 4012 session as soon as the close frame is written; from #339 on it keeps the channel open for up to 2 s (`closeGraceMs`, `SYNC_LAG_CLOSE_GRACE_MS`), so the client sees the close code rather than 1006 more often and the close ends later. Runs from either side of that change differ there;
- the load client's reconnect timing at ws-loadtest's defaults: 1000 ms between attempts, 5000 ms per attempt (`params.reconnectDelayMs`, `params.reconnectAttemptTimeoutMs`);
- the impaired window runs with sync-lag tracking at its defaults (resyncs, 4010 and rejoins under the throttle); it is not comparable with sets recorded before tracking; the recovery criterion and aggregate delivered bytes are;
- in-turn sync on, the shipped default: `cell.py` starts the server without `IN_TURN_SYNC` (or any other sync-path switch; "The sync path" above);
- one host, with server and clients on separate pinned CPUs;
- one load point, 300 rooms.

**The spawn ramp, from the commit after the d8321fde set:** `cell.py` starts the server with `HERO_DEFENSE_SPAWN_RAMP_TICKS=0` (`params.spawnRampTicks`; `meta.spawnRampTicksEffective` is the value the server reported). Every land spawns at Hero Defense's final rate from its first tick, so its live monster count is at its plateau before the baseline, and the scenarios' warm-up is 30 s (it was 15). The timeline in land age: the lands start about 1 s into the warm-up (the #425 diagnostic: 14.1 s before a 15 s warm-up's end, within 1.5 s of each other), so with the 30 s warm-up the baseline covers land age about 29–59 s, the impaired segment about 59–119 s and recovery about 119–209 s (60 s-impaired cells). Without the ramp the rules model reaches the monster plateau at land age about 12 s, about 17 s before the baseline, and the base reaches 0 at land age about 48–59 s: late in the baseline or at the apply. Its health is clamped at 0 and play goes on (the game has no game over), so the impaired and recovery segments run with a dead base, which a real game wouldn't allow; whether it dies in the baseline or at the apply, the monster load doesn't change with it (the confirmation run's land-stats give the measured times). `stationarity.py` checks a run's live monster count is stationary from the baseline's start to the recovery's end (per-10 s medians over lands: coefficient of variation at most 0.10, none more than 20 % from their mean, the last third's median within 10 % of the first third's, and the ramp 0 in params and from the server), and exits 1 when it isn't; a plateau reached later than the model's would fail it. It runs in the procedure, not in run.sh: on the confirmation run's directory before the sweep, and on every run directory of the sweep before its data commit (`python3 stationarity.py data/<run-id>`); a run it refuses isn't committed. The published set at d8321fde ran the game's own 3000-tick ramp.

**Host activity during the 48962fae set** (UTC 2026-11-10, from the measurement host's notes). None of it stopped a run, and every verdict above is the tables'.
- **Windows services.** Update Orchestrator (UsoSvc), Windows Update (wuauserv) and Delivery Optimization (DoSvc) were stopped before the set; Windows trigger-started each during it, each in its own process. UsoSvc started at 06:47:21Z during U-L5-r1 and ran through the rest of the set, 0.20 s of CPU in all. wuauserv started at 08:40:26Z during M-COMBO-r2, used 2.30 s of CPU and stopped by itself before the SR runs ended. DoSvc started at 08:58:12Z during M-BO75-r3 and ran through the rest, 0.95 s of CPU. No service was stopped mid-measurement.
- **Page-outs.** The page-out rule (nonzero pages output per second in a run's window from server start to teardown) flagged two runs. M-BO75-r3: 31.3 pages/s in the 1 s window from 08:59:32Z, with host CPU at 80.2 % that second against 60–70 % around it; that window holds the run's largest healthy RTT p99 of the impaired segment, 9.90 ms (healthy-rooms) and 9.32 ms (healthy-mixed), against about 3–5 ms in the neighbouring seconds, and DoSvc had started 80 s before. SR-CAL: 128.9 and 606.3 pages/s at 09:11:03Z and 09:11:07Z, in its last 10 s before teardown, as the host's commit charge rose from 55.5 % to 58.5 %; SR-CAL is the slow-reader calibration and isn't in the tables. M-BO75-r3 is within r1 and r2's spread on every criterion and on the RTT maxima, and is kept. The memory stop never fired.
- **Residual host load early in the sweep.** Host CPU less the server's and the clients' (in core-%), per sweep run over baseline to recovery: median 82.5, MAD 3.6. The first four runs (U-P0-r1, U-D50J10-r1, U-L5-r1, U-RATE-r1, 06:34–06:56Z) were above the median plus 3 MAD, at 104–107. The first two precede UsoSvc's start, and UsoSvc used 0.20 s of CPU in all, so this is host load early in the sweep, not that service. From U-BO75-r1 on it was 63–88, and 79–86 in the M runs, which overlap all three services.
- **Single-second RTT p99 maxima above the cell's other repeats.** M-COMBO-r2's healthy groups in the impaired segment: 210.2 ms (healthy-rooms) and 207.7 ms (healthy-mixed) at 08:41:06Z, then 98 and 71 ms (r1 24.2, r3 16.4 ms); 40 s after wuauserv started inside that run, with host CPU at 66.7 % that second and 85.5 % the next, and no page-out. U-L5-r2's baseline: 306.9 ms at 07:11:57Z, its first second (r1 33.8, r3 30.1 ms). U-P0-r2's recovery: 333.8 ms at 07:08:05Z, the first second after the lift (r1 159.8, r3 46.4 ms). All three overlap UsoSvc. Every criterion verdict for these runs passes, and they're kept.

**Observed, after every measured window:** after the convergence check, the live monster count per land falls from 30 to about 23–24. In all 27 runs it first reads 25 or less 2.0–3.5 s after the check ends, and the check stops every client's sends as it starts, so every player has stopped moving before the check ends; spawns stay at 6.68 per land per second, kills fall from 4.33 to 3.79 and arrivals at the base rise from 2.34 to 2.89 (medians over the runs, the 30 s before the check against 10–40 s after it). Ruled out: a deterministic keeper test (`HeroDefenseFreezeResumeTests`, one land) shows a freeze and resume, and PlayActions, leave a land's trajectory unchanged; and every land keeps its 5 players through the drop (`land-stats.jsonl`: until 52.5–58.4 s after the check ends). **Explained: the MoveTo stop** (#469). A second deterministic keeper test (`HeroDefenseMoveToStopTests`, four lands, seeded MoveTo at 1/s per player) reproduces it from the stop alone: stopped at the tick the check stops the clients, each land has 22–25 live against 29–30 when its players keep moving, with kills down (3.2–3.9/s against 4.0–4.5) and arrivals up (2.8–3.4/s against 2.1–2.6). With MoveTo its level before the stop is the run's 30 (28–31), where the first test's players stood still at 34–37. So the drop is the game's response to the players stopping, not the convergence check's freeze. It stays at about 23–24 until the run ends; in its last 3–8 one-second lines, once every land's players have left (0), it reads 31–35.

**Known limitation of the d8321fde set:** measured before f90471d4, so reconnected sessions sent no inputs in ws-loadtest's spread and event send modes (#422). This affects the impaired groups that reconnected: every session of SR and BO75, and 652–655 of RATE's 1500. Their recovery sends, RTT samples, unanswered counts and upstream bytes after the reconnects come only from the sessions that never reconnected, and their group recoveryMs is unmeasured. COMBO's impaired group and every healthy group didn't reconnect. The mixed-room healthy groups of SR and M-BO75 are measured, but at reduced room input load, against P0's band from full-load rooms. Per-session recovery reads received updates and firstSyncs, so it is unaffected.

**Observed, not explained:** in every run of the d8321fde set, P0 included, the healthy groups' and U's impaired group's RTT p99 rises over the recovery segment. Its median is about 2.0 ms in the baseline and 3.5–6.9 ms in the recovery's last 10 s. recoveryMs is read from the first run of five in-band windows after the lift, so it doesn't show this rise. M-BO75 r1's healthy groups have no such run: 4 and 5 of their 90 recovery windows are healthy, none five in a row, and every window had enough inputs sent. So their "not recovered" is a band result, not too few inputs. r2 and r3 start in band and read 1000. r1's client figures are a little higher than r2's and r3's, and inside the client-bound gate: client CPU max 47.0 % (42.2 and 42.6 %), client ELU max 0.185 (0.167, 0.169), loop delay p99 1.1 ms (0.99, 1.01).

**Not covered:**
- real WAN paths or measured traces;
- per-client independent netem links: per-client conditions are covered only by the slow reader;
- session resumption by the same player;
- other kernels' TCP stacks;
- clients on separate machines.

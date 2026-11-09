# Network impairment under multi-room load

Status: **tooling only, no runs yet.** The design, with every metric's semantics and the pass criteria, is `Notes/plans/2026-11-07-network-impairment-experiment-design.md`.

`regenerate.py` already builds these tables, tested on synthetic runs in `test_analysis.py`:
- `recoveryMs` per group, against the cell's P0 band, with each P0 repeat tested against the other two;
- per-session recovery, each session against its own baseline, with survivors and firstSync rebuilds counted apart. A session has recovered after the lift when all of these hold:
  - its state converged: its land converged in the convergence check, or its own connection did;
  - over the last 10 s of the recovery segment, it was joined and received an update in every 1 s slot. If it reconnected, a firstSync rebuilt it;
  - its update-gap p99 over those 10 s is at most its own baseline gap p99 plus one sync interval (100 ms).

  A session with no baseline gaps can't be compared, so it fails. The P0 repeats are checked the same way, as the control. The criterion sees gaps, not delay: a constant added delay (D50J10) shifts every arrival by the same amount and leaves the gaps as they were. Delay shows in the latency rows;
- closes and server causes, as counts;
- every close has a cause (§ 7 criterion 2), per session. Each client close is paired with its session's `sessionClosed` cause from `land-lifecycle.jsonl`. A connection's join sample carries the server's playerID (`serverPlayer`), which maps it to a `sessionJoined` line in its land. A close belongs to the connection's latest join before it. The criterion fails on a client close with no server cause, on a server-decided close (`pongTimeout`, `backlogBytes`, `backlogUnwritable`, `serverClose`, `error`) anywhere in the run's log that no client close matches, on a join that maps to no server session, or when a profile counter is below the log's count of its causes (a counter above it is reported);
- the per-profile criteria (§ 7) for the sessions each impaired group had open at the apply. In BO75, each must be closed on the server by a pong timeout or the backlog bound before the end of recovery and rebuilt by a firstSync within 60 s of the lift, and every stale close in the run must match a pong or backlog close of its session. In SR, each slow reader must be closed with 4008 (`backlogBytes` or `backlogUnwritable`) and rebuilt by a firstSync by the end of recovery. A group with fewer such sessions than its target fails;
- isolation of the healthy groups;
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
  - `MODE=calibrate bash run.sh` runs U-P0 and M-P0 at the current commit and writes `data/<RUN_ID>/calibration.json`, which a sweep reads with `CALIBRATION=<file>`.
  - The fixed limits and the jitter cells' reordering, which doesn't depend on payload size, carry over.
- **`MEASURING.lock` is the host agent's.** `run.sh` doesn't create, remove or read it.
- **The host procedure:** three RUN_IDs under one held lock, each a whole invocation, and never `OVERWRITE`, run from this topic's directory (`cd deep-research/network-impairment-2026-11`). `run.sh` resolves a relative `CALIBRATION` (and every other file-valued input) against the directory it was started from and refuses a missing file before any run; before that, a relative path was read from `Examples/GameDemo`, where `cell.py` runs, and failed there:
  1. `MODE=calibrate RUN_ID=<CAL> bash run.sh` exits 0.
  2. `CALIBRATION=data/<CAL>/calibration.json RUN_ID=<SWEEP> bash run.sh` runs U, M and SR-CAL. It exits **3** when it stops before SR as planned: every earlier run passed and `SR_PAUSE` isn't set.
  3. `SR_PAUSE=$(python3 srpause.py data/<SWEEP>-SR-CAL)`, stopping if it refuses, then `CALIBRATION=… CELLS=SR SR_PAUSE=$SR_PAUSE RUN_ID=<SR> bash run.sh` exits 0.

  Exit 1 is a failure. Exit 2 is a bad option, including `CELLS` naming SR without `SR_PAUSE`. Exit 3 is only the whole plan's stop before SR. `CELLS=`/`REPEATS=` per cell are for smokes only.
- **`srpause.py`** prints SR's pause: the slow readers' maximum time-to-unwritable in SR-CAL, plus 30 s plus 10 s (§ 4). Each slow reader's onset is its first backlog close during the pause, minus the 30 s unwritable timer for a `backlogUnwritable` close, or the close itself for `backlogBytes`. It refuses, with a non-zero exit and the reason, when an input is missing, when no slow reader became unwritable, when fewer did than the run's slow readers, or when an onset falls before the pause.
- **The pre-sweep smoke** checks the mechanics only, so it passes the 2026-11-07 COMBO settings as overrides: `ROOMS=10 CELLS=M-COMBO REPEATS=1 RATE=4047216bit LIMITS=168:10000 RUN_ID=smoke-m-combo bash run.sh`. With `DRY_RUN=1`, the same line prints every command first.
- **The client must not be the bottleneck** (`clientload.py`; design § 2). Each run's `meta` records two figures per segment (baseline, impaired, recovery), from every worker's `loop` spans:
  - `clientCpu`: the workers' CPU demand on the pinned client CPUs, against the recorded mask. Only the worker processes are measured: not each instance's parent process, nor the sockstat and backlog samplers on the same CPUs.
  - `clientElu`: each worker's mean ELU, the largest over workers.

  Every worker of every instance (its configured count) must cover each segment for at least 95 % of it. A worker missing from the start, or one whose process or sampler stopped mid-run, makes both figures missing (`clientLoadMissing` names it), so it can't drop out and understate the demand.

  `stopcheck.py` stops the sweep, and `regenerate.py` refuses the run, when any segment's workers' CPU demand reaches 70 %, when any worker's ELU is over 0.5, or when a figure is missing (an unpinned run included). A demand over 100 % is reported as a broken measurement.
- **When the sweep stops** (`stopcheck.py`, after every run): on a missing input in any run, and on any hard-criterion failure in a P0 run (§ 8), the per-session verdict included: each session is held to its own baseline, so a P0 that fails it is an unhealthy control, and the sweep doesn't run past it.
- **Smoke runs stay out of the tables.** A run with calibration overrides (`RATE`, `LIMITS`, `JITTER_REORDERS`, `REORDERED_PCT`; the documented smoke line) is ingested into its own `data/<run-id>/result.json`, which is ignored, never into `results/`. Its stop check reads it from there, so the smoke can't dirty the tree or reach the tables. `INGEST=0` skips ingest and the stop check altogether. As a backstop, `regenerate.py` and `stopcheck.py` refuse a run with calibration overrides, a test hook, a sweep that didn't build (`BUILD=0`), or a dirty tree (`git.dirty` other than false).
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

_No runs yet._

## Conclusion

None yet: no runs.

## Caveats

**Fixed:**
- messagepack encoding;
- Hero Defense at 1 action/s;
- 5 players per room;
- the server's bounds at their defaults: backlog 8 MiB / 30 s, ping 30 s, pong 20 s;
- in-turn sync as the baseline rerun ran it;
- one host, with server and clients on separate pinned CPUs;
- one load point, 300 rooms.

**Not covered:**
- real WAN paths or measured traces;
- per-client independent netem links: per-client conditions are covered only by the slow reader;
- session resumption by the same player;
- other kernels' TCP stacks;
- clients on separate machines.

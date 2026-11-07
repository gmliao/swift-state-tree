# Network impairment under multi-room load

Status: **tooling only, no runs yet.** The design, with every metric's semantics and the pass criteria, is `Notes/plans/2026-11-07-network-impairment-experiment-design.md`.

`regenerate.py` already builds these tables, tested on synthetic runs in `test_analysis.py`:
- `recoveryMs` per group, against the cell's P0 band, with each P0 repeat tested against the other two;
- per-session recovery: survivors and firstSync rebuilds counted apart, against the per-session band;
- closes and server causes, as counts;
- every close has a cause (§ 7 criterion 2), per session. Each client close is paired with its session's `sessionClosed` cause from `land-lifecycle.jsonl`. A connection's join sample carries the server's playerID (`serverPlayer`), which maps it to a `sessionJoined` line in its land. A close belongs to the connection's latest join before it. The criterion fails on a client close with no server cause, on a server-decided close (`pongTimeout`, `backlogBytes`, `backlogUnwritable`, `serverClose`, `error`) anywhere in the run's log that no client close matches, on a join that maps to no server session, or when a profile counter is below the log's count of its causes (a counter above it is reported);
- isolation of the healthy groups;
- memory: the RSS leak check against P0's slope, and the peaks of RSS, host TCP memory and the server's Send-Q.

A missing input fails the criterion that needs it, as "fail (missing: ...)": the lifecycle log, a profile covering under 95 % of the run's windows, a group's worker files, a group short of its target joins (ingest records each group's `manifest`), or a missing or zero `sendTargetPerS`. Without its P0 control a per-session or recovery check fails as "fail (no control)". SR's control is M's P0.

**Still to come:** convergence.

## Question

When the client–server network is delayed, jittered, lossy, throttled or cut for a while, what happens to the server?

1. How far do input-to-visible latency and the server's send backlog grow?
2. How long does each take to come back after the impairment ends?
3. Does every client end in the server's state?
4. Are clients whose own network is fine affected, in the same room or in other rooms?

The answers cover the synthetic conditions tested here, netem profiles on one host. They are not a claim about any particular real network.

## Environment

To be filled from the runs' `meta`:
- the Linux container and kernel;
- the Swift toolchain (pinned 6.2.4) and node versions;
- the git SHA;
- the CPU pinning of server, clients and samplers.

## Command(s)

Per run, from `Examples/GameDemo/ws-loadtest`, as root in the measurement container.

1. **Topology:** run once per run. `--with-good` is for populations M and SR.

   ```
   bash scripts/impair.sh setup --limit-down <N> --limit-up <N> [--with-good]
   ```

2. **The server, in the server namespace:**

   ```
   TRANSPORT_PROFILE_JSONL_PATH=<run>/profile.jsonl LAND_LIFECYCLE_LOG_PATH=<run>/land-lifecycle.jsonl \
     LOG_LEVEL=error GameServer &
   ```

3. **One client instance per client namespace:**

   ```
   ip netns exec lt-client bash scripts/run-ws-loadtest.sh --external-server <pid> \
     --external-profile <run>/profile.jsonl --samples-dir <run>/samples/lt-client \
     --stale-after 10 --reconnect on-server-close ...
   ```

4. **The impairment, at the timeline's offsets:**

   ```
   bash scripts/impair.sh schedule <profile> --at <epoch ms> --for <s> --timeline <run>/impairment-timeline.json
   ```

5. **Afterwards:** `bash scripts/impair.sh teardown`.

**Analysis:**

```
python3 analysis.py ingest data/<run-id>      # -> results/<run-id>.json
python3 regenerate.py                         # tables
python3 regenerate.py --check                 # OK when README matches
python3 -m unittest test_analysis             # analysis tests on synthetic fixtures
```

`data/<run-id>/` holds:
- `run.json`: `meta`, `params` and `groups`, see `analysis.py`. `params.jitterReorders` is set when the host's netem reorders with jitter (the acceptance smoke's step E). `params.reorderedPct` then holds the calibration capture's reordering, and the tables label D50J10 and COMBO as jitter with reordering;
- `impairment-timeline.json`;
- `samples/<instance>/`;
- `profile.jsonl`;
- `land-lifecycle.jsonl`;
- `system-metrics.json` (the server process's samples);
- `sockstat.jsonl` (`node dist/sockstat-main.js`; namespace `-` is the server's).

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

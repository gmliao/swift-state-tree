# Layer-3 spike measurements (do not merge)

Measurement harness for the layer-3 spike (#93) against base 59894dc (#91 head). Everything here is
env-gated measurement code on `measure/*` branches; nothing is meant for `main`.

| Branch | Tree | Contents |
|---|---|---|
| `measure/base-59894dc` | `base` | 59894dc + `SpikeMetrics` instrumentation, savepoint prototype, `SPIKE_MAX_PLAYERS`; ServerLoadTest client model (arms A/B); ws-loadtest diagnostics; these scripts |
| `measure/spike-672b559` | `spike` | 672b559 (spike, combined tick+sync turn) + the same instrumentation |
| `measure/variant-fold` | `variant` | spike + sync-only turns driven by the sync loop + the coincident-sync (fold) rule |

## Setup (once)

```bash
git clone <repo> sst && cd sst
MEASURE_ROOT=$HOME/measure Examples/GameDemo/measure-spike/setup.sh   # worktrees + release builds + load client
export MEASURE_ROOT=$HOME/measure
S=$MEASURE_ROOT/base/Examples/GameDemo/measure-spike
```

Results go to `$MEASURE_ROOT/results` (override with `MEASURE_RESULTS`).

## Rules for every run

- **Quiet window.** Nothing else heavy on the machine: no builds, tests, other servers or
  benchmarks while a script runs. All builds happen in `setup.sh` (and inside `cow.sh`, before and
  after its runs, never during one). Port 8080 must be free.
- **Interleaving.** The scripts alternate trees/arms within each repetition (base, other, base,
  other, ...); don't reorder or batch by tree.
- **Release only.** Every binary is built with `-c release`.
- **n = 3**, reported per run (spread), never only a mean.
- Phases per run: pre 8 s, steady 65 s, post 5 s. Metrics: 5 s windows in `metrics.jsonl`; analysis
  uses the steady windows only (first 5 s of steady skipped).
- Rooms are 5-player rooms unless stated; the load client joins the first player of a room at once
  and the others 300 ms later (simultaneous joins to a new instance id can create several lands; a
  separate issue).

## Queue (sequential, ~2 h)

```bash
$S/all.sh          # = fold.sh, then arms.sh, then cow.sh; log in $MEASURE_ROOT/results/all.log
```

### 1. `fold.sh` — coincident-sync variant vs base (~25 min)

cap300 (300 rooms × 5, messagepack, 5 workers) and json50 (1 room × 50, json, 1 worker), n=3.
Output: `results/fold/summary.txt`, per group (`cap300-base`, `cap300-variant`, `json50-*`):

- `tick.p99` (µs, whole tick incl. the in-turn sync on the variant), `turn.p99` (tick turn),
  `syncTurn.p50/p99` (sync-only turns), `sync.p99` (sync phase), `tickInterval.p50/p99`;
- `client.update.p99` (ms; the cadence check: must stay ≈ base, ~107 ms at 100 ms sync), `client.rtt.p95`;
- counters `foldedSyncs` (syncs folded into a coincident tick turn), `deferredTurns`, `backlogSkips`.

Gates (layer-3 plan): tick-turn p99 ≤ base tick p99 + 2 ms; sync-only-turn p99 ≤ base sync p99
+ 2 ms; json50 both ≤ 50 ms; update p99 within noise of base.

### 2. `arms.sh` — client cost, base tree only (~50 min)

300 and 500 rooms, n=3, interleaved A, B, C:

- **A**: `ServerLoadTest` (in-process `WebSocketTransport`, counting connection, no socket, no
  decode). Workload as ws-loadtest: one `PlayAction` per player per second (`LOADTEST_SEND=action`).
- **B**: A plus a full client decode of every received frame mirroring the TS SDK
  (`LOADTEST_CLIENT_DECODE=1`): messagepack unpack, opcode dispatch, 107 split, PathHash → path with
  dynamic-key slots, patches applied to a flat per-session map.
- **C**: ws-loadtest (Node) over real sockets, with diagnostics (`LOADTEST_DIAG_DIR`): per close
  code/reason/time/joined, event-loop lag p99 and CPU per worker per second; server at `LOG_LEVEL=info`;
  kernel TCP counters before/after.

Output: `results/arms/summary.txt`, per arm and room count:
- A/B: `tick.p99`, `sync.p99` (µs), `update.p99us` (`clientUpdateInterval`), `rtt` (`clientRTT`, B only),
  `clientDecode.p99us`, `clientDecodeCores` (decode CPU), `cpu(process)` (server + client, one process);
- C: `tick.p99`, `sync.p99`, `update.p99ms`, `rtt.p95ms`, `disconnectRate`, `cpu.serverCores` and
  `cpu.nodeWorkersCores`, `clientCloses` (phase | event | code | reason | when | joined → count),
  worker lag, `serverCloses` (pong timeouts, resets, writer-ceiling closes, duplicate logins), `tcpDelta`.

Read: A vs B = client decode cost; B vs C = sockets + Node. If C's closes are pong timeouts during
worker lag, run the 10-worker block at the end of `arms.sh` (commented) and compare.

### 3. `cow.sh` — CoW copies during sync (~30 min incl. builds)

Applies `cow/cow_patch.py` (`SPIKE_COW=1`) to base and spike, cap300 + json50, n=3, then reverts.
On each nested write to an Array/Dictionary/Set `@Sync` field it forces and times two copies:
**holder** (the stored buffer is shared with someone else, e.g. the `beginSync` snapshot: the copy
a `_modify` accessor would still pay after #94) and **#94** (the get/set temporary: what every nested
write pays today). Output `results/cow/summary.txt`: `holderPerCycle.p50/p99` (per beginSync…endSync
cycle; base only, the spike has no such cycle), `holderCopies/s`, `holderInSync/s`, `holderMB/s`,
`holderShareOfTick%`, `94Copies/s`, `94MB/s`, `94ShareOfTick%`. The forced copies inflate tick time;
shares are against the same run's tick time. Expected: spike holder copies ≈ 0.

## Single runs

```bash
PPR=5 WORKERS=5 $S/run.sh <base|spike|variant> $S/scenarios/cap300.json <outdir> messagepack [ENV=VAL ...]
$S/slt.sh <A|B> <rooms> <outdir>
python3 $S/analyze.py <outdir>          # one ws-loadtest run
python3 $S/summarize.py <dir-of-runs>   # groups <name>-<i>
```

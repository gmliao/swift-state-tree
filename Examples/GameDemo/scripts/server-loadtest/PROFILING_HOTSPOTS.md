# Hotspot Analysis for ServerLoadTest / GameServer

This doc describes how to see **CPU hotspots** (where time is spent) and compares options.

## 0. CLI: one command to run test + collect + summarize

Use the helper script to run a load test with Profile Recorder, collect samples during steady state, and get a **CLI summary** (top symbols by sample count):

```bash
cd Examples/GameDemo
bash scripts/server-loadtest/run-collect-profile.sh --rooms 500 --samples 1000
```

**Output** (under `results/server-loadtest/profiling/`):

- `profile-500rooms-<timestamp>.perf` — raw samples (drag into Speedscope or Firefox Profiler)
- `profile-500rooms-<timestamp>.summary.txt` — top symbols and total line count for quick analysis

**Options:**

- `--rooms N` (default 500)
- `--samples N` (default 800)
- `--ramp-wait N` seconds before first collect (default 35)
- `--output-dir DIR`
- `--collect-only --pid <PID>` — only collect from an already-running process
- `--no-analyze` — skip generating the summary file

**Analyze an existing .perf file:**

```bash
bash scripts/server-loadtest/analyze-profile.sh /path/to/samples.perf -o summary.txt
```

---

## 1. Swift Profile Recorder (recommended for in-process, no special privileges)

**Pros**: Runs inside the process; no `CAP_SYS_PTRACE`; single `curl` to get samples; works in containers.  
**Cons**: Need to enable and collect samples while the app runs.

### Steps

1. **Enable the server** when starting the app (e.g. 500-room script):
   ```bash
   export PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/serverloadtest-samples-{PID}.sock'
   bash run-server-loadtest-500-with-profiler.sh
   ```
   Or run GameServer / ServerLoadTest with the same env. `{PID}` is replaced by the process ID.

2. **Get the process PID** (e.g. from logs or `pgrep -f ServerLoadTest`).

3. **Collect samples** while the load test is in steady state (in another terminal):
   ```bash
   SOCK=/tmp/serverloadtest-samples-<PID>.sock
   curl -sd '{"numberOfSamples":500,"timeInterval":"10ms"}' --unix-socket "$SOCK" http://localhost/sample | swift demangle --compact > /tmp/samples.perf
   ```
   Increase `numberOfSamples` (e.g. 1000–2000) for a richer profile.

4. **View hotspots**:
   - **Speedscope**: Open https://speedscope.app and drag `/tmp/samples.perf` onto the page.
   - **Firefox Profiler**: Open https://profiler.firefox.com and drag `/tmp/samples.perf` onto the page.
   - **FlameGraph**:  
     `./stackcollapse-perf.pl < /tmp/samples.perf | swift demangle --compact | ./flamegraph.pl > samples.svg && open samples.svg`

You get a **call tree / flame graph** showing which functions use the most CPU → **hotspots**.

---

## 2. Alternatives

| Method | When to use | How |
|--------|-------------|-----|
| **Xcode Instruments** (macOS) | Prefer GUI, same machine | Xcode → Product → Profile, or attach to process; use **Time Profiler**. No env var needed if you run from Xcode. |
| **perf** (Linux) | Native Linux profiling | `perf record -g -p <PID>` for 30–60s, then `perf report` or `perf script \| stackcollapse-perf.pl \| flamegraph.pl`. Needs `perf` and usually `sudo` or `CAP_SYS_PTRACE`. |
| **Swift Profile Recorder** | Containers, no ptrace, or remote | As above: env var + curl → `.perf` → Speedscope / Firefox Profiler / FlameGraph. |

---

## 3. Actor wait & multi-thread utilization

You can see **actor contention** (time waiting to enter an actor) and **thread pool utilization** with the right tools.

### Swift Profile Recorder (on-CPU + off-CPU)

Swift Profile Recorder is an **on- and off-CPU** sampling profiler: it records both **running** and **waiting** threads (e.g. blocked on locks, `await` suspension, I/O).

- **Actor wait**: In the `.perf` / flame graph, look for stacks that show **scheduler / executor / `await`** frames while the thread is not running “your” code. A large share of samples in the runtime or “swift_task_switch” / executor code often indicates **actor or task queue contention**.
- **Utilization**: If many samples are in “wait” or runtime frames and few in your app code, effective CPU utilization is lower; the profile gives you the raw stacks to see where time goes (compute vs wait).

So you **can** infer actor wait and utilization from the same `.perf` you use for hotspots (e.g. in Speedscope / Firefox Profiler), by reading the call stacks and distinguishing “running in my code” vs “waiting in runtime/scheduler”.

### Instruments – Swift Concurrency (macOS, best for actors & threads)

For **dedicated** actor and concurrency views, use **Instruments** with the **Swift Concurrency** template (Xcode 14+):

- **Actor execution**: Which actors run when, and how long they hold the actor.
- **Thread pool**: How many threads are busy vs idle, and how work is distributed.
- **Task / await**: Where tasks suspend and resume, and where they wait.

**How**: Xcode → Product → Profile (⌘I) → choose **Swift Concurrency**. Run your app (e.g. ServerLoadTest or GameServer) and reproduce load; stop recording and inspect the actor/thread timelines.

This is the **best option for “actor 等待狀況” and “多執行緒利用率”** on macOS.

### Optional: custom signposts

For **targeted** metrics (e.g. “time waiting to enter LandKeeper” vs “time inside LandKeeper”), you can add **os_signpost** (or logging) around actor work and measure in Instruments’ **Points of Interest** or **os_signpost** instrument. That gives you explicit “actor wait” vs “actor run” durations without inferring from samples.

---

## 4. Summary

- **Hotspots**: Swift Profile Recorder (curl → `.perf` → Speedscope/Firefox) or Xcode Time Profiler.
- **Actor wait & thread utilization**:  
  - **macOS**: Prefer **Instruments → Swift Concurrency** for actor and thread-pool views.  
  - **Same `.perf` from Swift Profile Recorder** can still show wait vs run from stacks (on- and off-CPU).  
- **Containers / Linux**: Swift Profile Recorder (or `perf`) for stacks; no Swift Concurrency GUI there, so infer from off-CPU stacks and scheduler frames.

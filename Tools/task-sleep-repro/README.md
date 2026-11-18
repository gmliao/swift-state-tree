# task-sleep-repro

A standalone stress test for the release-only crash in
[`Notes/solutions/2026-01-27-release-only-crashes-task-sleep-and-format-s.md`](../../Notes/solutions/2026-01-27-release-only-crashes-task-sleep-and-format-s.md):
`swift_task_dealloc` aborting with "freed pointer was not the last allocation". It asks which
pattern triggers it on which toolchain: `Task.sleep(for:)` (the lesson's attribution, and the
reason `safeTaskSleep` exists), or the task-allocator bug reported upstream for `async let` and
`DiscardingTaskGroup` teardown ([swiftlang/swift#75501](https://github.com/swiftlang/swift/issues/75501),
closed 2026-03-26; reported fixed in Swift 6.3.1).

It depends on nothing in this repository. Each arm runs many concurrent workers, each looping
over short sleeps with cancellation:

| Arm | Pattern |
|---|---|
| `sleep-for` | `Task.sleep(for:)` in a child `Task`, cancelled half the time |
| `sleep-nanoseconds` | `Task.sleep(nanoseconds:)`, the same way |
| `async-let` | two `async let` sleeps; half the time one is left unawaited, so leaving the scope cancels and awaits it |
| `async-let-typed` | the same in a `throws(StopError)` function, one child throwing half the time |
| `discarding-group` | a `withThrowingDiscardingTaskGroup` of sleeps, cancelled or thrown out of half the time |

## Run

Release builds only; the crash was never seen in debug.

```bash
cd Tools/task-sleep-repro
./run.sh                       # results/<swift version>-<OS>-<arch>/, 5 runs × 2000 workers × 20 s per arm
./run.sh out 10 4000 30        # out-dir, runs, workers, seconds
```

On the pinned Linux toolchain:

```bash
docker run --rm -v "$PWD":/work -w /work swift:6.2.4-noble ./run.sh results/swift-6.2.4-linux
```

Each run is its own process. `summary.tsv` lists each arm, run, exit status (a signal shows as
128 + its number, 134 for SIGABRT) and the run's last line; a finished run ends with
`result=completed`. `toolchain.txt` holds `swift --version` and `uname -a`.

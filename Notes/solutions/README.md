# Solutions

Reusable lessons from solved problems: a bug class, a trap in Swift or the toolchain, a measurement pitfall, a testing practice. Each entry says what went wrong, why, how it was fixed, and the rule that prevents it next time.

This isn't a plan (those go in [`../plans/`](../plans/README.md)) or a design document, and it doesn't replace `docs/`. An entry records how a problem was understood when it was solved; the code is the source of truth.

## Before designing a fix

Search here first. The same bug class tends to come back at a new site.

```bash
grep -l -i '<symptom or keyword>' Notes/solutions/*.md
grep -l -i -x '  - <tag>' Notes/solutions/*.md   # by tag (also matches a related: entry)
```

Or scan the index below.

## When to add an entry

- A fix whose cause could recur elsewhere (a pattern, not a one-off typo).
- A trap that cost more than one attempt to find.
- A review finding that names a rule others should follow.
- A measurement result that turned out to be an artifact of the method or the tool.

Add the entry in the same PR or commit as the fix when you can, and add its row to the index.

## Format

One problem per file, named `YYYY-MM-DD-<slug>.md`, dated when the lesson was established (usually the fix's merge date).

```yaml
---
module: <module or area, e.g. SwiftStateTreeTransport>
date: YYYY-MM-DD
problem_type: bug_class | gotcha | performance_collapse | measurement_pitfall | testing_practice
component: <subsystem, e.g. outbound-send-path>
symptoms:
  - "<what you would see, in the words you'd search for>"
root_cause: <snake_case summary>
resolution_type: design_rule | architectural_fix | code_fix | design_change | established_pattern | tool_fix_and_method_rule
severity: low | medium | high
tags:
  - <keyword>
related:
  - "#<issue or PR>"
---
```

Body sections: **Problem**, **Symptoms** (optional when the frontmatter covers them), **Root cause**, **Fix**, **Prevention** (the rule to apply next time, and how a test pins it). English, concise; link the code path, the plan in `Notes/plans/` and the `deep-research/` topic where one exists. Cite commits that are on `main`; for squashed PRs, cite the PR and its merge commit.

## Index

| Date | Entry | Tags |
|---|---|---|
| 2026-01-27 | [Release-only crashes: `Task.sleep(for:)` and `%s` with a Swift `String`](2026-01-27-release-only-crashes-task-sleep-and-format-s.md) | release, crash, task-sleep, string-format |
| 2026-11-04 | [Frames for one session overtake each other](2026-11-04-same-session-frames-overtake-each-other.md) | ordering, send, outbound-writer, unstructured-task |
| 2026-11-05 | [Check, await, act: the function resumes on stale state](2026-11-05-await-resumes-on-stale-state.md) | reentrancy, actor, keeper, turns |
| 2026-11-05 | [A callback that outlives its instance clears state by key alone](2026-11-05-callback-outlives-its-instance-clears-by-key.md) | reentrancy, reconnect, generation, cleanup |
| 2026-11-05 | [Force the interleaving with hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md) | testing, reentrancy, hold-points |
| 2026-11-05 | [Test recorders that log in a `Task` per frame reorder on Linux](2026-11-05-async-test-recorder-reorders-frames-on-linux.md) | testing, linux, ordering, cross-platform |
| 2026-11-05 | [The load tool is the bottleneck](2026-11-05-load-tool-is-the-bottleneck.md) | measurement, load-test, rtt, methodology |
| 2026-11-06 | [A shared send serialization point collapses under saturation](2026-11-06-shared-send-serialization-point-collapses-under-saturation.md) | performance, saturation, backpressure, outbound-writer |
| 2026-11-06 | [Unbounded queues and awaits at component boundaries](2026-11-06-unbounded-queues-and-awaits-at-boundaries.md) | backpressure, deadline, timeout, bounded-queue |
| 2026-11-06 | [A protocol extension's async default wins over the concrete type's sync method](2026-11-06-protocol-extension-default-wins-overload-resolution.md) | swift, protocol-extension, overload-resolution, async |
| 2026-11-07 | [An evicting set lets an ended attempt back in](2026-11-07-evicting-set-lets-an-ended-attempt-back-in.md) | join, admission, eviction, token |
| 2026-11-07 | [A benchmark option honoured on one path only](2026-11-07-benchmark-option-honoured-on-one-path-only.md) | measurement, benchmark, load-test, methodology |
| 2026-11-07 | [Resolver errors arrive wrapped: unwrap before you classify them](2026-11-07-resolver-errors-arrive-wrapped.md) | resolver, error-handling, cancellation, initialization |
| 2026-11-07 | [`modprobe` loads only the first module named](2026-11-07-modprobe-loads-only-the-first-module.md) | kernel-modules, netem, tc, wsl, measurement-setup |
| 2026-11-07 | [`/proc/net/sockstat` TCP `mem` is host-wide, not per namespace](2026-11-07-sockstat-mem-is-host-wide.md) | netns, sockstat, kernel, measurement, methodology |
| 2026-11-07 | [`tc qdisc change ... netem` resets the options it isn't given, `limit` included](2026-11-07-tc-change-netem-resets-limit.md) | netem, tc, measurement-setup, methodology |
| 2026-11-07 | [`FileHandle.write(_: Data)` terminates the process on a write error](2026-11-07-filehandle-write-terminates-on-error.md) | foundation, filehandle, diagnostics, crash, linux |
| 2026-11-07 | [A cause recorded at a later callback than the event loses to a decision in between](2026-11-07-cause-recorded-at-a-later-callback.md) | nio, diagnostics, ordering, first-cause, measurement |

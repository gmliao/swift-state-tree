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
| 2026-11-05 | [Force the interleaving with hold points, not timing](2026-11-05-hold-points-not-timing-in-race-tests.md) | testing, reentrancy, hold-points, timers, tick, input-drain, parallel-hang, record-save, self-wait, deadline, hang-bound, code-timer |
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
| 2026-11-07 | [A per-tick frame can't be closed while late entries for its tick still arrive](2026-11-07-a-frame-cannot-close-while-late-entries-arrive.md) | recording, record-format, streaming, truncation, late-entries |
| 2026-11-07 | [A wire form keyed by schema patterns silently misses shapes the schema doesn't define](2026-11-07-a-wire-form-keyed-by-schema-patterns-misses-undefined-shapes.md) | transport, atomic-values, schema, wire-format, optionals |
| 2026-11-07 | [`pgrep` on a pipeline finds the wrong process](2026-11-07-pgrep-on-a-pipeline-finds-the-wrong-process.md) | methodology, shell, manual-check, process-control |
| 2026-11-07 | [`tc qdisc change` keeps netem parameters you don't restate](2026-11-07-tc-qdisc-change-keeps-unstated-parameters.md) | measurement, network-impairment, netem, tc, methodology |
| 2026-11-07 | [Encoded bytes vary run to run when a per-process hash order feeds slot assignment](2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md) | measurement, determinism, encoding, dynamic-keys, benchmark |
| 2026-11-07 | [Per-room bytes grow with identifier length when a strategy resends the IDs](2026-11-07-per-room-bytes-grow-with-identifier-length.md) | measurement, benchmark, encoding, methodology |
| 2026-11-07 | [A Darwin pipe write's SIGPIPE is process-directed: the writer can exit before it lands](2026-11-07-darwin-pipe-sigpipe-is-process-directed.md) | testing, signals, darwin, exit-test, flaky |
| 2026-11-08 | [A concurrency diagnostic the local 6.3 accepts and the pinned 6.2.4 rejects](2026-11-08-local-toolchain-accepts-what-pinned-rejects.md) | toolchain, concurrency, region-isolation, ci, linux |
| 2026-11-08 | [A synced field added to an example land needs SchemaGen and codegen in the same commit](2026-11-08-example-state-field-needs-schemagen-and-codegen.md) | ci, schema, codegen, examples, verification |
| 2026-11-08 | [A live copy can end between an event and its output: bound the tail by the read sequence, not the tick](2026-11-08-live-copy-cut-leaves-a-tail-the-verdict-must-bound.md) | reevaluation, verification, live-record, flaky, e2e |
| 2026-11-08 | [A counter incremented at plan or send time overcounts when the target goes away in between](2026-11-08-counter-at-plan-time-overcounts-when-target-goes-away.md) | measurement, load-test, counters, ramp-down, methodology |
| 2026-11-08 | [A converter that stamps the checkout's commit misattributes every older run](2026-11-08-collect-stamps-the-checkout-not-the-run.md) | measurement, provenance, collect, regenerate, methodology |
| 2026-11-08 | [A client-side matcher keyed to a wire shape breaks silently when the encoding changes](2026-11-08-client-matcher-keyed-to-wire-shape-breaks-silently.md) | measurement, load-test, encoding, wire-format, methodology |
| 2026-11-08 | [Moving a topic's results breaks the topics that read them](2026-11-08-moving-a-topics-results-breaks-the-topics-that-read-them.md) | deep-research, regenerate, verification, methodology |
| 2026-11-08 | [Mutation runs: a stale `.pyc` after `git checkout` restores a same-size file within the same mtime second](2026-11-08-mutation-runs-stale-pyc-after-checkout.md) | testing, mutation, python, pycache, methodology |
| 2026-11-08 | [A reader that stops early fails the pipeline under `pipefail`](2026-11-08-early-exit-reader-under-pipefail.md) | shell, pipefail, sigpipe, measurement, methodology |
| 2026-11-08 | [A quiet signal that counts only successes, and an offered rate above the service rate](2026-11-08-quiet-signal-counts-only-successes.md) | deep-research, load-test, backlog, methodology |
| 2026-11-08 | [A cancellation test passes on the deadline instead](2026-11-08-cancellation-test-passes-on-the-deadline.md) | testing, cancellation, deadline, mutants |
| 2026-11-09 | [A cancelled task waits for its cancellation handler to return](2026-11-09-a-cancelled-task-waits-for-its-cancellation-handler.md) | concurrency, cancellation, testing, hold-points |
| 2026-11-09 | [Collected results pinned to the host's checkout, and tests pinned to "no data yet"](2026-11-09-collected-results-pinned-to-the-host-and-to-no-data-yet.md) | deep-research, collect, testing, provenance, methodology |
| 2026-11-09 | [A wall-clock flush that closes a record still being merged splits it at points set by time](2026-11-09-a-wall-clock-flush-splits-records-at-time-set-points.md) | recording, record-format, determinism, timers, tickless |
| 2026-11-09 | [`String(contentsOfFile:)` on a Linux procfs file returns only the first page](2026-11-09-procfs-read-returns-only-the-first-page.md) | linux, procfs, foundation, measurement, metadata |
| 2026-11-09 | [A destroyed land kept alive by its own links](2026-11-09-a-destroyed-land-kept-alive-by-its-own-links.md) | memory, reference-cycle, teardown, lifecycle, testing |
| 2026-11-09 | [A view restart on a live connection, recorded without a clear](2026-11-09-a-view-restart-recorded-without-a-clear.md) | recording, replay, sync-stream, resync, verifier |
| 2026-11-09 | [An ordering check must fail under the mutant that breaks it](2026-11-09-an-ordering-check-must-fail-under-its-mutant.md) | testing, mutants, reentrancy, concurrency |
| 2026-11-09 | [A hand-written codec form drops a field added later](2026-11-09-a-hand-written-codec-form-drops-a-field-added-later.md) | codec, messagepack, serialization, testing |
| 2026-11-09 | [Wire-fed integer conversions must be exact and throwing](2026-11-09-wire-fed-integer-conversions-must-be-exact-and-throwing.md) | codec, messagepack, security, decoding, crash, record, replay |
| 2026-11-09 | [A child inherits the worker thread's blocked signals](2026-11-09-a-child-inherits-the-worker-threads-blocked-signals.md) | signals, linux, cross-platform, process, testing |
| 2026-11-09 | [An ID a client can build is not an authorization](2026-11-09-an-id-a-client-can-build-is-not-an-authorization.md) | security, authorization, replay, auto-create |
| 2026-11-09 | [A test on a ticking land awaits a join's effect without stepping the turn that applies it](2026-11-09-a-ticking-land-applies-a-join-in-its-next-turn.md) | testing, keeper, tick, lifecycle-input, hang, time-limit, tickless, join-flip, input-drain |
| 2026-11-09 | [An XCTest assertion is silent inside a Swift Testing test](2026-11-09-xctest-assertion-is-silent-under-swift-testing.md) | testing, macros, swift-testing, xctest, swift-syntax |
| 2026-11-09 | [The default SwiftPM build system hides frontend dump output and moves the build directory](2026-11-09-default-build-system-hides-frontend-dump-output.md) | swiftpm, toolchain, build, macros, measurement |
| 2026-11-09 | [A tickless keeper built without a transport only tests the legacy path](2026-11-09-a-tickless-keeper-without-a-transport-tests-only-the-legacy-path.md) | testing, keeper, tickless, in-turn-sync, mutants |
| 2026-11-09 | [Compare event times on one clock](2026-11-09-compare-event-times-on-one-clock.md) | deep-research, measurement, clocks, slow-reader, sync-lag, testing |
| 2026-11-10 | [A returned send is not a delivered frame](2026-11-10-a-returned-send-is-not-a-delivered-frame.md) | testing, send, send-queue, linux, ordering, frame-count-wait |
| 2026-11-10 | [A hold at a loop's start misses work a running loop picks up](2026-11-10-a-hold-at-a-loops-start-misses-a-running-loop.md) | testing, hold-points, keeper, input-drain, flaky |
| 2026-11-10 | [A rewritten extraction must keep the old path's empty-result rule](2026-11-10-a-rewritten-extraction-must-keep-the-empty-result-rule.md) | sync, extraction, per-player, byte-identity, equivalence-tests, testing |
| 2026-11-10 | [Per-connection work started once stops at the first reconnect](2026-11-10-per-connection-work-started-once-stops-at-reconnect.md) | ws-loadtest, measurement, reconnect, timers, testing |
| 2026-11-10 | [Unmeasured is not a failure](2026-11-10-unmeasured-is-not-a-failure.md) | deep-research, measurement, load-client, reconnect, sync-lag, testing |
| 2026-11-10 | [A sleep between timed spans slows the next span](2026-11-10-a-sleep-between-timed-spans-slows-the-next-span.md) | measurement, benchmark, methodology, cpu-frequency, drain |
| 2026-11-10 | [A diff replacement must match the old diff's quirks, found by a differential test](2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md) | testing, differential, sync-diff, unicode, dirty-tracking |
| 2026-11-10 | [A skipped test class reads as passing](2026-11-10-a-skipped-test-class-reads-as-passing.md) | testing, linux, cross-platform, review, verification |
| 2026-11-10 | [`--skip-build` after a failed build or a branch switch runs the old tests](2026-11-10-skip-build-after-a-failed-build-runs-the-old-tests.md) | testing, verification, swiftpm, skip-build, mutants, branch switch |
| 2026-11-11 | [A second staging in one plan undoes an edit to the first](2026-11-11-a-second-staging-undoes-an-edit-to-the-first.md) | sync-tables, staging, row-addressing, remake |
| 2026-11-11 | [CPU-bound tests starve the cooperative pool](2026-11-11-cpu-bound-tests-starve-the-cooperative-pool.md) | testing, linux, concurrency, cooperative-pool, parallel-tests |
| 2026-11-11 | [NSNumber.compare is a double compare on Linux](2026-11-11-nsnumber-compare-is-a-double-compare-on-linux.md) | linux, foundation, json, nsnumber, decimal |
| 2026-11-11 | [A test reads state that an unawaited start task sets](2026-11-11-a-test-reads-state-an-unawaited-start-task-sets.md) | testing, initialization, in-turn-sync, configurations, vacuous-assertion |
| 2026-11-11 | [A per-instance close misses a bind after its snapshot](2026-11-11-a-per-instance-close-misses-a-bind-after-its-snapshot.md) | reentrancy, router, land-stop, snapshot, bind, shutdown |
| 2026-11-11 | [A drain wait returns at once before the destruction starts](2026-11-11-a-drain-wait-returns-at-once-before-the-destruction-starts.md) | land-manager, drain, land-stop, wait-signal, lost-wakeup |
| 2026-11-11 | [Merging a squashed base into a stacked branch duplicates a moved line](2026-11-11-merging-a-squashed-base-duplicates-a-moved-line.md) | git, merge, squash, stacked-prs |
| 2026-11-12 | [A hash of a whole capture depends on the send order across sessions](2026-11-12-a-whole-capture-hash-depends-on-send-order-across-sessions.md) | measurement, capture, digest, determinism, send-order, ab-test |
| 2026-11-12 | [An equality trace misses a key bug when keys collide](2026-11-12-an-equality-trace-misses-a-key-bug-when-keys-collide.md) | testing, mutants, differential, change-metrics, sync-tables |
| 2026-11-12 | [A get/set property wrapper copies the collection on every write](2026-11-12-a-get-set-property-wrapper-copies-the-collection-on-every-write.md) | copy-on-write, property-wrapper, modify-accessor, sync, dirty-tracking, performance |
| 2026-11-12 | [A closure in every wrapper makes every node type non-trivial](2026-11-12-a-closure-in-every-wrapper-makes-every-node-non-trivial.md) | property-wrapper, value-witness, memory-layout, macro, static-storage, sync, performance |
| 2026-11-13 | [A surviving mutant is a coverage gap or an equivalent site: find out which](2026-11-13-a-surviving-mutant-is-a-coverage-gap-or-an-equivalent-site.md) | testing, mutants, fault-injection, encode-failure, sync-tables, per-player |
| 2026-11-13 | [A stacked branch carries a stale plan](2026-11-13-a-stacked-branch-carries-a-stale-plan.md) | git, stacked-prs, plans, review |
| 2026-11-13 | [An input that takes effect only in a later phase, measured without that phase](2026-11-13-an-input-applied-in-a-later-phase-measured-without-it.md) | measurement, benchmark, methodology, inputs, tick |
| 2026-11-13 | [An E2E leg named for a path it doesn't run](2026-11-13-an-e2e-leg-named-for-a-path-it-does-not-run.md) | encoding, opcode-json, payload-compression, e2e, coverage, crash |
| 2026-11-14 | [A verdict never checked on one land kind](2026-11-14-a-verdict-never-checked-on-one-land-kind.md) | replay, tickless, sync-output, verifier, testing |
| 2026-11-14 | [A snapshot read behind a shared diff baseline](2026-11-14-a-snapshot-read-behind-a-shared-diff-baseline.md) | reentrancy, initial-sync, broadcast-cache, legacy-sync |
| 2026-11-14 | [A case placed only at the root never tests the descent](2026-11-14-a-case-placed-only-at-the-root-never-tests-the-descent.md) | testing, mutants, fixtures, path-trie, sync-tables |
| 2026-11-17 | [A test-argument literal the pinned toolchain type-checks and a newer one times out on](2026-11-17-pinned-toolchain-type-checks-what-local-times-out-on.md) | toolchain, swift-testing, type-checking, ci |
| 2026-11-17 | [A gated test under a wall-clock deadline fails once the suite grows](2026-11-17-a-gated-test-under-a-wall-clock-deadline.md) | testing, resolver, deadline, cooperative-pool, parallel-tests, hold-points |
| 2026-11-17 | [A hang guard in a task group waits for the hang](2026-11-17-a-hang-guard-in-a-task-group-waits-for-the-hang.md) | testing, hang-bound, deadlock, task-group, mutants |
| 2026-11-17 | [A land-failure test passes in-turn and hangs on the legacy path](2026-11-17-a-land-failure-test-passes-in-turn-and-hangs-on-legacy.md) | testing, in-turn-sync, legacy-sync, land-failure, tick |
| 2026-11-18 | [A macro that splits a type's spelling breaks on nested types](2026-11-18-a-macro-that-splits-a-type-spelling-breaks-on-nested-types.md) | macros, swift-syntax, type-spelling, container-helpers, goldens |
| 2026-11-18 | [A `fatalError` in a cast's fallback branch is reachable from type-erased data](2026-11-18-a-fatalerror-in-a-casts-fallback-is-reachable-from-type-erased-data.md) | encoding, crash, type-erasure, land-failure, replay |
| 2026-11-18 | [A server close goes around the send queue](2026-11-18-a-server-close-goes-around-the-send-queue.md) | ordering, send, close, session-queue |
| 2026-11-18 | [A fuzz harness is only as good as the mutants it kills](2026-11-18-a-fuzz-harness-is-only-as-good-as-the-mutants-it-kills.md) | testing, fuzzing, mutants, decoding, messagepack, json |
| 2026-11-18 | [A soft reset to a moved main stages the reverse of every commit in between](2026-11-18-soft-reset-to-a-moved-main-stages-reverse-commits.md) | git, reset, squash, local-main |
| 2026-11-18 | [A cache keyed by a name serves a changed definition the old value](2026-11-18-a-cache-keyed-by-a-name-serves-a-changed-definition.md) | caching, fingerprint, replay, testing |
| 2026-11-18 | [Synthesized `Decodable` ignores `var` defaults, so a `{}` sample fails](2026-11-18-synthesized-decodable-ignores-var-defaults.md) | codable, schemagen, fingerprint, swift |
| 2026-11-18 | [A macro that names a property from `identifier.text` keeps its backticks](2026-11-18-macro-names-from-identifier-text-keep-backticks.md) | macros, swift-syntax, codable, schemagen, fingerprint |
| 2026-11-18 | [A parser's depth limit isn't the pipeline's: every recursive stage after it needs the bound](2026-11-18-a-parsers-depth-limit-isnt-the-pipelines.md) | decoding, nesting, stack-overflow, darwin, cooperative-pool, json, snapshot, outbound |
| 2026-11-19 | [A cache key is evaluated again in the post step, after the build filled the workspace](2026-11-19-a-cache-key-is-evaluated-again-in-the-post-step.md) | ci, github-actions, cache, swiftpm, container |
| 2026-11-19 | [A Docker tag isn't a pin: the same tag pulled two images a day apart](2026-11-19-a-docker-tag-is-not-a-pin.md) | ci, docker, toolchain, measurement, methodology |
| 2026-11-19 | [A checker's trigger must cover every path it reads, not its own directory](2026-11-19-a-checkers-trigger-must-cover-what-it-reads.md) | pre-push, ci, deep-research, shell, pipefail |
| 2026-11-19 | [A branch cut from a PR head that was then squash-merged duplicates on merge, with no conflict](2026-11-19-a-branch-from-a-squash-merged-pr-head-duplicates-on-merge.md) | git, merge, squash, stacked-branches, ci |
| 2026-11-19 | [A small generic wrapper used from another module runs unspecialized unless it's `@inlinable`](2026-11-19-a-cross-module-generic-wrapper-runs-unspecialized.md) | performance, generics, specialization, inlinable, existential, proof-type |
| 2026-11-19 | [Inlined class state pays a dynamic exclusivity check on every use](2026-11-19-inlined-class-state-pays-dynamic-exclusivity-checks.md) | performance, exclusivity, inlinable, class-state, release-build |
| 2026-11-19 | [A test harness under errexit dies without naming the failing case](2026-11-19-a-test-harness-under-errexit-dies-unnamed.md) | shell, errexit, set-e, test-harness, mutation |
| 2026-11-20 | [A thrown sweep cell hides the cells after it](2026-11-20-a-thrown-sweep-cell-hides-the-cells-after-it.md) | test-harness, differential, golden, fail-closed, reporting |
| 2026-11-19 | [`Bundle.allBundles` crashes a Linux test process (null dereference in CFBundleGetAllBundles)](2026-11-19-bundle-allbundles-crashes-on-linux.md) | linux, foundation, bundle, test-support, cross-platform |
| 2026-11-19 | [A typed decoder that replaces a JSON round trip misses the round trip's coercions](2026-11-19-a-typed-decoder-misses-the-round-trips-coercions.md) | testing, differential, decode, messagepack, decimal, float, anycodable |
| 2026-11-19 | [Decode a record with the codec that wrote it](2026-11-19-decode-a-record-with-the-codec-that-wrote-it.md) | replay, record-format, decode, canonical-messagepack, anycodable, date, json, resolver-output, verifier |
| 2026-11-19 | [A stale example build crashes after a library struct changes its layout](2026-11-19-a-stale-example-build-crashes-after-a-library-layout-change.md) | build, swiftpm, incremental, examples, crash, linux |
| 2026-11-19 | [An explicit config still reads the environment through its stored defaults](2026-11-19-an-explicit-config-still-reads-the-environment.md) | testing, environment, transport-env-config, sync-tables, ci, test-selection |
| 2026-11-19 | [A harness with its loops off must order the work it starts](2026-11-19-a-harness-with-its-loops-off-must-order-the-work-it-starts.md) | testing, differential, determinism, golden, sync, hold-points |
| 2026-11-19 | [A Swift block in the Turns docs must appear in a tested file](2026-11-19-a-turns-doc-block-must-appear-in-a-tested-file.md) | documentation, turns, docc, testing, pre-push |
| 2026-11-19 | [A retry loop catches failures, not hangs](2026-11-19-a-retry-loop-catches-failures-not-hangs.md) | ci, apt, retry, timeout, hang, shell |
| 2026-11-19 | [Array literals of enum cases joined with `+` time out the pinned type checker](2026-11-19-concatenated-enum-literals-time-out-the-pinned-type-checker.md) | toolchain, type-checking, ci |
| 2026-11-20 | [A helper that returns on state leaves its operation running](2026-11-20-a-helper-that-returns-on-state-leaves-its-operation-running.md) | testing, fixtures, join, polling, land-stop, flaky |
| 2026-11-20 | [A time limit does not end a wait that never resumes](2026-11-20-a-time-limit-does-not-end-a-wait-that-never-resumes.md) | testing, time-limit, hang-bound, test-gate, mutants, hold-points, mutation-run |
| 2026-11-20 | [A visited set keyed by a lossy name merges distinct types](2026-11-20-a-visited-set-keyed-by-a-lossy-name-merges-distinct-types.md) | schema, type-names, visited-set, codegen, registration |
| 2026-11-20 | [A concurrent delete stops a recursive removal and leaves the directory](2026-11-20-a-concurrent-delete-stops-a-recursive-removal.md) | testing, cleanup, filesystem, recorder, isolation |
| 2026-11-20 | [A macro-only change doesn't rebuild the clients that expand it](2026-11-20-a-macro-only-change-does-not-rebuild-its-clients.md) | macros, mutants, incremental-build, toolchain, testing |
| 2026-11-20 | [A budget break strands the work kinds after it](2026-11-20-a-budget-break-strands-the-work-kinds-after-it.md) | turns, driver, budget, drain-loop, follow-ups |
| 2026-11-21 | [A closure that captures only actor state runs off the actor](2026-11-21-a-closure-that-captures-only-actor-state-runs-off-the-actor.md) | turns, concurrency, isolation, continuation, lost-wakeup, quiescence |
| 2026-11-21 | [A feature path in the driver costs machines that don't use it](2026-11-21-a-feature-path-in-the-driver-costs-machines-that-do-not-use-it.md) | turns, driver, performance, instruction-gate, specialization, measurement |
| 2026-11-21 | [A hang bound can't end a wait that ignores cancellation](2026-11-21-a-hang-bound-cannot-end-a-wait-that-ignores-cancellation.md) | testing, hang-bound, cancellation, test-gate, continuation, watermark-gate |
| 2026-11-21 | [A gate checked per send site leaks at the next site; a failure found outside a turn needs a mailbox](2026-11-21-a-gate-checked-per-send-site-leaks-at-the-next-site.md) | transport, reentrancy, failure, output-gate, turns |
| 2026-11-21 | [A machine added to a gated bench binary moves its gated cells](2026-11-21-a-machine-added-to-a-gated-bench-binary-moves-its-gated-cells.md) | turns, measurement, benchmark, instruction-gate, specialization, function-merging |
| 2026-11-21 | [An unspecialized generic class looks up tuple metadata on every array access](2026-11-21-an-unspecialized-generic-class-looks-up-tuple-metadata-on-every-array-access.md) | turns, performance, generics, specialization, metadata, lock |
| 2026-11-21 | [A live-only predicate widened on a shared path changes replay](2026-11-21-a-live-only-predicate-widened-on-a-shared-path-changes-replay.md) | replay, reevaluation, routing, tickless, turns |
| 2026-11-21 | [An in-process depth test sized from Linux or release overflows the Mac's debug pool](2026-11-21-an-in-process-depth-test-sized-from-linux-overflows-the-mac.md) | testing, stack-overflow, recursion, nesting, cooperative-pool, debug-build, exit-test |
| 2026-11-21 | [A Foundation class cast bridges a Swift collection eagerly on Linux](2026-11-21-a-foundation-class-cast-bridges-a-swift-collection-on-linux.md) | linux, cross-platform, foundation, bridging, dynamic-cast, stack-overflow, nesting |
| 2026-11-21 | [A range checked at open can't bound later arithmetic whose count comes from code](2026-11-21-a-range-checked-at-open-cannot-bound-arithmetic-counted-by-code.md) | replay, record, overflow, integer-range, decoding, crash |
| 2026-11-21 | [Keeping a copy, then `removeAll(keepingCapacity:)`, allocates](2026-11-21-keeping-a-copy-then-removeall-keepingcapacity-allocates.md) | copy-on-write, allocation, keepingCapacity, turns, performance |
| 2026-11-21 | [A default in a public protocol's extension satisfies outside conformers only when it is `public`](2026-11-21-a-public-protocols-extension-default-needs-public-for-outside-conformers.md) | testing, mutants, must-not-compile, swift, protocol-extension, access-control |
| 2026-11-21 | [A generated local shadows a property of the same name](2026-11-21-a-macro-local-shadows-a-property-of-the-same-name.md) | macros, shadowing, snapshot-convertible, nesting-budget |
| 2026-11-21 | [A collection cast converts every element](2026-11-21-a-collection-cast-converts-every-element.md) | casts, collections, conditional-conformance, nesting-budget, stack-overflow |
| 2026-11-21 | [An exit body's local can be moved into a call's `Any` temporary and released there](2026-11-21-an-exit-body-local-can-be-released-through-a-calls-any-temporary.md) | exit-tests, lifetime, release-build, stack-overflow, nesting-budget |
| 2026-11-22 | [A test that reads a DEBUG-only probe fails in a release test run](2026-11-22-a-test-that-reads-a-debug-only-probe-fails-in-a-release-test-run.md) | testing, release-build, debug-only, probes, testable-import |
| 2026-11-22 | [A test clock with a gate per instant can't drive a single sleeper](2026-11-22-a-test-clock-with-a-gate-per-instant-cannot-drive-a-single-sleeper.md) | testing, test-clock, timers, deadline, monotonic-time, turns |
| 2026-11-22 | [A tombstone count reset while popped entries are outside the heap](2026-11-22-a-tombstone-count-reset-while-popped-entries-are-outside-the-heap.md) | heap, lazy-deletion, tombstones, compaction, timers, turns |
| 2026-11-22 | [A check placed at one replay site misses the other](2026-11-22-a-check-placed-at-one-replay-site-misses-the-other.md) | replay, reevaluation, initialize, verifier |
| 2026-11-22 | [A stricter check missed callers in the example packages](2026-11-22-a-stricter-check-missed-callers-in-the-example-packages.md) | testing, shell, examples, assertion |
| 2026-11-24 | [A `rejected` assertion is vacuous on a tickless frame](2026-11-24-a-rejected-assertion-is-vacuous-on-a-tickless-frame.md) | replay, tickless, rejected, mutant, testing |
| 2026-11-24 | [A test product is a `<target>-test-runner` executable under the swift-build system](2026-11-24-a-test-product-is-a-test-runner-executable-under-swift-build.md) | toolchain, swift-build, testing, linux, examples |
| 2026-11-24 | [A macro diagnostic defers when it can't read the spelling with certainty](2026-11-24-a-macro-diagnostic-defers-when-it-cannot-read-the-spelling.md) | macros, diagnostics, swift-syntax, generics, false-positive |
| 2026-11-24 | [A Swift Testing summary hides XCTest failures](2026-11-24-a-swift-testing-summary-hides-xctest-failures.md) | testing, xctest, swift-testing, verification, macros |
| 2026-11-24 | [An erased-array builder input reopens the type check](2026-11-24-an-erased-array-builder-input-reopens-the-type-check.md) | result-builder, type-erasure, land-dsl, registration, mutant |
| 2026-11-24 | [An "equivalent" mutant needs the combined-failure case checked](2026-11-24-an-equivalent-mutant-needs-the-combined-failure-case.md) | testing, mutants, registration, aggregation, fingerprint |
| 2026-11-24 | [An extension macro can't attach to a local type](2026-11-24-an-extension-macro-cannot-attach-to-a-local-type.md) | swift, macros, extension-macro, testing, fixtures |
| 2026-11-24 | [The Windows CRT `signal()` resets to the default on delivery: re-arm in the handler](2026-11-24-windows-crt-signal-resets-to-the-default-on-delivery.md) | windows, signals, crt, shutdown, ctrl-c |
| 2026-11-24 | [Compare instants by their order, never by the sign of a wrapped difference](2026-11-24-compare-instants-by-order-not-by-a-wrapped-difference.md) | clock, overflow, instant, wrapping-arithmetic, sleep |
| 2026-11-24 | [A depth limit checked after the tree is built bounds nothing](2026-11-24-a-depth-limit-checked-after-the-tree-is-built-bounds-nothing.md) | stack-overflow, depth-limit, recursion, anycodable, codable, debug-build, darwin |
| 2026-11-25 | [A drop-and-reset error path makes the next legal frame a violation](2026-11-25-a-drop-and-reset-error-path-makes-the-next-legal-frame-a-violation.md) | websocket, rfc6455, fragmentation, parser-state, stricter-check, error-path, testing |

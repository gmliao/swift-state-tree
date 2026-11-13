# Plans

This folder holds the design and implementation plans written while building SwiftStateTree. They are kept as a record of what was planned, why, and in what order. They are not maintained documentation: the code is the source of truth, and a plan can describe names, line numbers or behavior that have since changed. The official documentation is in `docs/`.

New plans go here as `YYYY-MM-DD-<topic>.md`. A Chinese companion can sit next to a plan as `YYYY-MM-DD-<topic>.zh-TW.md`. Longer specifications go in `specs/`.

Status values:

- **done**: the work is merged. Evidence is a PR or commit.
- **partial**: some steps are merged; the open steps are listed.
- **superseded**: replaced by a later plan or design, which is named.
- **open**: not started, or in progress.

Statuses were checked against `main` and the PR history on 2026-11-05.

## Turn rule, sync and in-turn sync

| Date | Plan | Status | Evidence |
|---|---|---|---|
| 2026-11-04 | [Sync dirty-flag window and merged broadcast gate](2026-11-04-sync-dirty-flags-and-merged-broadcast.md) | done | #74 (#68), #75 (#67), #76 (#70) |
| 2026-11-04 | [Keep late-queued events for the next sync cycle](2026-11-04-pending-events-kept-across-cycles.md) | done | #82 (#77) |
| 2026-11-04 | [Ordered state-update send](2026-11-04-ordered-broadcast-send.md) | superseded | Replaced by [sync cycle as plan + commit, one ordered writer](2026-11-04-sync-cycle-plan-commit-and-ordered-writer.md) |
| 2026-11-04 | [Sync cycle as plan + commit, one ordered outbound writer](2026-11-04-sync-cycle-plan-commit-and-ordered-writer.md) | partial | PR 1 ordered writer #86, PR 2 plan + commit #91. Open: PR 3, bounded per-session queue (#61) |
| 2026-11-04 | [E2E state convergence check](2026-11-04-e2e-state-convergence.md) | done | #83 (debug freeze and projection), #85 (`assertConverged` step; #79, #80) |
| 2026-11-04 | [RoomTransaction: target architecture for a room turn](2026-11-04-room-transaction-architecture.md) | partial | Target design. Landed: ordered writer #86, plan + commit #91, in-turn sync #114, boundary primitives #116, per-land phase offset #89, turn rule and helpers #146. Open: outbox back-pressure (#61), join as a turn input (#69), layer 3 PR B, per-input savepoints (#87) |
| 2026-11-05 | [Layer 3: sync phase inside the keeper turn](2026-11-05-layer3-prs.md) | partial | PR A (the runner) #114. Open: PR B, removal of the legacy sync path and the `IN_TURN_SYNC` switch; waits on the freeze settle (#129) and the joiner firstSync (#69) |
| 2026-11-05 | [Join as a turn input](2026-11-05-join-as-turn-input.md) | partial | PR 1 #137, PR 2 #139, PR 3 #141 (#92). Open: PR 4, join as a turn input (#69); PR 5, broadcast key table for joiners (#90) |
| 2026-11-05 | [Keeper state changes only in turns; helpers for the outer layer](2026-11-05-reentrancy-helpers.md) | partial | (a) #146, (b1) #148, (b2) #162 (#88), (b3) #158. Open: (c) join as a turn input (#69); (d1–d3) outer-layer retrofits (#97–#102, #144); freeze settle (#129) |
| 2026-11-06 | [Join PR 4b: targeted events to a joining session are held, then sent after its firstSync](2026-11-06-join-held-events.md) | done | #212 (4b of #69) |
| 2026-11-06 | [Join PR 4c: a pending-join phase, a bounded inbound deferral, and the join E2E](2026-11-06-join-pending-inbound.md) | done | #224 (4c of #69); one `SessionID` per connection (fixes #216) |
| 2026-11-06 | [Router join: one session ticket, one join attempt at a time](2026-11-06-router-join-session-ticket.md) | done | #230 (#99, #97); the resolved-player check for a `CanJoin` that maps aliases is #234 |
| 2026-11-11 | [Refuse a stale join by the resolved player](2026-11-11-refuse-stale-join-by-resolved-player.md) | open | #234; the keeper asks the transport in the segment of the CanJoin decision, on the in-turn path; the legacy path keeps the requested-player check |
| 2026-11-06 | [Bound a session's inbound task chain](2026-11-06-inbound-chain-bound.md) | done | #235 (#113): read backpressure in `WebSocketSessionHandler` |
| 2026-11-06 | [Late sync folds: count a fold as late only beyond the coincident window](2026-11-06-late-sync-folds.md) | open | #232; rev 2 (review GO folded in): lateness at the tick turn, keeps `syncOverdueFolds` as is |
| 2026-11-06 | [assertConverged: retry an inconclusive check, fail it under gating](2026-11-06-converged-inconclusive-retry.md) | open | #226; rev 2 (review GO folded in) |
| 2026-11-08 | [Action completion queue: a session's line no longer waits on an action's resolvers](2026-11-08-action-completion-queue.md) | partial | PRs 1–3 (tick lands; #326, #328, #329 on `exp/action-completion-queue`) merged to `main` with the maintainer's OK. Open: PR 4, tickless lands, after #325 |
| 2026-11-10 | [A throwing handler's writes: validate before you mutate, and a debug-build warning](2026-11-10-throwing-input-debug-warning.md) | open | #87 part B; this PR. A (undo-log rollback) is step 3 |

## Reevaluation and replay

| Date | Plan | Status | Evidence |
|---|---|---|---|
| — | [Deterministic replay: spec](specs/001-deterministic-replay/spec.md) | done | #30; later renamed from replay to reevaluation (`ReevaluationRunner`, `ReevaluationRecordMetadata`) |
| — | [Deterministic replay: technical plan](specs/001-deterministic-replay/plan.md) | done | #30 |
| 2026-02-15 | [Server-side reevaluation replay stream](2026-02-15-server-reevaluation-replay-stream.md) | done | #43; the replay-only land was later replaced by the same-land path (2026-02-20) and generic replay land v2 (#46) |
| 2026-02-15 | [Server reevaluation replay stream: verification](2026-02-15-server-reevaluation-replay-stream-verification.md) | done | #43 |
| 2026-02-15 | [Server replay compatible mode](2026-02-15-server-replay-compatible-mode-plan.md) | done | #43 (`ReplayProjector`) |
| 2026-02-18 | [Hero Defense replay live-state unification](2026-02-18-hero-defense-replay-live-state-plan.md) | done | #43; the dedicated replay land was removed in #46 |
| 2026-02-19 | [Replay generic baseline checklist](2026-02-19-replay-generic-baseline-checklist.md) ([zh-TW](2026-02-19-replay-generic-baseline-checklist.zh-TW.md)) | done | Tag `replay-baseline-v1`; #43 |
| 2026-02-19 | [Replay generic session mode](2026-02-19-replay-generic-session-mode-plan.md) ([zh-TW](2026-02-19-replay-generic-session-mode-plan.zh-TW.md)) | done | #43 (`ReevaluationFeature`, replay event policy, generated session composable) |
| 2026-02-20 | [Low-risk same-land reevaluation stream](2026-02-20-low-risk-same-land-reevaluation-plan.md) ([zh-TW](2026-02-20-low-risk-same-land-reevaluation-plan.zh-TW.md)) | done | #43 (`registerWithReevaluationSameLand`, `ReevaluationReplaySessionDescriptor`, reevaluation output mode) |
| 2026-02-20 | [Same-land reevaluation: verification report](2026-02-20-low-risk-same-land-reevaluation-verification.md) ([zh-TW](2026-02-20-low-risk-same-land-reevaluation-verification.zh-TW.md)) | done | #43 |
| 2026-02-21 | [Per-frame state recording and diff: design](2026-02-21-per-frame-state-recording-diff-design.md) | done | #45 (`ENABLE_STATE_SNAPSHOT_RECORDING`, `--diff-with`) |
| 2026-02-21 | [Per-frame state recording and diff: plan](2026-02-21-per-frame-state-recording-diff-plan.md) | done | #45 |
| 2026-02-21 | [Server event recording and verification: design](2026-02-21-server-event-recording-verification-design.md) | done | #45 |
| 2026-02-21 | [Server event recording and verification: plan](2026-02-21-server-event-recording-verification-plan.md) | done | #45 |
| — | [Generic replay land v2: design and v1 learnings](generic-replay-land-v2-design.md) | superseded | Replaced by the [v2 POC design](2026-02-23-generic-replay-land-v2-poc-design.md) (macro-generated snapshot decoding) |
| 2026-02-23 | [Generic replay land v2: POC design](2026-02-23-generic-replay-land-v2-poc-design.md) | done | #46 |
| 2026-02-23 | [Generic replay land v2: implementation](2026-02-23-generic-replay-land-v2-impl.md) | done | #46 (`SnapshotValueDecodable`, `GenericReplayLand`) |
| 2026-02-23 | [Generic replay land v2: integration recovery](2026-02-23-generic-replay-land-v2-integration-recovery.md) | done | #46 (`registerWithGenericReplay`; `HeroDefenseReplayLand` removed) |
| 2026-11-04 | [Replay sequence watermark](2026-11-04-replay-sequence-watermark.md) | done | #72 (#50); the two known limitations stay in #66 |
| 2026-11-05 | [Sync-output replay verification](2026-11-05-sync-output-replay.md) | done | PR 1 #120, 2a #125, 2b #133, 3a #136 (#115), 3b #140, 3c #147. The independent view oracle is tracked in #130 |
| 2026-11-05 | [Full-state replay hash](2026-11-05-full-state-hash.md) | open | #180; design checked 2026-11-05; PR #185 |
| 2026-11-07 | [Streaming record format (record 3.0)](2026-11-07-streaming-record-format.md) | open | #245; rev 3.1, canonical MessagePack (maintainer), review GO |
| 2026-11-09 | [Recorder flush at a turn boundary signalled by the keeper](2026-11-09-recorder-turn-boundary-flush.md) | open | #327 (option A); review GO on the plan |
| 2026-11-09 | [Tickless replay in recorded apply order, with per-pass sequence watermarks](2026-11-09-tickless-replay-passes.md) | open | #325 with #321; record format 3.1 (`passes`); review GO |

## State encoding and send path

| Date | Plan | Status | Evidence |
|---|---|---|---|
| — | [Broadcast encoding optimization: problem note](broadcast-encoding-optimization.md) | done | #32, implemented through the 2026-01-30 plan |
| 2026-01-30 | [Broadcast encoding optimization](2026-01-30-broadcast-encoding-optimization.md) ([zh-TW](2026-01-30-broadcast-encoding-optimization.zh-TW.md)) | done | #32 |
| 2026-11-07 | [Atomic values: one declaration, positional encoding](2026-11-07-atomic-values-positional-encoding.md) | open | rev 2, review GO; replaces the shape and name heuristics, positional wire form for opcode-array encodings |
| 2026-11-07 | [Path index and same-parent field merge for opcode state updates](2026-11-07-path-index-and-field-merge.md) | open | rev 3; rank of the schema path hash per land, merged entries (ops 4/5) with a 32-bit field mask that keep same-entity order, client-declared state-update features at join |
| 2026-11-10 | [Flat per-type state storage (#379 stage 1)](2026-11-10-flat-state-storage.md) | open | Decided 2026-11-10 (views over tables, per-land wire IDs with an overflow guard, permanent package-level "off", object-level per-row visibility reserved for stage 2); step 0 in progress. Per-type tables with generational handles and parent links, dirty rows per table, typed diff off `SnapshotValue`, monotonic wire IDs and row-addressed patches (#392); step 0 canonical emit order; step 1 hand-written bound with a fixed stop bar |
| 2026-11-10 | [Flat storage step 2: typed sync tables behind today's API](2026-11-10-flat-storage-step2.md) | open | Reviewed; section 1 decided 2026-11-10: tables on the sync side, live state stays native structs; overload-resolved field kinds with a per-field fallback to today's diff; typed patches with pre-split addresses; firstSync and resync on today's path with table seeding; four PRs behind a package switch, byte-identity and differential gates |
| 2026-11-10 | [Flat storage step 3: row addressing on the wire (#392)](2026-11-10-row-addressing.md) | open | Reviewed (two rounds). Slots on the wire with a generation in the create entry, superseding the parent plan's never-reused wire IDs; create, delete, column set and column clear entries behind `rowAddressing`, only where every join completes in a turn; full views take the staged or the committed table by recipient; per-row drops; records unchanged; NFC keys and `PlayerID` (#446) first, with record version 3.3; then #87's rollback and the non-`Equatable` warning |
| 2026-11-11 | [Flat storage step 3, PR E: typed conversion of changed leaves](2026-11-11-typed-leaf-conversion.md) | open | Reviewed (two rounds), GO. A per-field leaf writer chosen at registration for fields the macro marks `.standard`, same-value on the converted form, a release guard on the marker; part 1 typed `SnapshotValue` (skips the old value's conversion and the snapshot diff), part 2 (conditional) the opcode encoders without `SnapshotValue`; `TYPED_LEAF_VALUES`, default off; differential, byte-identity and oracle gates; same-binary A/B on the router path |
| 2026-11-12 | [Change-object metrics on the sync tables without a broadcast snapshot](2026-11-12-change-count-from-rows.md) | open | Reviewed, GO. On the tables, root node maps take the metric's keys and total from their entry count, with no snapshot conversion; other root fields keep today's helpers on a smaller extraction. Equal to today on every sync (switch flips unchanged); the old computation stays as the test oracle until step 2's PR 4 removes the metric |
| 2026-11-12 | [Resolve the atomic layout node once per pattern in the opcode encoders](2026-11-12-atomic-node-once-per-pattern.md) | open | Reviewed, GO. An index from pattern hash to layout node built once per encoder; a pattern whose `*` step leaves a node with named children keeps the string walk; byte identity and a node-level differential; host A/B on syncMs (default, router and rows cells) with frame digests |
| 2026-11-12 | [Sync policy per type, not per wrapper (#520)](2026-11-12-sync-policy-per-type.md) | done | Rev 2. Direction decided 2026-11-12: `Sync` keeps the value and the dirty flag, `@StateNodeBuilder` emits each field's policy as a static, `@Sync(.policy)` unchanged. Trade-offs T1–T4 decided the same day. Merged as #527 (9bf7df61) |
| 2026-11-13 | [Per-player fields on typed per-player sync tables (#514)](2026-11-13-per-player-sync-tables.md) | open | Draft for review. Step 2's PR 3: the filter keeps running on the native value; its output is diffed against per-player typed boxes that are not slot-addressed; a share measurement first (stop under 15 %); one PR on by default with `PER_PLAYER_SYNC_TABLES` as the opt-out; byte identity against today's path; host A/B under the off-path instruction gate; lands after row addressing's default flip |
| 2026-01-30 | [Opcode 107 performance fix](2026-01-30-opcode-107-performance.md) | done | #32 |
| 2026-02-03 | [Queue-based WebSocketTransport send path](2026-02-03-queue-based-transport-send.md) | done | #34, #36; the transport-wide send queue was later replaced by the ordered per-land writer (#86) |
| 2026-02-03 | [P2 optimization analysis (`compareSnapshotValues`, `SnapshotValue.make`)](2026-02-03-p2-optimization-analysis.md) | open | Analysis only; it defers P2, and `escapeJsonPointer` on `main` is unchanged |

## Transport and NIO

| Date | Plan | Status | Evidence |
|---|---|---|---|
| 2026-02-01 | [Membership queue and reconnection semantics](2026-02-01-membership-queue-reconnect.md) | done | #32 |
| 2026-02-02 | [NIO WebSocket transport](2026-02-02-nio-websocket-transport-design.md) | done | #34; Hummingbird removed in #37 and archived in `Archive/SwiftStateTreeHummingbird` |
| 2026-02-10 | [TransportAdapter pipeline refactor](2026-02-10-transport-adapter-pipeline-refactor.md) | done | #38 (`Sources/SwiftStateTreeTransport/Pipeline/`) |
| 2026-02-10 | [MembershipCoordinator wrapper removal](2026-02-10-membership-coordinator-wrapper-removal-plan.md) | done | #38 |
| 2026-11-06 | [Send queue backlog](2026-11-06-send-queue-backlog.md) | open | #61; step 1 (measurement) next, A vs B undecided |
| 2026-11-06 | [Deadlines on cross-boundary awaits](2026-11-06-cross-boundary-deadlines.md) | done | #237 (core), #239 (transport, budget A); follow-ups #238, #240, #242 |
| 2026-11-07 | [A failure policy for OnInitialize's resolvers](2026-11-07-init-resolver-failure-policy.md) | open | #238; rev 1, option C, default `.failLand` |
| 2026-11-11 | [Bound what a hung resolver costs](2026-11-11-bound-hung-resolver-cost.md) | open | #364. PR 1: an abandonment on every deadline call, per-kind gauges, a per-land action cap. Open: PR 2, the leak transition (#498); PR 3, the maintainer's decisions |
| 2026-11-09 | [Sync lag from client acks](2026-11-09-sync-lag-from-client-acks.md) | open | #332; design note for Review: per-land sync sequence behind a required `syncSequence` feature, `syncAck` (108), lag check in the adapter, close codes 4009–4011 |
| 2026-11-09 | [Graceful server shutdown](2026-11-09-graceful-shutdown.md) | open | #351, PR #372; decided (A1, B2, C, C2a, the awaited `run()` cancel): signal helper, ordered host shutdown under `Lifecycle`, awaited leaves with a land-level cut at the deadline, bounded wait that abandons a hung destroy. Follow-ups: #382 (forceShutdown as a turn), #373 (A/B: passed 2026-11-10, recorded in the plan) |
| 2026-11-11 | [A session goes to the land instance it joined (#390); the admin DELETE stops the land (#102)](2026-11-11-route-sessions-to-their-instance-and-stop-land.md) | open | PR A (#390): this PR. PR B (#102): `stopLand`, 4014 `landStopped`, the public `removeLand` removed, the stop bounded by `shutdownTimeout` |
| 2026-11-11 | [The WebSocket server's start and stop, and the transport's stop (#101)](2026-11-11-server-and-transport-lifecycle.md) | open | Not started. The server under `Lifecycle` (a failed start shuts its event-loop group down; a start after a shutdown logs and doesn't serve, decided); the transport's stop detaches first and rejects connections while stopped with a new `ConnectionRejection.transportStopped` (decided) |
| 2026-11-06 | [Action idempotency key](2026-11-06-action-idempotency-key.md) | superseded | #103 not adopted (2026-11-06): no transport-level key; dedup in land state instead, documented in `docs/core/land-dsl.md` ("Actions that must apply at most once") |

## Matchmaking and control plane

The Swift in-process matchmaking module is archived in `Archive/`; matchmaking now lives in the NestJS control plane in `Packages/control-plane`.

| Date | Plan | Status | Evidence |
|---|---|---|---|
| 2026-02-12 | [Matchmaking control plane design](2026-02-12-matchmaking-control-plane-design.md) | done | #41 |
| 2026-02-12 | [NestJS matchmaking control plane](2026-02-12-nestjs-matchmaking-control-plane-implementation-plan.md) | done | #41 |
| 2026-02-14 | [Provisioning REST API migration](2026-02-14-provisioning-rest-api-migration-plan.md) | done | #41 (provisioning merged into the control plane; `ProvisioningHTTPClient`) |
| 2025-02-15 | [Matchmaking BullMQ + WebSocket, phase 1](2025-02-15-matchmaking-bullmq-ws-phase1.md) | done | #42 |
| 2026-02-15 | [Matchmaking MVP fill group: design analysis](2026-02-15-matchmaking-mvp-fill-group-design-analysis.md) | done | #42 |
| 2026-02-15 | [Matchmaking MVP fill group: plan](2026-02-15-matchmaking-mvp-fill-group-implementation-plan.md) | done | #42 (`findMatchableGroups`) |
| 2026-02-15 | [Phase 2: ClusterDirectory and node inbox](2026-02-15-phase2-cluster-directory-node-inbox.md) | done | #42 |
| 2026-02-15 | [Pub/sub module](2026-02-15-pubsub-module-implementation-plan.md) | done | #42 (`MatchAssignedChannel`) |
| 2026-02-20 | [Control plane admin UI: design](2026-02-20-control-plane-admin-ui-design.md) | done | #42 (`Packages/control-plane-admin-ui`) |
| 2026-02-20 | [Control plane admin UI: plan](2026-02-20-control-plane-admin-ui-implementation-plan.md) | done | #42 |
| 2026-02-21 | [Matchmaking comprehensive E2E tests](2026-02-21-matchmaking-comprehensive-e2e-test-plan.md) | partial | Scenarios and scripts in #42. Open: the CI job `e2e-matchmaking-tests` is disabled (#52) |
| 2026-02-22 | [ClusterDirectory: UserIdDirectory + ServerIdDirectory, design](2026-02-22-cluster-directory-userid-serverid-design.md) | done | #44 |
| 2026-02-22 | [ClusterDirectory: UserIdDirectory + ServerIdDirectory, plan](2026-02-22-cluster-directory-userid-serverid-implementation-plan.md) | done | #44 |
| 2026-02-22 | [Matchmaking ticket ID and env loading fixes](2026-02-22-matchmaking-ticket-env-fixes.md) | done | #44 |

## Load testing and benchmarks

| Date | Plan | Status | Evidence |
|---|---|---|---|
| 2026-02-01 | [ws load test for Hero Defense: design](2026-02-01-uws-loadtest-design.md) ([zh-TW](2026-02-01-uws-loadtest-design.zh-TW.md)) | done | #33 (`Examples/GameDemo/ws-loadtest`) |
| 2026-02-01 | [ws load test for Hero Defense: plan](2026-02-01-uws-loadtest-implementation-plan.md) | done | #33 |
| 2026-02-01 | [Load test and reevaluation toggle](2026-02-01-uws-loadtest-and-reevaluation-toggle.md) | done | #33 (`ENABLE_REEVALUATION`) |
| 2026-02-01 | [Server metrics file](2026-02-01-server-metrics-file-design.md) | open | Not implemented: `METRICS_OUTPUT_PATH` appears only in this plan |

## Experiments

| Date | Plan | Status | Evidence |
|---|---|---|---|
| 2026-08-31 | [Experiment: active-player workload for single-room entity scaling](2026-08-31-active-players-experiment-design.md) | done | Commits 1fb0d4b, 44fd14f; [`deep-research/single-room-entity-scaling/`](../../deep-research/single-room-entity-scaling/) |
| 2026-08-31 | [Experiment: replay verification at scale and FP perturbation](2026-08-31-replay-scale-fp-perturbation-experiment-design.md) | done | #47; [`deep-research/replay-scale-fp-perturbation/`](../../deep-research/replay-scale-fp-perturbation/) |
| 2026-11-07 | [Entity-delta baseline (Quake 3–style) on the hero-defense workload](2026-11-07-entity-delta-baseline.md) | open | Rev 2 after the design check. Steps 1–3 on main (encoder, TypeScript decoder and gate, metrics, topic scripts); the host run waits for the refreeze |
| 2026-11-07 | [Experiment: network impairment (delay, jitter, loss, throttle, outage)](2026-11-07-network-impairment-experiment-design.md) | open | Rev 5.4: 27 planned runs at 300 rooms (U, M, SR), full matrix as an extension; per-session close causes from the lifecycle log (#265); jitter runs with reordering on the measurement host; design check GO; missing inputs fail; rate cells gated on queueing delay, COMBO's delay calibrated without its rate; host checklist in § 10; sync-lag criteria: SR by 4010 after one resync, BO75 admits 4011, RATE and COMBO report the impaired window and gate the last 10 s |
| 2026-11-08 | [Experiment: per-player visibility under movement](2026-11-08-visibility-experiment-design.md) | open | Rev 2, design only: capture and record the generic runner, radius/entity/viewer/ticks-per-sync knobs with an identity-filter control, tick and sync timed apart, verify-views + per-player replay + radius/all consistency gates |
| 2026-11-08 | [Experiment: external inputs that fail or time out](2026-11-08-external-input-failure-experiment-design.md) | open | Rev 2, design only: failure rate × which deadline fires × cancellation, server-side tick gaps, one process per cell, expected-failure counters and per-tag accounting, end driven by the abandoned gauge, replay and convergence gates |
| 2026-11-09 | [Core round and full rerun](2026-11-09-core-round-and-full-rerun.md) | open | Held PRs, #327, #325 with #321, the action completion queue, sync-lag resync from client acks, the network-impairment recovery criterion, then one refreeze and a rerun of every topic |
| 2026-09-15 | [Full-snapshot sync baseline: design](specs/2026-09-15-snapshot-baseline-design.md) | done | #53, #56, #57; [`deep-research/snapshot-baseline/`](../../deep-research/snapshot-baseline/) |
| 2026-09-15 | [Full-snapshot sync baseline: implementation](2026-09-15-snapshot-baseline-implementation.md) | done | #53 (`SyncStrategy`) |

## Web client and tools

| Date | Plan | Status | Evidence |
|---|---|---|---|
| 2025-01-20 | [WebClient UI shell refactor](2025-01-20-webclient-ui-shell-refactor.md) | done | #28 (`DemoLayout`, `ConnectionStatusCard`) |
| 2026-11-09 | [Server-originated turn inputs](2026-11-09-server-turn-inputs.md) | open | #387. PR 1: keeper, DSL, record/replay. Open: PR 2, the monitor migration |
| 2026-11-13 | [Off-path A/B gates judge instructions, not time](2026-11-13-off-path-instruction-gate.md) | partial | #517. Done: the EncodingBenchmark perf window (24600fe5). Open: the brief and summary-script changes, the first set run under both rules, the bar's calibration |

---
module: SwiftStateTreeTransport
date: 2026-11-19
problem_type: testing_practice
component: transport-env-config
symptoms:
  - "a test passes transportEnvConfig: yet behaves differently when USE_SYNC_TABLES or TYPED_LEAF_VALUES is set"
  - "a CI job that sets an env flag runs a combination of a test nowhere else"
  - "filtering a job to the targets that 'read the flag' would silently drop a combination"
root_cause: stored_property_defaults_read_the_environment_for_every_init
resolution_type: design_rule
severity: medium
tags:
  - testing
  - environment
  - transport-env-config
  - sync-tables
  - ci
  - test-selection
related:
  - "#642"
  - "Notes/plans/2026-11-19-ci-test-audit.md"
---

**Problem.** The CI test audit planned to filter the `sync-tables-off` job (`USE_SYNC_TABLES=false`, `TYPED_LEAF_VALUES=false`) to the Transport and NIO targets. Its premise was that the core tests that pass `transportEnvConfig:` to their adapter can't read the flags. Three of them did read one: their helpers set `useSyncTables`, but not `typedLeafValues`. So in that job their tables-on cells ran with typed leaf values off, a combination no other job ran, and the filter would have dropped it without a sign.

**Root cause.** `TransportEnvConfig.useSyncTables`, `perPlayerSyncTables` and `typedLeafValues` are stored properties whose defaults are statics read from the process environment. Every config gets them, one built with `init` included, so a whole test run can be switched from outside. Passing an explicit config pins only the properties the test sets. "Passes a config" and "doesn't read the environment" are different claims.

**Fix.** The three helpers pin `typedLeafValues` too (typed leaf values off stays covered explicitly by `SyncTablesByteIdentityTests`). `DebugProjectionWireShapeTests`, which built its adapter with no config, got explicit cells for both diff paths. `scripts/check-filtered-tests-pin-transport-env.sh` (#642) now fails if a test outside the filter could read the flags: an adapter without a config or with a possibly nil one, a config that doesn't set both flags in its function body, or a land manager or router, which build adapters from the environment.

**Prevention.**
- **To pin a config, set every property whose default is read from the environment.** Constructing it explicitly is not enough. Read the type's property defaults, not only its `init`.
- **Before narrowing a job that sets an env flag, find every reader of the flag,** including stored-property defaults and `?? fromEnvironment` fallbacks. Then make the narrowing checkable: a static check that fails when a test outside the filter could reach a reader. Keep the full run on the nightly as the backstop (safe regression test selection: leave out only the tests that can't reach the change).
- **A read counter can't replace that check here:** every init evaluates the defaults, so it counts pinned and unpinned configs alike.

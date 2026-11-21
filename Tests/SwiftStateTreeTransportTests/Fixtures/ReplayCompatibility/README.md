# Replay compatibility records

Re-evaluation records of the verifier test land (`makeVerifierLand` in
`SyncOutputVerifierTests.swift`) made by an earlier build, for a scenario whose recording a later
change altered. They are never regenerated: they pin that a record made before the change still
replays. `ReplayCompatibilityRecordTests` replays each and requires every hash reproduced and the
sync-output verdict `passed`.

| File | Made by | What it holds |
|------|---------|---------------|
| `freeze-resume-legacy-cycle-messagepack` | `main` at a7ed4d2b (a copy of that build's `freeze-resume-messagepack` golden) | a debug freeze settle recorded as a `legacyCycle` output |
| `settle-failure-queued-tick` | `main` at a7ed4d2b (`DebugFreezeSettleFailureTests`' scenario) | a settle whose plan throws: the failure is submitted and applied by the next tick, whose frame ends its inputs |

Since #546 L2d-1 the settle is a sync-only turn: it records a `syncOnly` output, and its failure
ends the land in the settle's own turn.

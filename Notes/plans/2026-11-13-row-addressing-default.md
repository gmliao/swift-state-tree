# Row addressing on by default (#392, flat storage PR F)

Parent plan: `2026-11-10-row-addressing.md` (section 9, PR F; section 15, point 4).

## 1. What flips

| Where | Before | After | Opt-out |
|---|---|---|---|
| `TransportEncodingConfig` inits, `rowAddressing:` default; the `.jsonOpcode`, `.opcode` and `.messagepack` presets follow it | false | true | `.withRowAddressing(false)` |
| `ROW_ADDRESSING` / `rowAddressingFromEnvironment()` | default false | default true | `ROW_ADDRESSING=false` |
| ws-loadtest `--row-addressing` (joins declare `rowAddressing`) | default off | default on | `--row-addressing off` |
| EncodingBenchmark `--row-addressing` | default off | not given: on with `--join-through-router on` and a `-pathhash` format, off otherwise | `--row-addressing off` |

- The env opt-out reaches only code that reads the env: GameServer, DemoServer and ServerLoadTest (which now reads it). In-process presets and test fixtures opt out with `.withRowAddressing(false)`.
- `.json` (object state updates) is unchanged in effect: `effective(pathHashes:)` drops the feature without opcode state updates. `NIOLandHost`'s default encoding is `.json`.
- Where it still doesn't take effect, unchanged:
  - no path hashes;
  - `pathIndex` or `syncSequence` off;
  - a keeper that isn't `.live`;
  - in-turn sync off;
  - joins not through the router.

  The adapter's effective features and its startup log say which.
- The router's pre-land check stays without `rowAddressing`. A land with it in effect refuses a join that doesn't declare it (`JOIN_STATE_UPDATE_FEATURE_MISSING`), so a client that didn't negotiate rows never receives them.

**Public API:** default values only. The source compiles unchanged; the behaviour changes for a caller that relied on the default.

## 2. `USE_SYNC_TABLES=false` after the flip (decided 2026-11-13: option B)

Row addressing needs the sync tables, so with it in effect the tables stay on whatever `USE_SYNC_TABLES` says.
- **(B), chosen:** row addressing wins. The adapter warns once at startup: "USE_SYNC_TABLES=false is ignored: row addressing is in effect and needs the sync tables. Set ROW_ADDRESSING=false too for the snapshot-diff (legacy) path." The docs and the FAQ say the same.
- **(A), rejected:** `USE_SYNC_TABLES=false` also turns rows off, and an explicit `ROW_ADDRESSING=true` with it refuses at startup.
- **Reason:** `USE_SYNC_TABLES=false` is a temporary fallback, expected to be removed before release, so it isn't worth (A)'s test migration. (A) would have reversed the test that rows turn the tables on, and needed every row-requiring test to inject its env config for the tables-off CI job.

## 3. Tests

- **The default pins flip:** `.messagepack.rowAddressing`, the init default and `rowAddressingFromEnvironment([:])` are true, and `ROW_ADDRESSING=false` is the opt-out.
- **What the flip moved.** The full suite was run with the flip. Three tests failed, all pins of the old default.
  - The field-merge config test now expects the row feature in the requested list.
  - The path-index tests pin rows off: they are about the path-entry form.
  - The benchmark-diagnostics "without rowAddressing" case turns it off explicitly.

  Most in-package fixtures don't reach rows, which need router joins, the sync sequence and path hashes together, so their expectations didn't move.
- **Arm assertions.** The tables on/off frame-identity test asserts each arm ran what it says (tables, no rows). With rows in effect, a tables-off arm would quietly run the tables.
- **New tests:**
  - **Golden scenarios through the router:** two router-joined runs of each golden scenario, identical but for the feature (`VerifierFixture.makeThroughRouter`). They record the same frames and sync stream and replay to the same summary (parent section 6, option 1). Each arm asserts its rows. The env config is injected, so it holds in the tables-off job. A router run can't be compared byte for byte with the direct-join goldens, because its joins are scheduled differently.
  - **Dirty tracking on and off on the row path:** the same frames. Each arm asserts rows, tables and its dirty tracking, and row entries were sent.
  - **The (B) warning:** once with rows in effect and the tables off; not with both off, or with the tables on.

## 4. Examples and tools

- **EncodingBenchmark:**
  - `--row-addressing` is on, off or not given. Not given, it resolves as in section 1 and is never refused. An explicit `on` keeps the refusals and the in-effect check.
  - The result's `config` records `rowAddressing` as given (null when not given) and `rowAddressingResolved`. `routerJoin.rowAddressingInEffect` is what ran.
  - The local path's encoding has rows off.
  - A router capture's header names the features the lands negotiated. verify-views passes either way, since it decodes without the runtime's negotiation check; the header is now accurate.
- **`check-encoding-benchmark-router.sh`:** covers the default, explicit on and off, a router run that resolves off, and the commands that run without the flag. The router refusals are unchanged.
- **ServerLoadTest** reads `ROW_ADDRESSING`. **ws-loadtest** declares the feature by default.

## 5. CI

- **Main E2E step:** the default path.
  - The in-turn leg checks rows with `check-row-addressing-run.sh`: every opcode join negotiated rows and applied row patches, and json had none.
  - The in-turn-off leg checks with the new `--expect-off`.
- **Opt-out step:** `ROW_ADDRESSING=false`, both legs, all three encodings, `--expect-off`.
  - It alone runs the tables-off variant (`USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false`), which is an opt-out only with rows off.
  - `test-e2e-game.sh` runs the variant only when `ROW_ADDRESSING` is explicitly false.
- **`build (sync tables off)`:** its comment says what it still covers: direct-adapter tests and those without router joins, the sync sequence or path hashes. The fallback under a router join is covered by the tests that turn rows off explicitly.

## 6. Data and measurement

- **deep-research (a separate commit on main):** the wire form gains row addressing, read from negotiated features. A record without a feature list is resolved by ancestry against the feature's introduction (6f7920c0, #491). The intended form of a GameServer environment models rows from their prerequisites. Numbers across this change aren't comparable on router or ws-loadtest paths.
- **The A/B, after merge, on the measurement machine.** Arms: base, head, and head with every opt-out.
  - **EncodingBenchmark, under the off-path instruction gate:**
    - base and head-off must be equal in bytes and digests, judged on instructions;
    - the router cell's head against head-off is the row form's cost, reported;
    - verify-views on head's router capture.
  - **ws-loadtest at 500 and 1000 rooms, against GameServer:**
    - head against base is the cost shipped, reported;
    - head-off must be within +2 % CPU and +1 ms RTT of base;
    - one round with `--reconstruct`: row entries > 0, no 4013, converged.
  - **ServerLoadTest:** reported.

## 7. Solutions consulted

- `Notes/solutions/2026-11-12-an-equality-trace-misses-a-key-bug-when-keys-collide.md`: the arm-assertion rule.
- `Notes/solutions/2026-11-11-a-second-staging-undoes-an-edit-to-the-first.md`: row addressing staging.
- `Notes/solutions/2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`: the A/B's perf runs.

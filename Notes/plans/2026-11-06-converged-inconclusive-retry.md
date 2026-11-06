# assertConverged: retry an inconclusive check, fail it under gating (#226)

Status: open, rev 2. Rev 1 was reviewed GO with no blocking finding. Rev 2 logs a discarded mismatch on its inconclusive line, makes retries visible per scenario, pins resume on every attempt's paths, and notes when to raise the retry delay.

## Problem

`runAssertConverged` (`Tools/CLI/src/cli.ts`) runs one convergence check: freeze the land, wait for the settle frames, compare each client's state with the server's projection, resume. When a join or leave lands between the settle copy and the projection, the server marks the projection `membershipChanged` (`TransportAdapter.debugProjection`: the membership epoch differs from the one read before the copy). The CLI then prints `CONVERGENCE INCONCLUSIVE (membership changed)`, counts it as inconclusive and returns success, **with gating on too**. A scenario whose check falls in that window passes without having compared anything.

It was found in the review of #224: `scenarios/game/test-join-supersede.json` replaces a session right before its `after-supersede` check, and the old session's leave can land inside the check.

## Change

1. **Move the step's decision into `convergence.ts`,** as `runConvergenceAttempts(check, options)`. `check` is a function returning one `ConvergenceResult`; in the CLI it's the existing `checkConvergence(...)` call. The options are `maxAttempts`, `retryDelayMs`, `gating` and a `sleep` the tests replace. That keeps the retry logic testable without a server, next to the code it extends. `runAssertConverged` keeps the logging and the stats.
2. **Retry an inconclusive result.** Up to `maxAttempts` checks in all, default 3, with `retryDelayMs` between them, default 200 ms: two sync intervals of the game land, enough for a pending join or leave to complete. Each attempt is a full freeze, settle, projection and resume, so a later attempt checks the current state with its own freeze token. The step's first conclusive attempt decides it:
   - converged → success;
   - mismatch → a mismatch, as today (fatal under gating, reported otherwise).

   A mismatch inside an inconclusive attempt doesn't count toward the verdict: membership changed, so the comparison isn't valid. It isn't dropped silently either. That attempt's `CONVERGENCE INCONCLUSIVE` line carries the mismatch's path count and first path, so a mismatch that is still there after the retry shows it was there before too.
3. **All attempts inconclusive:** under gating the step fails with `State convergence was inconclusive after N attempts (<label>); membership kept changing`. Without gating it's reported and counted, as today.
4. **Per-step overrides** in the step's `assertConverged` config: `maxAttempts` (≥ 1; `1` keeps today's single attempt) and `retryDelayMs`. They're documented in the README next to `label`, `quietMs`, `settleTimeoutMs`.
5. **Output:**
   - Each inconclusive attempt prints the existing `CONVERGENCE INCONCLUSIVE` line with ` attempt=i/N` added, and ` mismatchedPaths=<n> first=<path>` when its comparison differed. The marker prefix is unchanged, so a grep still finds it.
   - The final summary keeps its keys, and their meaning stays per step: `checks`, `converged`, `mismatches`, and `inconclusive`, which now means steps that ended inconclusive.
   - It adds `retried=<steps that needed more than one attempt>` and `attempts=<total checks run>`. Nothing in the repo parses the summary line; the E2E scripts grep only the mismatch markers.
   - The summary is printed per scenario, so a retry shows which scenario it came from. A rise in `retried` across runs is a signal of its own. The change's commit note gives the `retried` count of `test-join-supersede`.
6. **Resume on every path.** `checkConvergence` already resumes in its `finally`. Each attempt is one `checkConvergence` call, so every attempt that froze the land resumes it: a conclusive one, an inconclusive one, and one that throws after the freeze. A retry never starts with the land frozen. A unit row pins it.
7. **README:** a land whose join or leave resolvers are slow needs a larger `retryDelayMs`.

## Not changed

- The server side and the inconclusive rule itself: `membershipChanged` is the right signal, and the CLI only stops treating it as a pass.
- No per-step opt-out to accept an inconclusive result under gating. No scenario in `scenarios/` needs one; it can be added when one does.
- Infra errors (route, auth, timeout, projection token) stay fatal on the first attempt and aren't retried: they aren't the membership race.

## Tests

- **Unit, in `scripts/internal/test-convergence.ts`** (no server), with a fake `check` returning scripted results and a recording `sleep`:
  - inconclusive, converged → success after 2 attempts, one sleep of `retryDelayMs`;
  - inconclusive, mismatch → a mismatch, fatal with gating, reported without;
  - inconclusive ×3, gating → throws the inconclusive error after exactly 3 checks;
  - inconclusive ×3, no gating → no throw, counted inconclusive;
  - `maxAttempts: 1` → today's behaviour, one check;
  - an infra error on attempt 1 → rethrown, no retry;
  - with the fake debug server: `check` throws after a recorded freeze → resume is still called exactly once, and no second freeze follows;
  - an inconclusive attempt whose comparison differed → its line carries `mismatchedPaths` and the first path, and the mismatch isn't counted.
- **Mutation checks:** an off-by-one in the attempt limit, the gating check skipped on all-inconclusive, a retry after a mismatch, and a retry after an infra error must each fail a test.
- **E2E:** `./Tools/CLI/test-e2e-ci.sh` and `./Tools/CLI/test-e2e-game.sh`. The game run includes `test-join-supersede`. Check their `CONVERGENCE SUMMARY` lines: `inconclusive=0` is the expected outcome. Any `retried` count gets reported in the change.

## Paths

`Tools/CLI/src/convergence.ts`, `Tools/CLI/src/cli.ts`, `Tools/CLI/scripts/internal/test-convergence.ts`, `Tools/CLI/README.md`. These aren't core paths, so the change goes straight to main after this plan's review, verified with `npm run test:cli:unit` and both E2E scripts.

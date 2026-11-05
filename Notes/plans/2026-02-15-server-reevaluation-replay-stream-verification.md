# Server Reevaluation Replay Stream Verification

## Scope

- Verify server-driven replay stream behavior for Hero Defense.
- Ensure replay stream works across all transport encodings.
- Keep client-side replay logic minimal (no local frame reconstruction path in this milestone).

## Verification Commands

From repository root:

```bash
swift test --filter ReevaluationReplayCompatibilityTests
swift test --filter NIOAdminRoutesReplayStartTests
./Tools/CLI/test-e2e-game.sh
```

Monitor proof flow (manual, 3 terminals):

```bash
cd Examples/GameDemo && ENABLE_REEVALUATION=true swift run GameServer
cd Examples/GameDemo/WebClient && npm run dev -- --host 127.0.0.1 --port 5173
cd /tmp/task5-playwright && npx playwright test monitor-proof.spec.mjs --config playwright.config.mjs --reporter=line
```

Run each command in a separate terminal so server and web client remain active while Playwright executes.

## Matrix

`./Tools/CLI/test-e2e-game.sh` now verifies:

- `json`
  - Hero Defense scenario suite
  - Reevaluation replay stream E2E
- `jsonOpcode`
  - Hero Defense scenario suite
  - Reevaluation replay stream E2E
- `messagepack`
  - Hero Defense scenario suite
  - Reevaluation record+verify E2E
  - Reevaluation replay stream E2E

## Latest Sample Result Snapshot (ephemeral)

- Snapshot time: 2026-02-18 18:24:43 CST
- `swift test --filter ReevaluationReplayCompatibilityTests`: PASS (`9 tests in 1 suite`)
- `swift test --filter NIOAdminRoutesReplayStartTests`: PASS (`6 tests in 1 suite`)
- `./Tools/CLI/test-e2e-game.sh`: PASS all encodings (`✅ All encoding modes passed!`)
- Replay stream E2E observed continuous tick progression (`✅ Replay stream completed; observedTicks=134`)
- Playwright CLI monitor proof: `PROOF_SUMMARY total=262 correct=262 mismatches=0 screenshot=/tmp/verification-proof.png`

## Notes

- Replay land remains read-only.
- Replay stream now uses live-compatible fields (`players`, `monsters`, `turrets`, `base`, `score`) as primary and removes legacy `currentStateJSON` from replay state sync fields.
- Proof screenshot captured at `/tmp/verification-proof.png`.
- Values in this snapshot section (timestamp, tick counts, `/tmp` paths) are local run artifacts and will change on subsequent verification runs.

## Final Gate Snapshot

- Snapshot time: 2026-02-18 18:32 CST
- `swift test`: PASS (`714 tests in 36 suites passed`)
- `cd Examples/GameDemo && swift test`: PASS (`72 tests in 3 suites passed`)
- `cd Examples/GameDemo/WebClient && npm run build`: PASS (`vite build completed`)
- `./Tools/CLI/test-e2e-game.sh`: PASS (`✅ All encoding modes passed!`)

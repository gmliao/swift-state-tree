# Server Reevaluation Replay Stream Verification

## Scope

- Verify server-driven replay stream behavior for Hero Defense.
- Ensure replay stream works across all transport encodings.
- Keep client-side replay logic minimal (no local frame reconstruction path in this milestone).

## Verification Commands

From repository root:

```bash
swift test
./Tools/CLI/test-e2e-game.sh
```

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

## Current Result Snapshot

- `swift test`: PASS
- `./Tools/CLI/test-e2e-game.sh`: PASS all encodings
- Replay stream E2E observed continuous tick progression (latest run: `observedTicks=82` in messagepack stage)

## Notes

- Replay land remains read-only.
- Replay stream state payload is currently exposed as serialized JSON text (`currentStateJSON`) in replay state sync fields.

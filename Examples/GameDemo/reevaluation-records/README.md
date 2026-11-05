# Hero Defense replay fixtures

Record format 2.5 (#154). The reader rejects older records as unsupported, so re-create these
with the current server whenever the record version changes.

| File | Used by | How it is made |
|------|---------|----------------|
| `1-hero-defense.json` | replay land list, manual replay | headless, byte-reproducible (below) |
| `2-hero-defense.json` | replay land list, manual replay (`Tools/CLI/scripts/playwright-replay-e2e.sh`) | headless, byte-reproducible (below) |
| `3-hero-defense.json` | `HeroDefenseReplayStateParityTests`, `Tools/CLI/src/verify-replay-record.ts` | live GameServer capture of a client-driven session (below) |

## 1 and 2: headless

From `Examples/GameDemo`, in release:

```bash
swift run -c release ReevaluationRunner --record --seed-id 1 --players 1 --move-every 30 --ticks 600 \
  --output reevaluation-records/1-hero-defense.json
swift run -c release ReevaluationRunner --record --seed-id 2 --players 1 --move-every 30 --ticks 520 \
  --output reevaluation-records/2-hero-defense.json
```

Check each with `swift run -c release ReevaluationRunner --input reevaluation-records/<file> --verify`.

## 3: live capture

A client-driven record with a lifecycle join and leave, a `PlaceTurret` client event and
`PlayerShoot` / `TurretFire` server events. From the repository root:

```bash
cd Examples/GameDemo && ENABLE_REEVALUATION=true swift run GameServer   # localhost:8080
# in another shell
cd Tools/CLI && npx tsx src/cli.ts script -u ws://localhost:8080/game/hero-defense -l hero-defense \
  -s scenarios/game/test-replay-near-base-shoot.json --state-update-encoding messagepack
```

The `--state-update-encoding` must match the server's encoding (GameServer defaults to
messagepack); the CLI's own default is `jsonObject`.

The scenario's client leaves at the end, the land is destroyed and the server writes
`reevaluation-records/hero-defense-<timestamp>-<id>.json`. Rename that file to
`3-hero-defense.json` and check it with
`swift run -c release ReevaluationRunner --input reevaluation-records/3-hero-defense.json --verify`.

Other `*.json` files in this directory are local recordings and are not tracked.

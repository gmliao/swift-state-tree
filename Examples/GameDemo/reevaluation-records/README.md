[English](README.md) | [中文版](README.zh-TW.md)

# Hero Defense replay fixtures

Record format 3.6 (#521): each record carries the land's schema fingerprint, and replay refuses a
record whose fingerprint is missing or differs from the current definition's. So re-create these
with the current server whenever the record version changes, and whenever a change to the
hero-defense land's types changes its fingerprint (`RecordSchemaFingerprintTests` pins it).

| File | Used by | How it is made |
|------|---------|----------------|
| `1-hero-defense.sstr` | replay land list, manual replay | headless (below) |
| `2-hero-defense.sstr` | replay land list, manual replay (`Tools/CLI/scripts/playwright-replay-e2e.sh`) | headless (below) |
| `3-hero-defense.sstr` | `HeroDefenseReplayStateParityTests`, `Tools/CLI/src/verify-replay-record.ts` | live GameServer capture of a client-driven session (below) |

The current files were recorded with Swift 6.4.2 (Apple Swift 6.4.2, swiftlang-6.4.2.1.9) on macOS.

## 1 and 2: headless

From `Examples/GameDemo`, in release:

```bash
swift run -c release ReevaluationRunner --record --seed-id 1 --players 1 --move-every 30 --ticks 600 \
  --output reevaluation-records/1-hero-defense.sstr
swift run -c release ReevaluationRunner --record --seed-id 2 --players 1 --move-every 30 --ticks 520 \
  --output reevaluation-records/2-hero-defense.sstr
```

Check each with `swift run -c release ReevaluationRunner --input reevaluation-records/<file> --verify`.

## 3: live capture

A client-driven record with a lifecycle join and leave, a `PlaceTurret` client event and
`PlayerShoot` / `TurretFire` server events. From the repository root:

```bash
cd Examples/GameDemo && ENABLE_REEVALUATION=true swift run -c release GameServer   # localhost:8080
# in another shell
cd Tools/CLI && npx tsx src/cli.ts script -u ws://localhost:8080/game/hero-defense -l hero-defense \
  -s scenarios/game/test-replay-near-base-shoot.json --state-update-encoding messagepack
```

The `--state-update-encoding` must match the server's encoding (GameServer defaults to
messagepack); the CLI's own default is `jsonObject`.

The scenario's client leaves at the end, the land is destroyed and the server writes
`reevaluation-records/hero-defense-<timestamp>-<id>.sstr`. Rename that file to
`3-hero-defense.sstr` and check it with
`swift run -c release ReevaluationRunner --input reevaluation-records/3-hero-defense.sstr --verify`.

The JSON records these replaced (format 2.5) have no fingerprint and no longer replay; the one the
canonical MessagePack tests encode is kept as `Tests/SwiftStateTreeTests/Fixtures/hero-defense-record-2.5.json`.
Other `*.json` and `*.sstr` files in this directory are local recordings and are not tracked.

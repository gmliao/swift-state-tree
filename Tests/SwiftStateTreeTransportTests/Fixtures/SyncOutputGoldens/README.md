# Sync-output golden recordings

Short re-evaluation records of the verifier test land (`makeVerifierLand` in
`SyncOutputVerifierTests.swift`), recorded live with in-turn sync on. `SyncOutputGoldenTests`
replays each on every `swift test` run and requires:

- every recorded state hash reproduced;
- the sync-output verdict `passed`: every recorded broadcast, per-player, events and seed hash
  reproduced, and the apply check passing;
- the summary line equal to `<name>.expected.txt`, which pins the compared, unverifiable and
  skipped counts;
- the initialize check passing.

| File | Encoding | Scenario |
|------|----------|----------|
| `join-leave-json` | json (combined frames) | three players, mid-run join and leave, per-player scores |
| `join-leave-messagepack` | messagepack (opcode 107) | the same script |
| `freeze-resume-messagepack` | messagepack | a debug freeze and resume: a legacy cycle |
| `event-heavy-messagepack` | messagepack | bursts of targeted and broadcast events |
| `escaped-keys-json` | json | map keys that need JSON-pointer escaping or look like an index |

Each recording also has `<name>.apply-cases.json`: every case the apply oracle checked in its
replay (the view before, the patches, the oracle's view after). `SyncOutputGoldenTests`
requires it to equal what this build's oracle checks. `sdk/ts/src/core/view-golden-apply.test.ts`
applies the same patches with the TypeScript SDK's `StateTreeView`, built with
`verifier-land.schema.json`, and requires the oracle's view. The oracle is an RFC 6901 reference
client, so this is where the TypeScript client is held to it. Cases where `view.ts` is known to
differ (#121: `~0`/`~1` not unescaped, `[n]` read as an index) are listed in that test as
expected failures; fixing #121 makes them fail until they are removed from the list.

json and opcodeJsonArray produce the same sync output (the hashes are over canonical patches,
not bytes), so only one combined-frame encoding is recorded.

## Regenerating

A failure here means the replay no longer reproduces what an earlier build sent. If the change
is intentional (the diff, the canonical form, the hashes, the record format, or the verifier
land), regenerate and say why in the PR:

```bash
Tools/regenerate-sync-output-goldens.sh
swift test --filter SyncOutputGoldenTests   # the new baseline passes
(cd sdk/ts && npx vitest run src/core/view-golden-apply.test.ts)
```

Regeneration refuses to write a recording whose own replay does not pass.

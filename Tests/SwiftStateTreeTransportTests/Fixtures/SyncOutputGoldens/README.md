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

json and opcodeJsonArray produce the same sync output (the hashes are over canonical patches,
not bytes), so only one combined-frame encoding is recorded.

## Regenerating

A failure here means the replay no longer reproduces what an earlier build sent. If the change
is intentional (the diff, the canonical form, the hashes, the record format, or the verifier
land), regenerate and say why in the PR:

```bash
Tools/regenerate-sync-output-goldens.sh
swift test --filter SyncOutputGoldenTests   # the new baseline passes
```

Regeneration refuses to write a recording whose own replay does not pass.

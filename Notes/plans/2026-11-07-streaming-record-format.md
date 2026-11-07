# Streaming record format (record 3.0)

Status: rev 2 (review findings folded in, see the end), GO from review; the format choice (section 2) goes to the maintainer. Core change (`Sources/`, `Tests/`), through PRs. Fixes #245.

This is the last record-format change before the measurement rerun: once it and the atomic-values encoding ([plan](2026-11-07-atomic-values-positional-encoding.md)) land, the wire and record formats used for measurement freeze. Everything not listed here (checkpoints, an index, in-format compression, a binary encoding) is future work, and none of it triggers a rerun.

## Problem (#245)

`ReevaluationRecorder` (`Sources/SwiftStateTree/Runtime/ActionRecorder.swift`) keeps every tick frame in memory until `save(to:)`, which sorts the frames and encodes the whole file at once with `JSONEncoder` (`.prettyPrinted, .sortedKeys`). Memory grows linearly with the recorded duration, and the final write holds the frames and the encoded file together. A process that dies before `save` loses the whole recording.

Three facts shape the fix:

1. **A tick frame can't be closed in general.** Sync-stream entries for tick N are filed under `observedTickId = N` but can arrive many ticks later: a legacy sync cycle commits after awaits, and a new player's seed (`_syncStateForNewPlayer`, `TransportAdapter.swift:4598-4625`) is recorded after its located read, with no bound. Tickless lands record every turn into frame 0 for their whole life (`executingTickIdForPendingItems`, `LandKeeper.swift:2393`). That is why `flushIfNeeded` (`ActionRecorder.swift:935-945`) never finalizes a frame: a later record for the same tick would open a duplicate frame, and the reader's `Dictionary(uniqueKeysWithValues:)` (`ActionSource.swift:113`) would trap.
2. **Readers don't need the frames as written.** Every replay steps from tick 0. The sync stream is read whole and sorted globally by `streamIndex` (`ReevaluationSyncStream.swift:355`; `SyncOutputReplayDriver` checks the indices are dense, `SyncOutputVerifier.swift:703-735`). Per-tick lookups and `getMaxTickId` are all a reader needs from the frames.
3. **Shutdown can lose the newest entries today.** `ReevaluationRecordSaver.saveOnShutdown` runs from `AfterFinalize` without waiting for the keeper's queued recorder submissions (`drainAfterIdleCheck`, `LandKeeper.swift:3788-3850`; only the tests await `recorderSubmissionTail`).

## Design

### 1. Log records, not tick frames

The file is an append-only log of the records the recorder already receives, in arrival order:

| record | written when | content |
|---|---|---|
| `header` | at `setMetadata` | format `3.0`, the `ReevaluationRecordMetadata` |
| `turn` | each `recordTick` submission (in-turn path), or each closed legacy tick | `tickId` and that turn's inputs, server events, watermarks, `stateHash`, `initialize` (the fields of `ReevaluationTickFrame` the turn carries) |
| `syncOutput`, `syncMarker` | each `recordSyncOutput` / `recordSyncMarker` | the entry, with its `observedTickId` |
| `footer` | at close | `complete: true`, `maxTickId`, record counts, sync-stream count |

- **No record waits for a tick to close.** A late sync entry is just a later `syncOutput` line; a tickless land's turns are successive `turn` lines with `tickId` 0.
- **The reader rebuilds today's model:** it merges `turn` records with the same `tickId` the way `recordTick` merges into an existing frame (`ActionRecorder.swift:902-932`), attaches sync entries to their `observedTickId`, and exposes the same `ReevaluationSource` API. Nothing above the source changes.
- **Legacy path (in-turn sync off):** its per-field calls (`record`, `setStateHash`, `recordServerEvents`, the watermark `record`) go into a buffer keyed by tick, written as one `turn` record when `runTick(N)` returns and also whenever a call names a different tick. `runTick` awaits, so a call for N can arrive after N's line was written; it becomes one more `turn` line for N, in arrival order, which the reader merges as `recordTick`'s `lastIndex` merge does today. Nothing is dropped.
- **Intentional change, legacy tickless:** today `recordServerEvents` replaces frame 0's server events between tickless passes (`ActionRecorder.swift:865-892`), so only the last pass's events survive. 3.0 writes one `turn` per pass and keeps every pass's events. Existing 2.6 legacy-tickless records keep only the last pass; they still replay as before, and verification of them is unchanged.
- **Memory:** the recorder holds the open turn's buffer and a write buffer, nothing per tick. The debug state snapshots (`ENABLE_STATE_SNAPSHOT_RECORDING`, `*-state.jsonl`) are streamed to their side file the same way instead of buffered.
- **Writes:** records are encoded on the recorder and appended to a write buffer; the buffer is handed to one dedicated writer thread (not the cooperative pool, so no cooperative thread blocks on file I/O) when it reaches 64 KiB or 1 s after its first record, whichever comes first, and at close. **Durability:** no fsync; a crash loses at most the unflushed buffer, and what reached the file is readable by section 3.
- **Close:** `close()` writes the footer and flushes. The shutdown saver (`ReevaluationRecordSaver.saveOnShutdown`, from `AfterFinalize`) first awaits the keeper's recorder submission tail, outside any keeper turn: no keeper state is changed after the await, only the recorder is closed. The await has a deadline (5 s); on the deadline the saver closes with `complete: false` and logs the land and the pending count, so a stuck submission can't hang shutdown (fixes fact 3).
- **`encode()`** (admin download mid-run, `NIOAdminRoutes.swift:215-247`) returns the bytes in the file plus the unflushed buffer, followed by a footer marked `complete: false`. That footer exists only in the returned copy, never in the live file.
- **State side file:** the streamed `*-state.jsonl` is in arrival order (today it's sorted by tick); on the legacy path snapshots can arrive out of tick order, so `loadRecordedStates` sorts by tick on read, and readers must not assume order.

### 2. Encoding: JSON Lines with sorted keys (recommended) or length-prefixed MessagePack

Each log record is one line of compact JSON with sorted keys (`JSONEncoder` with `.sortedKeys`, `.iso8601` dates), ended by `\n`. Compact JSON never contains a raw newline (strings escape it), so the newline is the frame boundary.

**Why not MessagePack, as first proposed:**
- **Determinism.** Today's records are byte-identical across architectures (41/41, arm64 macOS against x86_64 Linux, in `deep-research/replay-scale-fp-perturbation`) because of `JSONEncoder` with sorted keys. The repository's MessagePack encoder writes maps in `Dictionary` order, which changes from process to process (`MessagePackValue.swift:237-254`), and writes `Float` as float32 and `Double` as float64, so the bytes depend on the Swift type of a payload field. A deterministic record would need a new canonical encoder (sorted keys, one float width) and a proof that it stays byte-identical across architectures.
- **Packaging.** The recorder is in core `SwiftStateTree`, which can't import `SwiftStateTreeMessagePack` (that module depends on core). The canonical encoder would be new code in core.
- **Decode drift.** JSON and MessagePack decode `AnyCodable` numbers to different base types (a float64 `3.0` stays a `Double`; JSON `3` becomes an `Int`), which replay would have to reconcile.
- **Size is measured offline anyway.** The recomputation-cost topic re-encodes records into compact JSON and sorted-key MessagePack, raw and gzipped (`deep-research/recomputation-cost/README.md`), so the on-disk encoding doesn't decide the reported sizes.
- **Tools.** Python and TypeScript tools read JSON Lines with the standard library.

**What MessagePack would buy:** smaller files on disk without external compression, roughly the gap the recomputation-cost topic already reports between its compact-JSON and MessagePack columns. If the maintainer prefers it, the log structure in section 1 is unchanged; the record framing becomes a 4-byte big-endian length (as `ServerLoadTest/StreamDump.swift:20-27` already does), and the plan adds the canonical encoder and a cross-architecture byte-identity test as a step before PR 1.

**No compression in the format.** Byte-identical compression across platforms isn't available (Apple's Compression framework isn't on Linux; zlib output depends on version and level). Archives are compressed externally, as the recomputation-cost topic already does (gzip level 9, mtime 0). The header reserves `codec: "none"` so a codec can be added later without a new framing.

### 3. Truncation

A file cut anywhere is readable up to its last complete line. The reader drops a final partial line and reports the file as incomplete when the footer is missing. **Without a footer, the last tick present is reported unverified, not compared**, because a tick can have several `turn` lines (several drains, or tickless frame 0) and a cut between them would otherwise replay that tick with partial inputs and report a false divergence. Every earlier tick is replayed and verified; missing sync outputs past the cut are reported as missing, as for any incomplete stream. A recording no longer depends on the process reaching `save`.

### 4. Versions and existing records

- **Record version `3.0`.** `ReevaluationRecordVersion.current` becomes `"3.0"`. The source is picked by the file's first bytes: a `{"header"` line opens the 3.0 reader; anything else goes to the existing `JSONReevaluationSource`, which keeps reading 2.5 and 2.6. No converter is needed for replay. A small `ReevaluationRunner --convert <in> <out>` writes a 2.x file as 3.0, for tools that want one format.
- **Version checks:** `isCompatible` and `unsupportedReason` (`ActionSource.swift:92-101`, `:280`) accept major 3 and 2.5+. What each caller does with a 2.x file after the change:
  - `ReevaluationEngine.run` (always checks): 2.5/2.6 replay, as today; 2.4 and older stay `.unsupported`.
  - `ReevaluationRunnerImpl` with `requiredRecordVersion` (GameServer's `REEVALUATION_REPLAY_REQUIRED_RECORD_VERSION`): the requirement is compared exactly as today, so a server requiring `3.0` refuses a 2.6 file; it isn't silently accepted.
  - The admin replay start with `expectedRecordVersion`: same exact comparison, refused on mismatch.
  - LandManager's replay keeper: gets the engine's check (none today), so a 2.4 or malformed file is refused where it was accepted before; 2.5+ opens.
  - A 3.0 file read by an older 2.x build fails as `.incompatible` (different major) before decoding.
- **Tracked records:** `Examples/GameDemo/reevaluation-records/{1,2,3}-hero-defense.json` stay 2.5 and stay readable. The five sync-output goldens (`Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/*.reeval.json`, 2.6) are re-recorded in 3.0, because `SyncOutputGoldenTests` requires a re-recording to equal the committed bytes. The 2.6 copies are kept as reader fixtures.
- **Semantic golden check:** each re-recorded 3.0 golden and its kept 2.6 copy must give an equal `ReevaluationSource` (frames, initialize record, sync stream, max tick); a bytes check alone would let a regression in through the re-recording. The legacy-tickless difference (section 1) is the only allowed difference, and no golden is legacy tickless.
- **`deep-research/replay-scale-fp-perturbation`:** its 41 recordings (2.5) aren't in the repository; they are regenerated by `scripts/run-batch.sh`, which records with the runner, so a rerun writes 3.0 and its per-file SHA-256 list changes. The topic's existing results stay as 2.5 data. The cross-architecture byte-identity check is repeated on 3.0 files in the rerun.

### 5. Sync-output verification and reevaluation

Unchanged above the source. The 3.0 reader gives `SyncOutputReplayDriver` the same globally sorted stream; a late entry that was written after later ticks' outputs is sorted by `streamIndex` exactly as today. Reevaluation, `--verify` and the replay land (`GenericReplayLand`, the admin replay start) read through the same `ReevaluationSource`. The reader still loads the stream whole, as the driver requires; bounding the reader's memory is out of scope.

### 6. Tools and the recomputation-cost method

- `Tools/CLI` re-saves downloaded records with `JSON.stringify(record, null, 2)` (`reevaluation-e2e.ts:116`, `reevaluation-e2e-game.ts:91`, `reevaluation-replay-e2e-game.ts:192`) and walks `tickFrames[].lifecycleEvents` (`reevaluation-replay-e2e-game.ts:169-185`). They pass the downloaded bytes through unchanged, and the lifecycle walk reads `turn` lines.
- `ServerLoadTest --record-dir` writes each room's log as it runs instead of `encode()` at the end.
- `deep-research/recomputation-cost/regenerate.py` reads 3.0 files by rebuilding the same `recordMetadata` / `tickFrames` structure from the lines, so B_asStored keeps its definition: everything the record holds, re-encoded. The re-encoded sizes change only by the structure (sync entries outside frames, the header and footer), which the method README states, and the native file size (compact JSON Lines) becomes a reported column. The README also notes that the peak RSS of earlier runs included the end-of-run write (#245), and that 3.0 runs don't have it.

## Tests (written first)

- **Truncation:** record a hero-defense run, cut the file at every record boundary and inside a record at several offsets; each cut opens, reports incomplete, and replays the complete ticks; the full file reports complete and verifies with 0 mismatches.
- **Truncation between turn lines of one tick:** a cut between two `turn` lines of the same tick (a tickless land, and a tick with two drains) reports incomplete, that tick unverified, and no mismatch.
- **Bounded memory:** the recorder's buffered state (records and bytes held) stays below a fixed bound over a long recording (10,000 ticks with sync stream on), independent of length. A ServerLoadTest run with `--record on` for 600 s on the measurement host shows flat RSS, as the evidence for #245.
- **Recording cost:** ServerLoadTest with recording on against off, same build and host (the measurement host), reporting throughput and the tick and sync p99. Flat RSS alone doesn't show that recording doesn't perturb the run.
- **Round trip:** the same scenario recorded as 2.6 (the current writer, kept for the test) and as 3.0 gives equal `ReevaluationSource` outputs for every tick (frames, initialize record, sync stream, max tick) and the same verification result, in-turn and legacy ticked.
- **Late entries:** a new player's seed recorded several ticks after its observed tick (held with `HoldPoints` at `initialSyncAfterRead`) lands in the right tick on read, and verification passes. No fixture covers this today.
- **Tickless:** a tickless land with many input turns reads back as one frame 0 equal to the 2.6 writer's.
- **Legacy path:** with `IN_TURN_SYNC=false`, one `turn` per closed tick and no duplicate-`tickId` frames on read; a per-field call for N held (HoldPoints) at one of `runTick`'s awaits until after N's line is written lands as an extra `turn` line and merges into N on read. Legacy tickless: every pass's server events are kept (the intentional change), asserted directly rather than against the 2.6 writer.
- **Shutdown:** with a submission held (TestGate), the saver waits and the record then contains every submitted entry; with the hold past the deadline, the file closes with `complete: false` and the log line, and shutdown finishes.
- **Determinism:** recording the same scenario twice gives byte-identical files; the cross-architecture check runs in CI's Linux job against a committed SHA-256.
- **Versions:** 2.5 and 2.6 files still replay; a 3.0 file opens through the new reader; version reporting as in section 4.
- **E2E:** `test-e2e-game.sh` with reevaluation replay, 0 mismatches.

## Steps

1. **PR 1, the writer and the reader:** log records, the legacy-path buffering, `close()` and the shutdown await, the 3.0 reader and version dispatch, the tests above, the re-recorded goldens.
2. **Examples and tools (direct to main):** `ServerLoadTest --record-dir`, the CLI pass-through, `ReevaluationRunner --convert`, `regenerate.py` and the recomputation-cost method README.
3. **Solutions entry** if the "a frame can't be closed while late entries can arrive" lesson isn't already covered: log the records as they come and rebuild the grouping on read.

## Prior art

- **MCAP** (robotics logs): an append-only record log with chunks, an index and optional compression, readable when truncated. The chunk, index and compression parts are future work here.
- **Quake `.dem` and the Unreal Engine replay streamer:** demos as a stream of messages plus periodic checkpoints for seeking. Checkpoints are future work; replay here always starts at tick 0.
- **Kafka segments and database write-ahead logs:** length-prefixed records appended in arrival order, with recovery that drops a torn last record. Section 3 does the same with newline framing.
- **JSON Lines:** one JSON value per line, the framing recommended in section 2.

## Open questions

- **Format (for the maintainer):** JSON Lines with sorted keys (recommended), or length-prefixed canonical MessagePack with a new encoder in core.
- The 2.6 writer is kept in tests while the 2.6 fixtures and the semantic golden check exist, and deleted with them later (review agreed).


## Changes in rev 2

From the rev 1 review: legacy tickless keeping every pass's events is stated as intentional, and the round trip is split accordingly (1); late legacy per-field calls become extra `turn` lines, buffer keyed by tick (2); without a footer the last tick is unverified, not compared (3); the shutdown await is outside keeper turns and has a deadline (4); writes are batched on a dedicated writer thread, no fsync claim, and a recording-cost A/B is added (5); the re-recorded goldens get a semantic check (6); the version callers are listed (7); state side file order and `encode()` mid-run (8, 9).
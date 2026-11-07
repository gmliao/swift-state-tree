# Path index and same-parent field merge for opcode state updates

Status: rev 1, open. Direction approved by the maintainer (2026-11-07): unfreeze the wire format, implement both changes with the handshake and the SDK, then refreeze. Core change (`Sources/`, `Tests/`, `sdk/ts`, `Tools/CLI`); it lands through the PRs below, each a trade-off PR.

## Problem

In the opcode state-update encodings (`opcodeJsonArray` and `opcodeMessagePack` with path hashes), every patch is an entry `[pathHash, dynamicKey, op, value]`:

- **The path hash is a 32-bit FNV-1a hash** of the path pattern (`players.*.position`). In MessagePack it takes 5 B (a uint32), in JSON 9–10 digits. A land's schema has few patterns (GameDemo's largest land has 54), so the hash carries far more bits than it needs to.
- **One entity changing several fields sends one entry per field,** each repeating the array header, path id, dynamic key and op. In hero-defense, a moving monster changes `position` and `rotation` in the same sync, and an active player changes `position`, `rotation` and `targetPosition`.

An experiment branch measured both changes in `EncodingBenchmark` on the hero-defense cells, with every frame expanded and checked against the current encoder's patches. For delta syncs, path ids are a large share of state-update bytes, and both changes reduce them substantially; full-snapshot syncs are top-level object sets and gain little. The PRs below measure again on the final code and record the numbers with the new baseline.

## Design

### 1. Path index

**The rank table, per land:** the land's schema `pathHashes` values, de-duplicated and sorted ascending as unsigned 32-bit integers. A pattern's **path index** is its position in that list (0-based).

- Server and client derive it from the schema they already share. The schema, codegen output and schema hash don't change.
- An indexed entry has the same layout as today, with the index in place of the hash: `[pathIndex, dynamicKey, op, value?]`. With fewer than 128 patterns, every index is a MessagePack positive fixint (1 B).
- The table is per land. The SDK's global `pathHashReverseLookup` (one map for every land a client has open) becomes a per-land decode context for indices; the hash path keeps working as today.

**A path outside the schema** (a pattern `PathHasher.split` can't match, today hashed by the fallback heuristic; the class of #287): there is no index for it. It is an **encode-time error, never guessed by the decoder**:

- The encoder throws for that scope's frame. The adapter's existing encode-failure handling applies: the scope's update isn't sent, the per-player cache isn't committed (`perPlayerUncommitted`), and the sync stream marks it unverifiable.
- A counter (`unmappedPathPatches`, per land, in the adapter's sync metrics) and one log line per pattern make it visible.
- The blast radius matches today: a client already fails the whole frame on "Unknown pathHash".

### 2. Same-parent field merge

**Which patches merge:** patches in one frame whose paths are schema leaves under the same parent pattern, with the same dynamic keys and the same op. They are sent as one merged entry.

- **A leaf** is a pattern with no longer pattern below it, or a pattern in the atomic layout table (an atomic value such as `Position2` is one value on the wire).
- **Parent and field:** the parent is the pattern without its last component, and the last component must be a field name, not `*`.
- **Ops:** only set and add merge.

**Not merged:** deletes; object-level sets (patterns with a pattern below them, such as a whole entity on spawn or the top-level sets of a full-snapshot sync); fields at the root (no parent entry); paths outside the schema; groups of one.

**Wire layout, with distinct ops:**

| op | entry |
|---|---|
| 1 set, 2 remove, 3 add (unchanged) | `[pathId, dynamicKey, op, value?]` |
| 4 merged set, 5 merged add | `[parentId, dynamicKey, op, fieldMask, v1, v2, …]` |

- `parentId` is the parent pattern's path index, or its hash when the path index is off. `dynamicKey` has the same encoding and slot rules as a plain entry. The values follow the mask's bits in ascending order, each a wire value as for a plain entry (positional for atomic values).
- **The mask:** a field's bit is its rank among the parent's named children (patterns `parent.<name>`, name not `*`), sorted by name in byte order. The mask is an unsigned integer.
  - It fits a MessagePack positive fixint (1 B) when only bits 0–6 are set. Bit 7 takes a uint8 (2 B).
  - Fields with rank 64 or above are not merged; they go out as plain entries. That is the fallback for a parent with more than 64 named children. A parent with 8–64 children still merges, with a wider mask.
  - GameDemo's widest parent (`monsters.*`) has 8 named children.
- **Order:** a merged entry takes the position of its first member in the frame. A frame's patches have distinct paths and no order dependence between different fields, so no reordering is visible to a client.

### 3. Toggles

Two fields in `TransportEncodingConfig`, each independent, for the ablation:

- **`pathIndex: Bool`:** the path index instead of the hash.
- **`fieldMerge: Bool`:** merged entries.

Both are with `with…` builders like `dynamicKeyCompression`, and env keys in `TransportEnvKeys` read by the demo servers and `EncodingBenchmark` (`--path-index on|off`, `--field-merge on|off`). Each PR lands its toggle defaulting to on; the refreeze SHA is the main commit after both PRs.

### 4. Handshake: the client declares what it decodes

The schema hash doesn't change, and `joinResponse.encoding` carries only the message encoding (the SDK derives the state-update encoding from it). So an old client would read indices as hashes, and merged entries as plain ones, without noticing. A frame version alone wouldn't help, since old clients don't check one.

- **The client declares** the state-update features it decodes in join metadata, next to `schemaHash`: `stateUpdateFeatures: ["pathIndex", "fieldMerge"]`.
- **The server refuses a join** whose declaration lacks a feature the server has on, with the reason `unsupported state update encoding: missing <feature>`.
- **`joinResponse`** echoes the features in use (`stateUpdateFeatures`), and the client decodes by them.
- **Turning a feature off** on the server keeps old clients working. A client that declares more than the server uses is fine.

One list of named features rather than one encoding name per combination, so the ablation's four combinations need no four names.

### 5. Records and verification stay logical

The sync stream hashes canonical logical patches (`CanonicalPatchList`, string paths), the `.patches` record detail stores `StatePatch`es, and the sync-output goldens are logical. Both changes happen in the encoders, after the plan, so:

- the record format doesn't change, and records store no path ids;
- the sync-output verifier and the patch-apply oracle see the expanded patches.

Each PR tests this: the sync-output golden scripts, run with the feature on and off, give identical `expected.txt` and record hashes.

## Places that change

- **Swift:**
  - `OpcodeJSONStateUpdateEncoder` and `OpcodeMessagePackStateUpdateEncoder`: the index, merged entries, the unmapped-path error;
  - `StateUpdateDecoder` (both opcode decoders): the rank table and merged expansion;
  - `PathHasher` (pattern access for the rank and child tables);
  - `TransportEncodingConfig`, `TransportAdapter` (join check, `joinResponse`, counter).
- **SDK (`sdk/ts`):**
  - `protocol.ts` entry decoding: index lookup per land, ops 4 and 5;
  - `view.ts` (the per-land table);
  - the runtime's join metadata and `joinResponse` handling.
- **Tools:** `Tools/CLI` and `Examples/GameDemo/ws-loadtest` decode through the SDK; CLI unit tests for both ops.
- **Fixtures:** the shape-matrix fixture (#290) holds raw frames, so regenerate it per PR. Its cases gain merged groups (a struct with two atomic fields under one parent). The sync-output goldens don't change.
- **Docs:** `docs/transport/README.md` and `docs/transport_evolution.md`, with their `.zh-TW.md` pair.

## PRs

1. **Path index:**
   - the rank table, the encoders and decoders, the unmapped-path error and counter;
   - the handshake (`pathIndex` feature), the SDK and CLI;
   - the toggle (default on), the docs.
   - **Tests:** the shape matrix with the fixture regenerated; a rank-table test (sorted, per land); a join refused without the feature; an unmapped path that fails the frame and counts; the goldens equal with the toggle on and off.
2. **Field merge:**
   - ops 4 and 5 in the encoders, decoders, SDK and CLI;
   - the `fieldMerge` feature and toggle (default on), the docs.
   - **Tests:** the shape matrix (new merged cases, both formats, the SDK and the CLI decoding the same frames); the mask with a wide parent (bit 7, and rank ≥ 64 sent plain); expanded patches equal to the unmerged patches for every frame of an E2E run; the goldens equal with the toggle on and off.
3. **(Optional, small) order-independent slot assignment (#292):** within a frame, new dynamic keys get their slots in byte-sorted order. No wire change.

Each of PRs 1 and 2 also runs:
- the full `swift test` (both `IN_TURN_SYNC` values);
- `sdk/ts` and the CLI unit tests;
- `test-e2e-ci.sh` (all encodings) and `test-e2e-game.sh`;
- `EncodingBenchmark` bytes per sync for the hero-defense cells, with its toggle on and off.

## Out of scope

- Varint integers, and merging across parents.
- A path index for the legacy (string path) and `jsonObject` encodings.
- Fixing #287; it makes the unmapped-path error less likely, not unnecessary.

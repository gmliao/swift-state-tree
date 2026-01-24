[English](transport_evolution.md) | [中文版](transport_evolution.zh-TW.md)

# Transport Layer Encoding Evolution and Final Results (Transport Evolution)

This document records the major evolution of transport layer encoding in the `optimize/transport-opcode-json-array` branch. The goal is to significantly reduce network bandwidth consumption and improve transmission performance through more efficient serialization methods.

All examples below are based on the **GameDemo**'s `HeroDefenseState` and `ClientEvents`.

---

## Evolution History

### Stage 1: Opcode JSON Array Optimization

- **Background**: The original transport format was a standard JSON Object, where field names (Keys) took up a large amount of redundant bytes.
- **Improvement**: Introduction of the `OpcodeJsonArray` format. The original `{ "kind": "action", "payload": ... }` structure was changed to an array structure `[Opcode, Payload...]`.

#### Example

Suppose there is a `MoveTo` Action:

**Original JSON Object:**

```json
{
  "kind": "action",
  "payload": {
    "requestID": "req-1",
    "action": {
      "type": "MoveTo",
      "payload": { "target": { "v": { "x": 100, "y": 200 } } }
    }
  }
}
```

**Opcode JSON Array:**

```json
[
  101, // Opcode for Action (assuming 101 represents Action)
  "req-1", // Request ID
  "MoveTo", // Action Type
  { "target": { "v": { "x": 100, "y": 200 } } } // Payload
]
```

> **Difference**: Removed redundant keys like "kind", "payload", "action", "type", significantly reducing packet size.

- **Source Code**:
  - Server Encoder: [StateUpdateEncoder.swift:L140](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L140)
  - Client Decoder: [protocol.ts:L388](../sdk/ts/src/core/protocol.ts#L388)

---

### Stage 2: Path Hashing

- **Background**: In State Sync, large string paths occupy most of the traffic. For example, `players.user-123.position.v.x`.
- **Improvement**: Introduced `PathHasher` integration with `schema.json`. Only a 4-byte integer hash is sent during transmission.

#### Example

Refer to the definitions in `schema.json`:

```json
"pathHashes" : {
  "players.*.position" : 3358665268,
  "players.*.items" : 2159421276
}
```

> **Note**: The `*` represents a **wildcard** (dynamic segment), corresponding to a dictionary key or array index in the State. These segments are further optimized by the dynamic key mechanism in Stage 3.

When the server updates a player's position (using Diff as an example):

**Original Path (String):**

```json
[
  2, // Opcode: Diff
  ["players/user-123/position", 1, { "v": { "x": 105, "y": 205 } }]
]
```

**After Path Hash Optimization:**

```json
[
  2, // Opcode: Diff
  [3358665268, "user-123", 1, { "v": { "x": 105, "y": 205 } }]
]
```

- `2`: Represents `StateUpdateOpcode.diff`.
- `3358665268`: Hash for `players.*.position`.
- `"user-123"`: Dynamic path segment (Dynamic Key).
- `1`: Represents `StatePatchOpcode.set`.

> **Difference**: Long string `players.*.position` is replaced by a 4-byte integer.
> **Note**: In JSON format, the **text size** may not drop significantly because the hash integer (e.g., `3358665268` is 10 bytes) is similar in length to the original path, and an array structure is introduced to separate dynamic keys. The core value of this stage is establishing a "numerical" structure for the binary storage in Stage 4.

- **Source Code**:
  - Path Hashing Logic: [PathHasher.swift](../Sources/SwiftStateTree/Core/PathHasher.swift)
  - Server Usage: [StateUpdateEncoder.swift:L214](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L214)
  - Client Reconstruction: [protocol.ts:L520](../sdk/ts/src/core/protocol.ts#L520)

---

### Stage 3: Runtime Compression Optimization (Runtime Compression)

A runtime compression mechanism was introduced for dynamic data that cannot be predicted at compile time, further pushing the limits of transmission. This relies on the Snapshot mapping table established during "First Sync".

#### 1. Core Concept: Slot Mapping

To eliminate overhead caused by long strings (Dynamic Path Keys), the server maintains a dynamic mapping table of `String <-> Int Slot`.

- **Dynamic Key (Body Layer)**: Maps dynamic strings in the State Path (e.g., `players["user-123"]`, `inventory["item-abcdef"]`) to an `Int`.
- **Scope**: The slot table is **not global**. It is scoped per `(landID, playerID)` so different players do not share the same mapping.
- **Reset**: On `firstSync`, the table is reset and keys are (re)defined to avoid unbounded growth and to keep decoding deterministic.

#### 1.1 Dynamic Key Wire Format (Opcode Patch)

For PathHash patches, the patch format is:

`[pathHash, dynamicKeyOrKeys, op, value?]`

Where `dynamicKeyOrKeys` supports both single-wildcard and multi-wildcard patterns:

- **No wildcard**: `null`
- **Single wildcard** (one `*` in the schema pattern): a _DynamicKeyToken_
- **Multiple wildcards** (two or more `*` in the schema pattern): an array of _DynamicKeyToken_ in wildcard order

**DynamicKeyToken** can be one of:

- `string`: the raw key (no compression)
- `number`: a previously-defined **slot id** (compressed reference)
- `[number, string]`: a **definition** of slot id to raw key (`[slot, "key"]`)
- `null`: no key (only valid when the schema pattern has no `*`)

> **Important**: `number` is reserved for slot ids. If your dynamic key is a numeric index (e.g. `"7"`), encode it as a **string** to avoid being interpreted as a slot id.

> **Ambiguity rule**: An array `[number, string]` is always treated as a _definition token_. Any other array shape is treated as the multi-wildcard `dynamicKeyOrKeys` list.

#### 2. Establishment Mechanism: First Sync

When a player first connects, the server sends Opcode `1` (FirstSync).

- **Forced Definition (Body)**: All patches in the Body involving dynamic keys (such as `players.user-123`) MUST use the `[Slot, "KeyString"]` format to establish the initial mapping.

**First Sync Example:**

```json
[
  1,          // Opcode: FirstSync
  // Patches...
  [2159421276, [1, "user-123"], 3, { ... }]  // [Body] Define Slot 1 = "user-123" for this path
]
```

#### 3. Runtime Benefit: Incremental Updates (Update)

Once the mapping is established, all subsequent updates (Diff) only need to transmit the Slot ID.

`[2, [3358665268, 1, 1, 100]]`

- **Opcode**: `2` (Diff).
- **Body**: Uses Slot `1` (1 byte) instead of "user-123" (36 bytes).

  > **Note**: This mechanism applies to **any wildcard segment** (e.g. `PlayerID`, `MonsterID`, `ItemKey`) as long as it appears under `*` in the schema path pattern.

- **Source Code**:
  - Server Tracking: [StateUpdateEncoder.swift:L221](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L221)
  - Client Resolution: [protocol.ts:L455](../sdk/ts/src/core/protocol.ts#L455)

---

### Stage 4: MessagePack Binary Integration (MessagePack Integration)

- **Background**: Previous stages have completed "numericalization" and "structuralization". Although JSON Array reduces field names, a value like `1234567890` still occupies 10 bytes in text format, and parsing performance is still limited by text processing.
- **Improvement**: Since previous optimizations have simplified the data into pure numerical arrays, this provides perfect space for **MessagePack**. By directly encoding Opcode Array, PathHash, and Dynamic Keys into binary, text processing costs are eliminated, reaching the limits of performance and bandwidth.

#### Example

Position update again (Diff):

**JSON Array:**
`[2, [3358665268, 1, 1, 100]]` (Plain text, every digit/comma is a character)

**MessagePack (Binary):**
`92 02 94 CE C8 31 2A 34 01 01 64`

> **Note**: Depending on the encoder (especially online tools based on JavaScript `Number`), `3358665268` may be encoded as **float64** (`CB`) instead of `uint32` (`CE`), e.g.:
> `92 02 94 CB 41 E9 06 25 46 80 00 00 01 01 64`
>
> Both represent the same numeric value, but with different MessagePack type tags. On the Swift server, `UInt32` PathHash normally encodes as `CE` (uint32).

- `92`: Top-level Array of 2 elements (`[opcode, patches]`).
- `02`: Opcode `2` (Diff).
- `94`: Patch Array of 4 elements (`[pathHash, slot, op, val]`).
- `CE C8 31 2A 34`: `UInt32` (PathHash) takes only 5 bytes.
  - If you see `CB 41 E9 06 25 46 80 00 00`: it's the same PathHash encoded as `float64` (9 bytes).
- `01`: `Int` (Dynamic Key Slot) takes only 1 byte.
- `01`: `Int` (Patch Opcode) takes only 1 byte.
- `64`: `Int` (Value 100) takes only 1 byte.

> **Final Benefit**: Completely removes text parsing costs and compresses packet size to the extreme.

#### Parallel Encoding Support

`OpcodeMessagePackStateUpdateEncoder` and `MessagePackSerializer` are both **`Sendable`** types, supporting safe parallel encoding in multi-threaded environments:

```swift
// Safe parallel encoding in TaskGroup
let results = await withTaskGroup(of: Data.self) { group in
    for update in updates {
        group.addTask {
            try! encoder.encode(update: update, landID: landID, playerID: playerID)
        }
    }
    // ...
}
```

**Unit Test Verification**: Parallel encoding results are identical to serial encoding, with better performance.

- **Source Code**:
  - Server Encoder: [StateUpdateEncoder.swift:L329](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L329)
  - Client Decoder: [protocol.ts:L304](../sdk/ts/src/core/protocol.ts#L304)
  - Parallel Encoding Tests: [TransportAdapterParallelEncodingPerformanceTests.swift](../Tests/SwiftStateTreeTransportTests/TransportAdapterParallelEncodingPerformanceTests.swift)

---

## Final Result

Currently, **GameDemo** uses the following configuration for optimal performance:

1.  **Transport Config**: `messagepack`
    - Full binary transmission.
2.  **State Encoding**: `opcodeMessagePack`
    - Combines Path Hash (compile-time) + DynamicKey (runtime).
3.  **Schema**: `schema.json`
    - Contains the full `pathHashes` table to ensure synchronized decoding between client and server.

## Performance Benchmarks

Based on performance test results on `2026-01-15` (GameServer: hero-defense, duration: 60s), optimization results for each stage are as follows:

| Message Type                 | JSON Format (Original) | Opcode Format (Stage 1) | MessagePack Format (Final) | Savings    |
| :--------------------------- | :--------------------- | :---------------------- | :------------------------- | :--------- |
| **StateUpdate (Avg/Packet)** | 533.60 bytes           | 255.14 bytes            | **142.30 bytes**           | **73.00%** |
| **Event (Avg/Packet)**       | 185.00 bytes           | 97.00 bytes             | **48.74 bytes**            | **73.00%** |
| **Transport Control**        | 312.00 bytes           | 110.00 bytes            | **90.00 bytes**            | **71.00%** |

### Key Data

- **73% Bandwidth Savings**: From original JSON to the final MessagePack + PathHash, state update packet sizes are reduced to 1/4 of the original size.
- **Under 150 bytes**: The average **StateUpdate(diff) message packet** (one diff flush; may contain multiple patches) is about **142 bytes/packet**.
  - **Throughput**: bandwidth is approximately \(142 \times \text{StateUpdate(diff) packets per second}\) bytes/s.
  - For example, at 10 state updates per second: \(142 \times 10 = 1420\) bytes/s (~1.4 KB/s).

## Technical Q&A

### Q1: Will multiple updates of the same ID within the same frame be merged? (Update Merging)

**A: Yes, they will be automatically merged.**

- **Mechanism**: `SyncEngine` uses a **Snapshot Diff** mechanism rather than an Operation Log.
- **Process**:
  1. At the end of each frame, the system captures a Snapshot of the current state.
  2. Compares it with the Snapshot sent in the previous frame.
  3. Produces only the differing parts (Diff).
- **Example**: If a player's position changes from `(0,0)` -> `(10,0)` -> `(20,0)` in the same frame:
  - The system will only see `Old=(0,0)` and `New=(20,0)`.
  - Only one Patch is produced: `op: set, value: (20,0)`.
  - This ensures that under network jitter or high-frequency calculations, transmission volume always stays at a minimum and doesn't expand due to intermediate calculation processes.

### Q2: How is the order of Arrays generated by Payload Macro (@Payload) determined?

**A: Strictly according to the declaration order of the Struct properties.**

- **Implementation**: The `@Payload` Macro parses the Struct's Abstract Syntax Tree (AST) at compile time.
- **Rule**: It sorts `Stored Properties` by **ASCII Name (Deterministic ASCII Sorting)** before generating serialization code. This ensures protocol stability even if you refactor source code (change declaration lines), as long as field names remain unchanged.
- **Dual Guarantee (Synchronization)**:
  1.  **Runtime (`encodeAsArray`)**: The Macro generates this function using sorted fields for Server serialization.
  2.  **Schema (`getFieldMetadata`)**: The Macro generates this metadata using sorted fields for `SchemaExtractor` to write into `schema.json`.
- **Critical Constraint**: These two functions MUST use the exact same sorting logic. We chose ASCII sorting because it guarantees **cross-platform, cross-language determinism** and is immune to developer refactoring habits.
- **Schema Mapping**: Although the `properties` in a JSON Object are unordered, the `required` array in the generated `schema.json` strictly preserves this order, serving as the reference for clients to decode the Tuple Array.
- **Source Code**: [PayloadMacro.swift](../Sources/SwiftStateTreeMacros/PayloadMacro.swift)
- **Example**:
  ```swift
  @Payload
  struct MyEvent {
      let x: Int    // Index 0
      let y: Int    // Index 1
      let z: Int    // Index 2
  }
  ```
  Serialization result will always be `[x, y, z]`.
- **Caution**: Therefore, when modifying Protocols, to maintain backward compatibility, **new fields must be added at the end**, and old fields cannot change order or be deleted (unless all clients are forced to update).

### Q3: Will `player.rotate` and `player.position` updating simultaneously result in two pieces of data?

**A: Yes, two independent Patches are generated, but they are transmitted in the same Packet.**

- **Structure**: In `PlayerState`, `position` and `rotation` are two independent `@Sync` properties.
- **Patch Generation**:
  - `SyncEngine` detects `position` change -> Generates Patch 1.
  - `SyncEngine` detects `rotation` change -> Generates Patch 2.
- **Transmission Merging**: These two Patches are bundled into the same `StateUpdate.diff([Patch1, Patch2])` array.
  - This means although logically two modifications, there is **only one packet** at the network transmission level (Header overhead only once).
  - The receiver also applies both changes in the same tick, avoiding state inconsistency.

### Q4: What format do client-side Payloads currently use? (Future Optimizations)

**A: Currently, Payloads in various language SDKs (TypeScript/C#) still use Object format.**

- **Status**: Although the server-side has been fully optimized to Tuple Arrays (e.g., `[100, 200]`), current Client SDKs still use Object structures when sending Actions (e.g., `{ "x": 100, "y": 200 }`).
- **Future Optimization**: This is a known optimization point. In the future, Client SDKs can also implement a mechanism similar to `@Payload` to convert Action Payloads into Array format, further saving upstream traffic.

### Q5: Does the MessagePack encoder support parallel encoding? (Parallel Encoding)

**A: Yes! The MessagePack encoder fully supports parallel encoding.**

- **Technical Reason**: `OpcodeMessagePackStateUpdateEncoder` and `MessagePackSerializer` are both `Sendable` types, enabling safe parallel execution in `TaskGroup`.
- **Test Verification**: Unit test `testOpcodeMessagePackParallelEncoding` verifies that parallel encoding results are identical to serial encoding.
- **Performance Comparison** (50 updates × 3 patches):

| Format                        | Per Update   | vs JSON   |
| ----------------------------- | ------------ | --------- |
| JSON Object                   | 280 bytes    | 100%      |
| Opcode JSON (Legacy)          | 172 bytes    | 61.5%     |
| Opcode JSON (PathHash)        | 99 bytes     | 35.4%     |
| Opcode MsgPack (Legacy)       | 135 bytes    | 48.2%     |
| **Opcode MsgPack (PathHash)** | **65 bytes** | **23.3%** |

> **Best combination (Opcode MessagePack + PathHash) saves 76.7% of space!**

---

## Comprehensive Evolution Example

Using "Updating a player's Health (HP)" as an example, observe how the same semantic is represented across different stages and its packet size:

#### Stage 0: Original JSON Object

```json
{
  "kind": "stateUpdate",
  "payload": {
    "type": "diff",
    "patches": [{ "path": "players/user-123456/hp", "op": "set", "value": 100 }]
  }
}
```

- **Size**: **117 bytes**
- **Pain Point**: Large amount of redundant keys.

#### Stage 1: Opcode JSON Array

```json
[2, [["players/user-123456/hp", 1, 100]]]
```

- **Size**: **38 bytes**
- **Optimization**: Removed attribute names, kept only structure.

#### Stage 2: Path Hashing

```json
[2, [[3358665268, "user-123456", 1, 100]]]
```

- **Size**: **38 bytes**
- **Optimization**: Long path `players.*.hp` reduced to 4-byte hash.

#### Stage 3: Runtime Compression (Dynamic Key)

```json
[2, [[3358665268, 1, 1, 100]]]
```

- **Size**: **26 bytes**
- **Optimization**: Dynamic string `user-123456` reduced to 1-byte Slot ID.

#### Stage 4: MessagePack Binary (Final Form)

`92 02 91 94 CE C8 31 2A 34 01 01 64` (Hex)

- **Size**: **12 bytes**
- **Ultimate Optimization**: Numerical data and structure stored directly in binary, no brackets, commas, or quotes.

### Summary

From **117 bytes** to **12 bytes**, while maintaining the same logical semantics, we achieved nearly **90% bandwidth savings** at the physical level (89.74%). This is the core value of the optimizations in this branch.

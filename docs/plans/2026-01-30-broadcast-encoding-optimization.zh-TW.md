# Broadcast Encoding Optimization Implementation Plan
[English](2026-01-30-broadcast-encoding-optimization.md) | [中文版](2026-01-30-broadcast-encoding-optimization.zh-TW.md)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 每個 tick 的 broadcast 狀態只編碼一次（opcode 107），送給所有玩家；per‑player 更新分開送，讓 500 rooms 壓力測試不再超時。

**Architecture:** Tick 時拆成 broadcast 與 per‑player。broadcast 更新一律用 opcode 107（沒有 events 也用空陣列）並使用 broadcast 範圍的 DynamicKeyTable；per‑player 仍用一般 StateUpdate，並使用 per‑player DynamicKeyTable。firstSync 保持單一合併更新。

**Tech Stack:** Swift 6（SwiftStateTreeTransport）、TypeScript SDK（sdk/ts）、Swift Testing、vitest、shell load test script。

---

### Task 1: StateUpdate encoders 增加 scope（Swift）

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/StateUpdateEncoderProtocol.swift`
- Modify: `Sources/SwiftStateTreeTransport/OpcodeJSONStateUpdateEncoder.swift`
- Modify: `Sources/SwiftStateTreeTransport/OpcodeMessagePackStateUpdateEncoder.swift`
- Test: `Tests/SwiftStateTreeTransportTests/StateUpdateEncoderTests.swift`（或新增 `StateUpdateEncoderScopedTests.swift`）

**Step 1: Write the failing test**

```swift
@Test("Broadcast scope reuses dynamic keys across players")
func testBroadcastScopeEncodesIdenticalBytes() throws {
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher())
    let landID = "land"
    let playerA = PlayerID("a")
    let playerB = PlayerID("b")
    let patches: [StatePatch] = [
        .init(path: "/monsters/dragon/hp", operation: .set(100))
    ]
    let update = StateUpdate.diff(patches)

    let dataA = try encoder.encode(update: update, landID: landID, playerID: playerA, playerSlot: nil, scope: .broadcast)
    let dataB = try encoder.encode(update: update, landID: landID, playerID: playerB, playerSlot: nil, scope: .broadcast)

    #expect(dataA == dataB)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter BroadcastScopeEncodesIdenticalBytes`
Expected: FAIL

**Step 3: Write minimal implementation**

- 新增 `StateUpdateKeyScope`（broadcast / perPlayer）與 `StateUpdateEncoderWithScope` protocol。
- opcode encoders 實作 scope，broadcast 用 land‑level key table，per‑player 用 player‑level key table。
- JSONStateUpdateEncoder 不變（無 dynamic keys）。

**Step 4: Run test to verify it passes**

Run: `swift test --filter BroadcastScopeEncodesIdenticalBytes`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/StateUpdateEncoderProtocol.swift \
        Sources/SwiftStateTreeTransport/OpcodeJSONStateUpdateEncoder.swift \
        Sources/SwiftStateTreeTransport/OpcodeMessagePackStateUpdateEncoder.swift \
        Tests/SwiftStateTreeTransportTests/StateUpdateEncoderTests.swift

git commit -m "Add broadcast/per-player key table scope"
```

---

### Task 2: 拆分 broadcast / per‑player sync，opcode 107 只用於 broadcast

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`
- Test: `Tests/SwiftStateTreeTransportTests/TransportAdapterOpcode107Tests.swift`

**Step 1: Write the failing test**

```swift
@Test("Opcode 107 is used only for broadcast updates")
func testOpcode107BroadcastOnly() async throws {
    // Arrange: two sessions, one has per-player diff
    // Act: run sync tick
    // Assert: broadcast update uses opcode 107, per-player update uses opcode 0-2
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter Opcode107BroadcastOnly`
Expected: FAIL

**Step 3: Write minimal implementation**

- `syncNow` 先產出 broadcast 更新，encode 一次後送給所有 session。
- broadcast 一律用 opcode 107（events 可為空）。
- per‑player 仍送一般 StateUpdate（不走 107 合併）。
- firstSync 保持單一合併更新。
- 若 encoder 支援 scope，就用 `StateUpdateEncoderWithScope`，否則 fallback 到原本 encode。

**Step 4: Run test to verify it passes**

Run: `swift test --filter Opcode107BroadcastOnly`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/TransportAdapter.swift \
        Tests/SwiftStateTreeTransportTests/TransportAdapterOpcode107Tests.swift

git commit -m "Send opcode 107 only for broadcast updates"
```

---

### Task 3: SDK 端分離 broadcast / per‑player dynamic key map

**Files:**
- Modify: `sdk/ts/src/core/protocol.ts`
- Modify: `sdk/ts/src/core/runtime.ts`
- Test: `sdk/ts/src/core/protocol.test.ts`

**Step 1: Write the failing test**

```ts
it('uses broadcast key map for opcode 107 only', () => {
  const broadcastMap = new Map<number, string>()
  const playerMap = new Map<number, string>()

  const broadcast = [107, [2, [123, [0, 'foo'], 1, 1]], []] // opcode 107 with one patch
  const perPlayer = [2, [123, [0, 'bar'], 1, 1]] // diff update

  decodeStateUpdateWithEventsArray(broadcast, broadcastMap)
  decodeStateUpdateArray(perPlayer, playerMap)

  expect(broadcastMap.get(0)).toBe('foo')
  expect(playerMap.get(0)).toBe('bar')
})
```

**Step 2: Run test to verify it fails**

Run: `cd sdk/ts && npm test -- protocol.test.ts`
Expected: FAIL

**Step 3: Write minimal implementation**

- runtime 內新增 `broadcastDynamicKeyMap` 與 `perPlayerDynamicKeyMap`。
- `decodeMessage` / `classifyAndDecode` 根據 opcode 107 或 state update array 選擇 map。
- firstSync 只清除對應 map。

**Step 4: Run test to verify it passes**

Run: `cd sdk/ts && npm test -- protocol.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add sdk/ts/src/core/protocol.ts sdk/ts/src/core/runtime.ts sdk/ts/src/core/protocol.test.ts

git commit -m "Split broadcast/per-player dynamic key maps"
```

---

### Task 4: 完整驗證（完成宣告前必跑）

**Step 1: Swift tests**

Run: `swift test --filter BroadcastScopeEncodesIdenticalBytes`  
Run: `swift test --filter Opcode107BroadcastOnly`

Expected: PASS

**Step 2: SDK tests**

Run: `cd sdk/ts && npm test -- protocol.test.ts`  
Expected: PASS

**Step 3: Load test (500 rooms)**

Run: `timeout 180 bash Examples/GameDemo/scripts/server-loadtest/run-server-loadtest.sh`

Expected: 超時前完成；若超時立刻關閉 DemoServer/GameServer 並檢查 logs。

**Step 4: Report evidence**

貼上完整命令輸出（exit code + summary）。

---

## 發現與根因（實作後整理）

**現象：** 500-room 壓測（messagepack + opcode 107）常常超過預設 timeout，且偶爾看到「傳訊息但 session 尚未加入」的警告。

**根因整理：**
1. **Opcode 107 組包成本過高**：broadcast 更新先 encode 成 `Data`，再 unpack 重組 107；server event 也走同樣 pack→unpack，每次同步都有額外 CPU/配置成本。
2. **107 模式下 targeted event 沒被送出**：當 per‑player diff 為 `.noChange`，targeted event 會排隊但未送，造成 backlog 與延遲。
3. **斷線序列化**：`LandRouter.onDisconnect` 逐一 await 每個 land 的 `TransportAdapter.onDisconnect`，在 2,500+ 斷線時形成長尾。
4. **壓測收尾太慢**：load test 逐一斷線、等待 land 的 empty destroy timer，導致收尾超過 180s guard。

**已套用修正：**
- opcode 107 直接用 MessagePack array 組包，避開 pack→unpack。
- server event body 直接轉 MessagePack array，避開 pack→unpack。
- per‑player diff 為 `.noChange` 時仍會送 targeted events。
- `LandRouter` 以非同步方式派送 `TransportAdapter.onDisconnect`。
- 新增 land 的 `forceShutdown`，ServerLoadTest 用 `shutdownAllLands()` 快速收尾。

**結果：** 500-room ServerLoadTest 能在 180s 內完成。

## 容量 / 系統爆炸估算（簡化模型）

可用「每秒需要的 CPU 時間」估算爆炸風險：

```
TotalWorkPerSecond ≈
  Rooms * (TickCost * TicksPerSecond
         + SyncCost * SyncsPerSecond
         + EncodeCost * SyncsPerSecond)
  + EventCost * EventsPerSecond

CPUUtilization ≈ TotalWorkPerSecond / (CoreCount * 1s)
```

當 `CPUUtilization > 1.0` 時系統飽和；實務上約 0.7–0.8 就會開始明顯劣化（配置/GC 與排程成本）。這個模型可協助判斷是哪個成本項（tick / sync / encode / events）最該先優化。

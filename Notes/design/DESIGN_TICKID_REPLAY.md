# TickId 綁定機制用於重播

## 設計目標

為 action 和 event 綁定 tickId，用於重播系統的記錄和重播。

## 核心概念

### TickId 語意

- **Tick Handler**: `tickId` 是「正在執行的 tick」（例如 tick 100）
- **Action/Event Handler**: `tickId` 是「已 commit 的最後 tick」（例如 tick 100，如果執行於 tick 100 完成後、tick 101 開始前）

### 實作機制

```swift
// LandKeeper 中的追蹤變數
private var nextTickId: Int64 = 0              // 下一個要執行的 tick
private var lastCommittedTickId: Int64 = -1    // 已 commit 的最後 tick

// Tick 執行流程
private func runTick() {
    let tickId = nextTickId
    nextTickId += 1
    
    // 執行 tick handler（使用 tickId）
    handler(&state, ctx)
    
    // 更新已 commit 的 tick
    lastCommittedTickId = tickId
}

// Action/Event 使用 lastCommittedTickId
ctx = makeContext(..., tickId: lastCommittedTickId)
```

## 重播記錄格式

```
tickId:action
tickId:event
tickId:tick
```

範例：
```
0:tick
1:action:AttackAction
1:tick
2:action:MoveAction
2:event:PlayerJoinedEvent
2:tick
```

## 優勢

1. **確定性**: 所有操作都綁定到 tickId，執行順序確定
2. **最小 log**: 只需要記錄 tickId + action/event 數據
3. **重播友好**: 可以按照 tickId 順序重播
4. **時間計算**: 可以通過 `tickId * tickInterval` 計算確定性時間

## TickId 類型選擇

使用 `Int64` 而非 `Int32`，原因：

- **運行時間**：在 60 Hz 下，Int64 可運行約 490 萬年，Int32 僅約 1.1 年
- **重播需求**：更大的範圍支援更靈活的重播
- **長期運行**：支援長期運行的服務器（如 lobby、persistent worlds）
- **記憶體開銷**：差異僅 4 bytes（每個 tick context），影響可忽略

## 注意事項

- Tick handler 使用 `tickId`（正在執行的 tick）
- Action/Event handler 使用 `lastCommittedTickId`（已 commit 的最後 tick）
- 因為 actor 序列化，執行順序是確定的
- 重播時可以按照相同的順序執行

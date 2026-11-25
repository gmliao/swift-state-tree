[English](state-node-builder.md) | [中文版](state-node-builder.zh-TW.md)

# @StateNodeBuilder 詳細說明

> `@StateNodeBuilder` 是 SwiftStateTree 的核心 macro，用於標記和驗證 StateNode，並自動生成必要的 metadata 和方法。

## 概述

`@StateNodeBuilder` macro 在編譯期執行以下操作：

1. **驗證規則**：確保所有 stored property 都標記為 `@Sync` 或 `@Internal`
2. **生成 sync metadata**：產生 `getSyncFields()` 方法
3. **生成驗證方法**：產生 `validateSyncFields()` 方法
4. **生成 snapshot 方法**：產生 `snapshot(for:)` 和 `broadcastSnapshot()` 方法
5. **生成 dirty tracking**：產生 `isDirty()`、`getDirtyFields()`、`clearDirty()` 方法
6. **生成 field metadata**：產生 `getFieldMetadata()` 方法（用於 schema 生成）

## 基本使用

### 標記 StateNode

```swift
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    @Internal
    var lastProcessedTimestamp: Int64 = 0 // 毫秒
}
```

### 生成的程式碼

Macro 會自動生成以下方法（簡化版）：

```swift
// 自動生成的方法
extension GameState {
    // 取得所有 @Sync 欄位
    func getSyncFields() -> [SyncFieldInfo] {
        return [
            SyncFieldInfo(name: "players", policyType: "broadcast"),
            SyncFieldInfo(name: "hands", policyType: "perPlayerSlice"),
            SyncFieldInfo(name: "hiddenDeck", policyType: "serverOnly")
        ]
    }
    
    // 驗證所有欄位都已標記
    func validateSyncFields() -> Bool {
        return true  // 編譯期已驗證
    }
    
    // 生成 snapshot
    func snapshot(for playerID: PlayerID?) throws -> StateSnapshot {
        // 根據 @Sync 策略過濾欄位
        // ...
    }
    
    // Dirty tracking
    func isDirty() -> Bool { ... }
    func getDirtyFields() -> Set<String> { ... }
    mutating func clearDirty() { ... }
}
```

macro 也會寫出 `PlainData` 的 witness，它是型別主體裡的成員：

```swift
struct GameState: StateNodeProtocol {
    // ...上面的欄位...

    /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
    static func _plainDataCheck() {
        @available(*, deprecated, message: "the PlainData checks; never called")
        func check(_ value: inout Self) {
            SwiftStateTurns.PlainDataCheck.field(value._players)
            SwiftStateTurns.PlainDataCheck.field(value.players)
            SwiftStateTurns.PlainDataCheck.field(value._hands)
            SwiftStateTurns.PlainDataCheck.field(value.hands)
            SwiftStateTurns.PlainDataCheck.field(value._hiddenDeck)
            SwiftStateTurns.PlainDataCheck.field(value.hiddenDeck)
        }
    }
}
```

`StateNodeProtocol` 繼承 `PlainData`（[什麼算純資料](../turns/README.zh-TW.md#什麼算純資料)），`_plainDataCheck` 就是它的 witness。每個 `@Sync` 與 `@Internal` 欄位有兩行：`value._players` 讀 wrapper 的儲存內容，`value.players` 讀它的值。存放 class、closure、`Any` 或非 `PlainData` 型別的欄位，會在其中一行編譯失敗。檢查儲存內容的那一行也能抓到自己定義、名為 `Sync` 或 `Internal` 的 wrapper。`#if` 裡的 `@Internal` 欄位在同樣的條件下檢查。

## 驗證規則

### 編譯期驗證

`@StateNodeBuilder` 在編譯期執行嚴格驗證：

#### ✅ 正確的標記

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)      // ✅ 正確
    var players: [PlayerID: PlayerState] = [:]
    
    @Internal              // ✅ 正確
    var tempData: String = ""
    
    var totalPlayers: Int {  // ✅ Computed property 自動跳過
        players.count
    }
}
```

#### ❌ 錯誤的標記

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    var score: Int = 0  // ❌ 編譯錯誤：必須標記 @Sync 或 @Internal
}
```

**編譯錯誤訊息**：
```
error: Stored property 'score' in GameState must be marked with @Sync or @Internal
```

### 驗證規則詳解

1. **Stored properties**：必須明確標記 `@Sync` 或 `@Internal`，`#if` 裡的也一樣。有 observer（`willSet`、`didSet`）的 property 是 stored property，只有 `@Internal` 欄位可以有 observer：`@Sync` 欄位由產生的程式碼寫入時會略過 observer
2. **Computed properties**：自動跳過驗證，不需要標記
3. **未標記的 stored property**：編譯錯誤
4. **欄位的值是 `PlainData`**：每個 `@Sync` 與 `@Internal` 欄位，包含 `.serverOnly`（[同步](../core/sync.zh-TW.md#同步狀態只能由-value-type-組成)）
5. **欄位上不能有其他 property wrapper**：`PlainData` 檢查只讀 `@Sync` 與 `@Internal` 欄位
6. **`@StateNodeBuilder` 旁邊不能加 `@PlainData`**：這個 macro 已經寫出 witness。旁邊加 `@SnapshotConvertible` 沒有問題
7. **`#if` 裡不能有 `@Sync`**：同步只讀最上層的欄位，所以這種欄位永遠不會被同步。`#if` 裡的 `@Internal` 沒有問題
8. **成員中不能有 freestanding macro 展開**：檢查看不到它加入的儲存內容。`#warning` 與 `#error` 是編譯器指令，沒有問題
9. **型別上不能有其他 attached macro**：除了 `@StateNodeBuilder`，只能有 `@SnapshotConvertible` 與不加入成員的內建 attribute（例如 `@available`）。其他 macro 可能加入這個 macro 看不到的成員

## 生成的方法

### getSyncFields()

取得所有標記為 `@Sync` 的欄位資訊：

```swift
let fields = gameState.getSyncFields()
// 返回: [
//   SyncFieldInfo(name: "players", policyType: "broadcast"),
//   SyncFieldInfo(name: "hands", policyType: "perPlayerSlice")
// ]
```

### validateSyncFields()

驗證所有 stored properties 都已正確標記：

```swift
let isValid = gameState.validateSyncFields()
// 返回: true（編譯期已驗證，總是返回 true）
```

### snapshot(for:)

為特定玩家生成狀態快照：

```swift
// 為特定玩家生成 snapshot
let snapshot = try gameState.snapshot(for: playerID)
// 只包含該玩家可見的欄位（根據 @Sync 策略）

// 只生成 broadcast 欄位
let broadcastSnapshot = try gameState.snapshot(for: nil)
```

### broadcastSnapshot(dirtyFields:)

高效能的 broadcast snapshot 生成：

```swift
// 只生成 dirty 的 broadcast 欄位
let dirtyFields = gameState.getDirtyFields()
let snapshot = try gameState.broadcastSnapshot(dirtyFields: dirtyFields)
```

## Dirty Tracking

### 機制說明

Dirty tracking 用於追蹤哪些欄位已被修改，優化同步效能：

- **自動標記**：當欄位被修改時自動標記為 dirty
- **批次清除**：完整的同步週期在取得快照時清除所有 dirty 標記
- **效能優化**：只同步變更的欄位，減少序列化成本

### 使用方式

```swift
// 檢查是否有變更
if gameState.isDirty() {
    // 取得所有 dirty 欄位
    let dirtyFields = gameState.getDirtyFields()
    // 只同步變更的欄位
    try syncEngine.syncDirtyFields(gameState, dirtyFields: dirtyFields)
    
    // 清除 dirty 標記
    gameState.clearDirty()
}
```

### 自動標記

當欄位被修改時，會自動標記為 dirty：

```swift
// 修改欄位
gameState.players[playerID] = newPlayer  // 自動標記 players 為 dirty

// 檢查
gameState.isDirty()  // true
gameState.getDirtyFields()  // Set(["players"])
```

## 巢狀結構支援

### 遞迴處理

`@StateNodeBuilder` 支援巢狀的 StateNode：

```swift
@StateNodeBuilder
struct PlayerState: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String
    
    @Sync(.broadcast)
    var position: Position
}

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // 巢狀 StateNode
}
```

當生成 snapshot 時，會遞迴處理巢狀結構：

```swift
// 會遞迴處理 players 字典中的每個 PlayerState
let snapshot = try gameState.snapshot(for: playerID)
```

### 巢狀值型別與 generic node

欄位存放的 struct 或 enum 若不是 state node，就需要 `@PlainData`（或寫出同樣 conformance 的 `@SnapshotConvertible`）。generic node 的型別參數必須是 `PlainData`，因為它的欄位存放該型別的值：

```swift
@PlainData
struct Position: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
}

@StateNodeBuilder
struct Slot<Item: PlainData & Codable & Equatable & Sendable>: StateNodeProtocol {
    @Sync(.broadcast)
    var item: Item? = nil
}
```

不用 `@StateNodeBuilder`、手寫 `StateNodeProtocol` conformance 的 state node 要加上 `@PlainData`。這只適用於 stored property 都沒有 property wrapper 的 node，因為 `@PlainData` 拒絕所有 wrapper。有 `@Sync` 或 `@Internal` 欄位的 node 請用 `@StateNodeBuilder`。

## 常見問題

### Q: 為什麼必須標記所有 stored properties？

A: 這是為了確保所有狀態欄位都有明確的同步策略，避免意外洩露敏感資料或浪費頻寬。

### Q: Computed properties 需要標記嗎？

A: 不需要。Computed properties 會自動跳過驗證，因為它們不儲存狀態。

### Q: 可以在 class 上使用 @StateNodeBuilder 嗎？

A: 不可以。`@StateNodeBuilder` 只支援 `struct`，因為 StateNode 必須使用 value semantics。

### Q: 如何處理可選型別？

A: 可選型別可以正常使用，只需要標記 `@Sync` 或 `@Internal`：

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var optionalField: String? = nil  // ✅ 正確
}
```

## 最佳實踐

1. **明確標記所有欄位**：不要遺漏任何 stored property
2. **合理使用 @Internal**：內部計算用的欄位使用 `@Internal`
3. **使用 @Sync(.serverOnly) 而非 @Internal**：如果需要同步引擎知道但不同步給 client
4. **保持結構簡單**：避免過深的巢狀結構，提升效能

## 相關文檔

- [Macros 總覽](README.zh-TW.md) - 了解所有 macro 的使用
- [同步規則](../core/sync.zh-TW.md) - 深入了解 `@Sync` 策略
- [StateNode 定義](../core/README.zh-TW.md) - 了解 StateNode 的使用


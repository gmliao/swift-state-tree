# Policy 過濾機制：篩子層層過濾與樹的深度優先遍歷

> 本文檔說明 SwiftStateTree 的 Policy 過濾機制設計理念
> 
> 相關文檔：
> - [DESIGN_CORE.md](./DESIGN_CORE.md) - 核心概念與架構
> - [DESIGN_OPTIMIZATION.md](./DESIGN_OPTIMIZATION.md) - 性能優化

## 核心設計理念

SwiftStateTree 採用**「篩子層層過濾 + 樹的深度優先遍歷（DFS）」**的設計理念來實現狀態同步過濾。

### 比喻：篩子層層過濾

每一層節點都根據自己的 `@Sync` policy 進行過濾，最終結果是層層過濾的組合：

```
Level 0 (根節點) → 第一層篩子
  ↓
Level 1 (子節點) → 第二層篩子
  ↓
Level 2 (孫節點) → 第三層篩子
  ↓
...
```

### 樹的深度優先遍歷（DFS）

StateTree 本身就是一棵樹，過濾過程採用**深度優先遍歷**：

```swift
// SnapshotValue.swift:94-98
if let stateNode = value as? any StateNodeProtocol {
    // Recursively apply @Sync policies by calling snapshot(for:)
    let snapshot = try stateNode.snapshot(for: playerID, dirtyFields: nil)
    return .object(snapshot.values)
}
```

**遍歷過程**：
1. 訪問根節點 → 根據 policy 過濾
2. 對每個子節點遞歸調用 → 深度優先
3. 每個節點根據自己的 policy 過濾 → 層層篩選

## 實際範例

### 範例結構

```swift
@StateNodeBuilder
struct TestPlayerNode: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.perPlayerSlice())
    var inventory: [PlayerID: [String]] = [:]
}

@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.perPlayerSlice())  // Level 0: 第一層篩子
    var players: [PlayerID: TestPlayerNode] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}
```

### 為 Alice 生成 Snapshot 的過程

```
StateTree (根節點)
│
├─ players: [PlayerID: TestPlayerNode] (.perPlayerSlice)
│  │  ← Level 0 篩子：只保留 players["alice"] 的值
│  │     結果：TestPlayerNode 實例（不是字典）
│  │
│  └─ TestPlayerNode (alice 的節點)
│     │  ← Level 1：遞歸調用 snapshot(for: alice, ...)
│     │
│     ├─ name: String (.broadcast)
│     │  ← Level 1 篩子：保留（因為是 broadcast）
│     │
│     └─ inventory: [PlayerID: [String]] (.perPlayerSlice)
│        ← Level 1 篩子：只保留 inventory["alice"] 的值
│          結果：["sword", "shield"]
│
└─ round: Int (.broadcast)
   ← Level 0 篩子：保留（因為是 broadcast）

最終 Snapshot:
{
  "players": {
    "name": "Alice",
    "inventory": ["sword", "shield"]
  },
  "round": 0
}
```

## 關鍵特性

### 1. 獨立過濾（Independent Filtering）

**設計原則**：每個節點獨立決定自己的 policy，不依賴 parent

- ✅ **優點**：
  - 語義清晰：`.broadcast` 始終表示「公開字段」
  - 靈活性：parent policy 改變時，child 不需要修改
  - 一致性：所有節點使用相同的 policy 語義

- ⚠️ **注意**：
  - 當 parent 是 `.perPlayerSlice()` 時，child 的 `.broadcast` 在實際效果上確實「只對該玩家可見」
  - 但這是 parent 過濾的結果，不是 child policy 的結果
  - Child 的 `.broadcast` 仍然有意義：表示「這個字段是公開的」（相對於 `.serverOnly`）

### 2. 層層組合（Layered Composition）

**設計原則**：最終可見性是所有層級 policy 的組合結果

```
最終可見性 = Level 0 Policy × Level 1 Policy × Level 2 Policy × ...
```

**範例**：
- Level 0: `players` 是 `.perPlayerSlice()` → 只保留該玩家的節點
- Level 1: `inventory` 是 `.perPlayerSlice()` → 只保留該玩家的物品
- 最終結果：該玩家只能看到自己的 inventory

### 3. 深度優先遍歷（Depth-First Traversal）

**遍歷順序**：
1. 訪問節點 → 應用 policy 過濾
2. 遞歸訪問子節點（深度優先）
3. 合併結果

**實現**：
```swift
// 當遇到嵌套 StateNode 時
if let stateNode = value as? any StateNodeProtocol {
    // 遞歸調用，使用相同的 playerID
    let snapshot = try stateNode.snapshot(for: playerID, dirtyFields: nil)
    return .object(snapshot.values)
}
```

## SyncPolicy 類型詳解

SwiftStateTree 提供 5 種 `SyncPolicy` 類型，每種都有不同的使用場景：

### 1. `.serverOnly`

**用途**：伺服器內部使用，不同步到客戶端

**行為**：
- 字段不會出現在 snapshot 中
- 不會被包含在 diff 中
- 完全隱藏於客戶端

**範例**：
```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerNode] = [:]
    
    @Sync(.serverOnly)  // 伺服器內部邏輯，不暴露給客戶端
    var serverSecret: Int = 0
}
```

### 2. `.broadcast`

**用途**：同步給所有客戶端，所有玩家看到相同的值

**行為**：
- 字段出現在所有玩家的 snapshot 中
- 值對所有玩家相同
- 最常用的 policy

**範例**：
```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)  // 所有玩家看到相同的回合數
    var round: Int = 0
    
    @Sync(.broadcast)  // 所有玩家看到所有玩家節點
    var players: [PlayerID: PlayerNode] = [:]
}
```

### 3. `.perPlayer(@Sendable (Value, PlayerID) -> Any?)`

**用途**：根據玩家 ID 過濾值，每個玩家看到不同的內容

**行為**：
- 過濾函數接收 `(Value, PlayerID)` 參數
- 返回該玩家應該看到的值（`Value?`，**必須返回相同類型**）
- 如果返回 `nil`，該字段不會出現在該玩家的 snapshot 中
- **必須返回相同類型**以確保類型安全，macro 可以直接使用類型轉換

**範例**：
```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    // 自定義 perPlayer 過濾：只返回該玩家的物品
    @Sync(.perPlayer { inventory, playerID in
        inventory[playerID]
    })
    var inventory: [PlayerID: [String]] = [:]
    
    // 更複雜的過濾邏輯
    @Sync(.perPlayer { data, playerID in
        // 只返回該玩家有權限看到的數據
        data.filter { $0.ownerID == playerID }
    })
    var playerData: [PlayerData] = []
}
```

**Convenience Method**：
```swift
// 對於字典類型，可以使用 convenience method
@Sync(.perPlayerSlice())  // 等同於 .perPlayer { dict, pid in [pid: dict[pid]] }
var hands: [PlayerID: [Card]] = [:]
```

**⚠️ 結構一致性說明**：
- `perPlayer` **必須返回相同類型**（`Value?`）
- 對於 `perPlayerSlice`，它返回單元素字典 `[playerID: element]`，**保持字典結構**（不提取單個值）
- 這確保了伺服器和客戶端的結構一致：兩者都看到字典結構，只是字典中只包含當前玩家的 key
- 例如：`{"alice": [...]}` 而不是 `[...]`

### 4. `.masked(@Sendable (Value) -> Value)`

**用途**：遮罩敏感信息，所有玩家看到相同的遮罩後的值

**行為**：
- 遮罩函數接收 `Value` 參數
- **必須返回相同類型**（`Value`，不能為 `nil`）
- 所有玩家看到相同的遮罩後的值
- 與 `.perPlayer` 不同：`.masked` 不依賴 `playerID`，所有玩家看到相同結果
- 與 `.custom` 不同：`.masked` 只能返回相同類型，如果需要返回不同類型，使用 `.custom`

**範例**：
```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    // 遮罩玩家真實 HP：四捨五入到最近的 10
    @Sync(.masked { hp in
        // 返回 Int（相同類型）
        return (hp / 10) * 10
    })
    var hp: Int = 100  // 85 -> 80, 97 -> 90
    
    // 遮罩敏感數字：四捨五入到最近的 100
    @Sync(.masked { balance in
        // 返回 Int（相同類型）
        return (balance / 100) * 100
    })
    var playerBalance: Int = 0  // 1234 -> 1200
    
    // 遮罩字串：只顯示前 3 個字符
    @Sync(.masked { password in
        // 返回 String（相同類型）
        return String(password.prefix(3)) + "..."
    })
    var adminPassword: String = ""  // "secret123" -> "sec..."
}
```

**⚠️ 注意**：
- `masked` **必須返回與輸入相同的類型**（`Value -> Value`）
- 如果需要返回不同類型（例如 `Int -> String`），請使用 `.custom` policy
- 這個限制確保類型安全，避免運行時類型轉換錯誤
- Macro 生成的代碼可以直接使用原始類型進行轉換，無需運行時類型檢查

### 5. `.custom(@Sendable (PlayerID, Value) -> Any?)`

**用途**：完全自定義的過濾邏輯，結合 `playerID` 和 `value` 進行複雜判斷

**行為**：
- 自定義函數接收 `(PlayerID, Value)` 參數（注意順序與 `.perPlayer` 不同）
- 返回該玩家應該看到的值（`Value?`，**必須返回相同類型**）
- 如果返回 `nil`，該字段不會出現在該玩家的 snapshot 中
- **必須返回相同類型**以確保類型安全，macro 可以直接使用類型轉換
- 最靈活的方式，可以實現任何複雜的過濾邏輯

**範例**：
```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    // 自定義邏輯：根據玩家角色決定可見性
    @Sync(.custom { playerID, data in
        // 檢查玩家是否有權限
        guard let player = getPlayer(playerID),
              player.role == .admin else {
            return nil  // 非管理員看不到
        }
        return data
    })
    var adminData: AdminData = AdminData()
    
    // 自定義邏輯：根據玩家狀態決定可見內容
    @Sync(.custom { playerID, hp in
        // 返回 Int（相同類型），但可以根據條件返回 nil
        if getPlayer(playerID)?.canSeeHP == true {
            return hp  // 返回原始值
        }
        return nil  // 隱藏字段
    })
    var hp: Int = 100
    
    // 自定義邏輯：根據玩家狀態決定可見內容
    @Sync(.custom { playerID, messages in
        let player = getPlayer(playerID)
        // 只返回該玩家應該看到的訊息
        return messages.filter { message in
            message.recipients.contains(playerID) ||
            message.isPublic ||
            (player?.isModerator == true && message.needsModeration)
        }
    })
    var chatMessages: [ChatMessage] = []
}
```

**⚠️ 類型轉換說明**：
- `custom` **必須返回相同類型**（`Value?`）
- Macro 生成的代碼可以直接使用類型轉換，無需運行時類型檢查
- 這確保了類型安全，同時保持了靈活性（可以根據條件返回 `nil`）
- 如果需要類型轉換（例如 `Int -> String`），應該在 StateNode 層級處理（使用計算屬性或另一個字段）

## Policy 類型對比

| Policy | 依賴 playerID | 所有玩家看到相同值 | 返回類型 | 返回 nil 的意義 | Macro 處理方式 |
|--------|--------------|------------------|---------|----------------|----------------|
| `.serverOnly` | ❌ | N/A | N/A | 不出現在 snapshot | N/A |
| `.broadcast` | ❌ | ✅ | **相同** | N/A（總是返回值） | 直接類型轉換 |
| `.perPlayer` | ✅ | ❌ | **相同** | 該玩家看不到此字段 | 直接類型轉換 |
| `.masked` | ❌ | ✅ | **相同** | N/A（總是返回值，且類型相同） | 直接類型轉換 |
| `.custom` | ✅ | ❌ | **相同** | 該玩家看不到此字段 | 直接類型轉換 |

### 關鍵差異總結

1. **`.perPlayer` vs `.custom`**：
   - 參數順序不同：`perPlayer(Value, PlayerID)` vs `custom(PlayerID, Value)`
   - 兩者都可以返回任意類型，使用 `SnapshotValue.make()` 處理

2. **`.masked` vs `.custom`**：
   - `.masked`：不依賴 `playerID`，所有玩家看到相同值，**必須返回相同類型**
   - `.custom`：依賴 `playerID`，每個玩家可能看到不同值，**可以返回任意類型**

3. **類型安全 vs 靈活性**：
   - `.masked`：類型安全（編譯時檢查），但只能返回相同類型
   - `.perPlayer` / `.custom`：靈活（可以返回任意類型），但需要運行時類型檢查

## Policy 組合規則

### 規則 1：Parent 決定哪些 Child 節點出現

| Parent Policy | Child 節點可見性 |
|--------------|-----------------|
| `.broadcast` | 所有 child 節點都出現 |
| `.perPlayerSlice()` | 只出現該玩家的 child 節點 |
| `.serverOnly` | 不出現任何 child 節點 |

### 規則 2：Child 決定該節點內哪些字段出現

| Child Policy | 字段可見性 |
|-------------|-----------|
| `.broadcast` | 出現在 snapshot 中 |
| `.perPlayerSlice()` | 只保留該玩家的值 |
| `.serverOnly` | 不出現在 snapshot 中 |

### 規則 3：組合結果

```
最終可見性 = Parent Policy (決定節點) × Child Policy (決定字段)
```

**範例組合**：

| Parent | Child | 結果 |
|--------|-------|------|
| `.broadcast` | `.broadcast` | 所有玩家看到所有節點的所有字段 |
| `.broadcast` | `.perPlayerSlice()` | 所有玩家看到所有節點，但字段過濾 |
| `.perPlayerSlice()` | `.broadcast` | 每個玩家只看到自己的節點，但節點內所有字段可見 |
| `.perPlayerSlice()` | `.perPlayerSlice()` | 每個玩家只看到自己的節點，且字段也過濾 |

## 設計優勢

### 1. 語義清晰
- 每個 policy 都有明確的語義
- 不依賴上下文（parent policy）

### 2. 靈活性
- 可以任意組合不同的 policy
- Parent policy 改變時，child 不需要修改

### 3. 可擴展性
- 支持無限嵌套
- 每個層級獨立過濾

### 4. 一致性
- 所有節點使用相同的過濾機制
- 易於理解和維護

## 實際應用場景

### 場景 1：共享狀態 + 個人數據

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)  // 所有玩家看到所有玩家節點
    var players: [PlayerID: PlayerNode] = [:]
    
    @Sync(.perPlayerSlice())  // 每個玩家只看到自己的手牌
    var hands: [PlayerID: [Card]] = [:]
}
```

### 場景 2：完全隔離

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.perPlayerSlice())  // 每個玩家只看到自己的節點
    var players: [PlayerID: PlayerNode] = [:]
}
```

### 場景 3：嵌套過濾

```swift
@StateNodeBuilder
struct PlayerNode: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.perPlayerSlice())  // 嵌套過濾
    var inventory: [PlayerID: [Item]] = [:]
}

@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)  // 所有玩家看到所有玩家節點
    var players: [PlayerID: PlayerNode] = [:]
    // 但每個節點內的 inventory 會根據 playerID 過濾
}
```

## 與其他設計的對比

### 選項 1：當前設計（獨立過濾）

**理念**：每個節點獨立決定自己的 policy

**優點**：
- 語義清晰
- 靈活性高
- 一致性強

### 選項 2：Policy 繼承性

**理念**：Parent 的 policy 會影響 child 的語義

**缺點**：
- 語義複雜
- 靈活性降低
- 實現複雜

**結論**：當前設計（獨立過濾）更適合，因為它提供了更好的靈活性和一致性。

## 測試驗證

為了確保這個設計理念正確運作，應該測試：

1. ✅ **基本組合**：不同 parent-child policy 組合
2. ✅ **多層嵌套**：三層或更多層的嵌套
3. ✅ **邊界情況**：空節點、單一節點等
4. ✅ **實際場景**：共享倉庫 vs 獨立倉庫
5. ✅ **類型轉換**：`perPlayer` 和 `custom` 返回不同類型的情況

詳見測試文件：
- `Tests/SwiftStateTreeTests/SyncEngineEndToEndTests.swift`
- `Tests/SwiftStateTreeTests/SyncEnginePolicyCombinationTests.swift`
- `Tests/SwiftStateTreeTests/SyncEnginePolicyTypeTests.swift`

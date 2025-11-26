# Nested StateNode Per-Player 過濾機制說明

## 問題背景

當我們有一個 nested StateNode 結構，例如：

```swift
@StateNodeBuilder
struct TestPlayerNode: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.perPlayerSlice())
    var inventory: [PlayerID: [String]] = [:]
}

@StateNodeBuilder
struct E2ETestGameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: TestPlayerNode] = [:]
}
```

## 實際行為說明

### 1. Server 端的實際數據結構

```swift
// Server 端存儲的完整數據：
serverState.players["alice"] = TestPlayerNode(
    name: "Alice",
    inventory: [
        "alice": ["sword", "shield"],  // Alice 自己的物品
        "bob": ["bow"]                 // Bob 存放在 Alice 這裡的物品
    ]
)

serverState.players["bob"] = TestPlayerNode(
    name: "Bob",
    inventory: [
        "bob": ["arrow"],              // Bob 自己的物品
        "alice": ["potion"]             // Alice 存放在 Bob 這裡的物品
    ]
)
```

### 2. 為 Alice 生成 Snapshot 時的過濾過程

當調用 `syncEngine.snapshot(for: alice, from: serverState)` 時：

#### Step 1: 根節點過濾
- `players` 是 `.broadcast`，所以**所有玩家節點都會包含**在 snapshot 中
- Snapshot 包含：`players["alice"]` 和 `players["bob"]`

#### Step 2: 嵌套節點遞歸過濾
對於每個嵌套的 `TestPlayerNode`，系統會**遞歸調用** `snapshot(for: alice, ...)`：

**對於 `players["alice"]` (Alice 自己的節點)**：
- `name`: `.broadcast` → 包含 "Alice"
- `inventory`: `.perPlayerSlice()` → **過濾為只包含 `alice` key 的值**
  - 結果：`["sword", "shield"]` (只保留 `inventory["alice"]` 的值)

**對於 `players["bob"]` (Bob 的節點)**：
- `name`: `.broadcast` → 包含 "Bob"
- `inventory`: `.perPlayerSlice()` → **過濾為只包含 `alice` key 的值**
  - 結果：`["potion"]` (只保留 `inventory["alice"]` 的值，因為 Bob 的 inventory 中有 `["alice": ["potion"]]`)

### 3. 最終 Snapshot 結構（為 Alice 生成）

```json
{
  "players": {
    "alice": {
      "name": "Alice",
      "inventory": ["sword", "shield"]  // ✅ 只包含 alice 的物品
    },
    "bob": {
      "name": "Bob",
      "inventory": ["potion"]            // ✅ 只包含 alice 存放在 Bob 這裡的物品
    }
  }
}
```

## 關鍵理解點

### ✅ 正確理解

1. **每個嵌套節點獨立過濾**：
   - 當生成 snapshot 時，每個嵌套的 `TestPlayerNode` 都會**獨立地**根據 snapshot 的 `playerID` 進行過濾
   - `players["alice"]` 的 `inventory` 過濾為只包含 `alice` 的物品
   - `players["bob"]` 的 `inventory` **也**過濾為只包含 `alice` 的物品（如果 Bob 的 inventory 中有 `alice` key）

2. **Broadcast 字段保留所有節點**：
   - 因為 `players` 是 `.broadcast`，所以 snapshot 中會包含**所有玩家節點**
   - 但每個節點內部的 per-player 字段會被過濾

3. **這是設計行為，不是 Bug**：
   - 這個設計允許「跨玩家共享物品」的場景
   - 例如：Alice 可以將物品存放在 Bob 的倉庫中，Bob 可以看到這些物品

### ❌ 錯誤理解

1. **誤解**：Alice 的 snapshot 中，`players["bob"].inventory` 應該是空的
   - **實際**：如果 Bob 的 inventory 中有 `alice` key，Alice 可以看到這些物品

2. **誤解**：每個玩家只能看到自己的 inventory
   - **實際**：每個玩家可以看到**所有玩家 inventory 中 key 為自己 ID 的物品**

## 兩種設計方案對比

### 設計 1：共享倉庫（Shared Inventory）- `[PlayerID: [String]]`

**適用場景**：需要支持跨玩家共享物品

```swift
@StateNodeBuilder
struct TestPlayerNode: StateNodeProtocol {
    @Sync(.perPlayerSlice())
    var inventory: [PlayerID: [String]] = [:]  // 需要 PlayerID 作為 key
}

// 使用方式：
aliceNode.inventory[alice] = ["sword", "shield"]  // Alice 自己的物品
aliceNode.inventory[bob] = ["bow"]                 // Bob 存放在 Alice 這裡的物品
bobNode.inventory[bob] = ["arrow"]                // Bob 自己的物品
bobNode.inventory[alice] = ["potion"]              // Alice 存放在 Bob 這裡的物品

// Alice 的 snapshot：
// - players["alice"].inventory = ["sword", "shield"] ✅ (只看到自己的)
// - players["bob"].inventory = ["potion"] ✅ (看到自己存放在 Bob 這裡的物品)
```

**特點**：
- 支持跨玩家共享物品
- 需要 `@Sync(.perPlayerSlice())` 來過濾
- 每個玩家可以看到自己存放在其他玩家倉庫中的物品

### 設計 2：獨立倉庫（Independent Inventory）- `[String]`

**適用場景**：每個玩家的 inventory 完全獨立

```swift
@StateNodeBuilder
struct TestPlayerNodeWithIndependentInventory: StateNodeProtocol {
    @Sync(.broadcast)
    var inventory: [String] = []  // 不需要 PlayerID 作為 key
}

// 使用方式：
aliceNode.inventory = ["sword", "shield"]  // Alice 自己的物品
bobNode.inventory = ["arrow", "bow"]        // Bob 自己的物品

// Alice 的 snapshot：
// - players["alice"].inventory = ["sword", "shield"] ✅
// - players["bob"].inventory = ["arrow", "bow"] ✅ (因為 players 是 broadcast，所有玩家都看到)
```

**特點**：
- 每個玩家的 inventory 完全獨立
- 不需要 PlayerID 作為 key（因為每個 `TestPlayerNode` 實例本身就是專屬於某個玩家的）
- 如果 `players` 是 `.broadcast`，所有玩家都可以看到所有玩家的 inventory
- 如果 `players` 是 `.perPlayerSlice()`，每個玩家只能看到自己的 player 節點

## 實際應用場景

### 場景 1：個人倉庫（使用獨立倉庫設計）
```swift
// 使用設計 2：獨立倉庫
aliceNode.inventory = ["sword", "shield"]
bobNode.inventory = ["arrow"]

// Alice 的 snapshot（如果 players 是 broadcast）：
// - players["alice"].inventory = ["sword", "shield"] ✅
// - players["bob"].inventory = ["arrow"] ✅ (可以看到 Bob 的 inventory)
```

### 場景 2：共享倉庫（使用共享倉庫設計）
```swift
// 使用設計 1：共享倉庫
aliceNode.inventory[alice] = ["sword", "shield"]
bobNode.inventory[alice] = ["potion"]  // Alice 存放在 Bob 這裡的物品

// Alice 的 snapshot：
// - players["alice"].inventory = ["sword", "shield"] ✅
// - players["bob"].inventory = ["potion"] ✅ (可以看到自己存放在 Bob 這裡的物品)
```

## 測試調整

基於這個理解，測試應該驗證：

1. ✅ Alice 可以看到自己的 inventory
2. ✅ Alice 可以看到存放在其他玩家 inventory 中 key 為 `alice` 的物品
3. ✅ Alice **不能**看到其他玩家存放在自己 inventory 中的物品（除非 key 是 `alice`）

這就是為什麼測試中：
- `aliceClientState.players["alice"]?.inventory == ["sword", "shield"]` ✅
- `aliceClientState.players["bob"]?.inventory == ["potion"]` ✅ (因為 Bob 的 inventory 中有 `["alice": ["potion"]]`)


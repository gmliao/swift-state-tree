# 效能優化計劃

> 本文檔記錄 SwiftStateTree 的後續效能優化計劃和設計方向

## 概述

目前 SwiftStateTree 已經實現了基本的同步機制和 diff 計算，**並支援遞迴過濾功能**（巢狀 StateNode 可以獨立套用 @Sync 政策）。

**重要說明**：遞迴過濾已經解決了以下問題：
- ✅ **細粒度過濾**：不需要 ReactiveDictionary，可以用 StateNode 來細分
- ✅ **Per-Player 細分**：不需要 Per-Player State View 架構，遞迴過濾已經可以做到

為了進一步提升效能，特別是針對大型狀態樹和高頻更新場景，我們計劃實施以下優化策略。

## 優化目標

1. **減少不必要的計算**：只處理真正改變的欄位
2. **細粒度追蹤**：支援 per-player 層級的細粒度變更追蹤
3. **容器優化**：針對 Dictionary、Set 等容器的特殊優化
4. **自動化**：減少手動標記的需求，自動偵測變更

---

## 1. isDirty 機制優化

### 目標
實現自動化的 dirty tracking，無需手動標記即可偵測狀態變更。

### 設計方向

#### 1.1 Property Wrapper 層級的 Dirty Tracking

在 `@Sync` property wrapper 層級自動追蹤變更：

```swift
@StateTreeBuilder
struct GameStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var round: Int = 0  // 自動追蹤變更，無需手動 markDirty
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: HandState] = [:]  // 自動追蹤 Dictionary 變更
}
```

**實作方式**：
- 在 `@Sync` property wrapper 的 `wrappedValue` setter 中自動標記 dirty
- 使用 `willSet`/`didSet` 或 `_modify` 來攔截變更
- 維護內部 dirty 狀態，由 SyncEngine 查詢

#### 1.2 自動 Dirty 查詢 API

```swift
protocol StateTreeProtocol {
    /// 檢查是否有任何欄位被標記為 dirty
    func isDirty() -> Bool
    
    /// 檢查特定欄位是否為 dirty
    func isDirty(_ fieldName: String) -> Bool
    
    /// 檢查特定玩家的 per-player 欄位是否為 dirty
    func isDirty(_ fieldName: String, for playerID: PlayerID) -> Bool
    
    /// 取得所有 dirty 欄位名稱
    func getDirtyFields() -> Set<String>
}
```

#### 1.3 與 SyncEngine 整合

**重要設計考量**：如果 `isDirty == false` 就跳過生成欄位，會導致誤判為刪除。

**問題場景**：
```swift
// 舊快照（cache）
{
  "round": 10,
  "players": {...}
}

// 新狀態：round 沒變（isDirty = false），players 變了（isDirty = true）
// 如果只生成 dirty 欄位：
{
  "players": {...}  // 只有 players，沒有 round
}

// 比較時：
// oldSnapshot["round"] = 10
// newSnapshot["round"] = nil  // 沒有這個欄位！
// → 會被誤判為刪除！❌
```

**解決方案**：比較時需要考慮 dirty 資訊

```swift
extension SyncEngine {
    /// 使用自動 dirty tracking 生成 diff
    public mutating func generateDiff<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State,
        useDirtyTracking: Bool = true  // 預設啟用
    ) throws -> StateUpdate {
        if useDirtyTracking && state.isDirty() {
            // 取得 dirty 欄位資訊
            let dirtyFields = state.getDirtyFields()
            
            // 只生成 dirty 欄位的快照（減少序列化開銷）
            let dirtySnapshot = try state.snapshot(for: playerID, onlyDirty: true)
            
            // 比較時傳入 dirty 資訊，避免誤判刪除
            return try generateDiffWithDirtyTracking(
                for: playerID,
                from: state,
                dirtyFields: dirtyFields
            )
        } else {
            // 標準方式：檢查所有欄位
            return try generateDiffStandard(for: playerID, from: state)
        }
    }
    
    /// 比較時考慮 dirty 資訊，避免誤判刪除
    private func compareSnapshots(
        from oldSnapshot: StateSnapshot,
        to newSnapshot: StateSnapshot,
        dirtyFields: Set<String>,  // 新增：dirty 欄位資訊
        onlyPaths: Set<String>? = nil
    ) -> [StatePatch] {
        var patches: [StatePatch] = []
        let allKeys = Set(oldSnapshot.values.keys).union(Set(newSnapshot.values.keys))
        
        for key in allKeys {
            let oldValue = oldSnapshot.values[key]
            let newValue = newSnapshot.values[key]
            
            if oldValue != nil && newValue == nil {
                // ⚠️ 關鍵：如果這個欄位不是 dirty，視為未變更（避免誤判刪除）
                if !dirtyFields.contains(key) {
                    continue  // 跳過，視為未變更
                }
                // 如果是 dirty 且不存在，才是真正的刪除
                patches.append(StatePatch(path: "/\(key)", operation: .delete))
            } else if oldValue == nil && newValue != nil {
                // 新增
                patches.append(StatePatch(path: "/\(key)", operation: .set(newValue)))
            } else if let oldValue = oldValue, let newValue = newValue {
                // 兩個都存在，比較值（只比較 dirty 欄位）
                if dirtyFields.contains(key) {
                    patches.append(contentsOf: compareSnapshotValues(
                        from: oldValue,
                        to: newValue,
                        basePath: "/\(key)"
                    ))
                }
                // 如果不是 dirty，跳過比較
            }
        }
        
        return patches
    }
}
```

**設計原則**：
1. **只生成 dirty 欄位的快照**：減少序列化開銷
2. **比較時傳入 dirty 資訊**：避免誤判刪除
3. **只比較 dirty 欄位**：減少比較開銷

### 優點
- **零配置**：開發者無需手動標記，自動運作
- **向後相容**：可以選擇性啟用，不影響現有程式碼
- **效能提升**：
  - 只序列化 dirty 欄位（減少序列化開銷）
  - 只比較 dirty 欄位（減少比較開銷）
  - 正確處理刪除（需要 dirty 資訊）

### 挑戰
- Property wrapper 的變更攔截需要仔細設計
- 需要處理 nested 結構的變更追蹤
- **容器類型（Dictionary、Set）的變更偵測較複雜**：這是 Property Wrapper 的根本限制
  - `state.players["alice"] = "Alice"` 不會觸發 property wrapper 的 setter
   - 需要額外機制來追蹤容器內部變更（已由遞迴過濾解決）
- **避免誤判刪除**：比較時需要 dirty 資訊來區分「未變更」和「真正刪除」

---

## 2. 細粒度優化（Fine-grained Optimization）

> **注意**：遞迴過濾已經提供了細粒度控制能力。此章節主要說明如何與 dirty tracking 配合使用。

### 目標
支援更細粒度的變更追蹤，特別是針對 per-player 欄位。

### 設計方向

#### 2.1 與遞迴過濾配合的細粒度追蹤

遞迴過濾已經可以做到細分，但 dirty tracking 可以進一步減少計算：

```swift
@StateNodeBuilder
struct PlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast) var position: Vec2
    @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
}

@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]
}

// 只有 Alice 的 inventory 改變
state.players[alice].inventory[bob] = ["item1"]

// 自動標記：只有 players[alice].inventory 欄位是 dirty
// 遞迴過濾 + dirty tracking：只處理變更的部分
```

#### 2.2 Dictionary 值層級的追蹤

對於 `@Sync(.perPlayerDictionaryValue())` 欄位，追蹤到具體的 key：

```swift
@Sync(.perPlayerDictionaryValue())
var hands: [PlayerID: HandState] = [:]
 
// 內部追蹤：
// dirtyKeys: Set<PlayerID> = [alice]  // 只有 alice 的 hands 改變
```

**實作方式**：
- 在 Dictionary 的 subscript setter 中記錄變更的 key
- SyncEngine 只處理 dirty keys 對應的值
- 與遞迴過濾配合：如果值是 StateNode，會遞迴套用過濾

### 優點
- **精確追蹤**：只處理真正改變的部分
- **效能提升**：大型容器中只有小部分改變時，效能提升明顯
- **頻寬節省**：只傳輸改變的部分
- **與遞迴過濾配合**：可以做到非常細粒度的控制

### 挑戰
- 需要實作容器類型的特殊處理
- 變更偵測的實作複雜度較高

---

## 3. 容器優化（Container Optimization）

### 目標
針對 Dictionary、Set 等容器類型進行特殊優化。

### 設計方向

#### 3.1 Dictionary 優化

**問題**：當 Dictionary 只有部分 key-value 改變時，目前會比較整個 Dictionary。

**優化方案**：
- 追蹤變更的 keys
- 只比較和序列化變更的 key-value pairs
- 使用 path-based diff：`/hands/alice` 而不是 `/hands`

```swift
// 優化前：比較整個 hands Dictionary
let oldHands = lastSnapshot.values["hands"]  // 整個 Dictionary
let newHands = currentSnapshot.values["hands"]  // 整個 Dictionary
compare(oldHands, newHands)  // 比較所有 key-value pairs

// 優化後：只比較變更的 key
let dirtyKeys = state.getDirtyKeys(for: "hands")  // [alice]
for key in dirtyKeys {
    let oldValue = oldHands[key]
    let newValue = newHands[key]
    compare(oldValue, newValue)  // 只比較變更的 key
}
```

#### 3.2 Set 優化

**問題**：Set 的變更需要知道新增和刪除的元素。

**優化方案**：
- 追蹤新增和刪除的元素
- 使用 set difference 來計算變更

```swift
let oldSet: Set<PlayerID> = lastSnapshot.values["readyPlayers"]
let newSet: Set<PlayerID> = currentSnapshot.values["readyPlayers"]

let added = newSet.subtracting(oldSet)  // 新增的元素
let removed = oldSet.subtracting(newSet)  // 刪除的元素

// 生成 patches
for playerID in added {
    patches.append(StatePatch(path: "/readyPlayers/\(playerID)", operation: .set(true)))
}
for playerID in removed {
    patches.append(StatePatch(path: "/readyPlayers/\(playerID)", operation: .delete))
}
```

### 優點
- **大幅減少計算量**：只處理變更的部分
- **頻寬節省**：只傳輸變更的資料
- **更好的效能**：特別是在大型容器場景

### 挑戰
- 需要為每種容器類型實作特殊處理
- 需要處理 nested 容器（Dictionary of Dictionaries 等）

---

## 4. ~~Vue 3 Proxy 風格的響應式追蹤~~（已由遞迴過濾解決）

> **已移除**：遞迴過濾功能已經解決了原本需要 ReactiveDictionary 的問題。
> 
> **替代方案**：使用 StateNode 來細分，不需要額外的容器類型：
> 
> ```swift
> // ❌ 原本需要 ReactiveDictionary
> @Sync(.broadcast)
> var players: ReactiveDictionary<PlayerID, String> = [:]
> 
> // ✅ 現在可以用 StateNode 細分
> @StateNodeBuilder
> struct PlayerStateNode: StateNodeProtocol {
>     @Sync(.broadcast) var name: String
>     @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
> }
> 
> @StateNodeBuilder
> struct GameStateRootNode: StateNodeProtocol {
>     @Sync(.broadcast)
>     var players: [PlayerID: PlayerStateNode] = [:]
> }
> ```
> 
> 遞迴過濾會自動處理巢狀結構的過濾，不需要額外的容器類型。

---

## 5. 自動偵測與標記（Auto-detection and Marking）

### 目標
減少手動標記的需求，自動偵測和標記變更。

### 設計方向

#### 5.1 Property Wrapper 自動標記

在 `@Sync` property wrapper 中自動標記變更：

```swift
@propertyWrapper
struct Sync<Value> {
    private var _value: Value
    private var _isDirty: Bool = false
    
    var wrappedValue: Value {
        get { _value }
        set {
            if _value != newValue {  // 只有真正改變時才標記
                _value = newValue
                _isDirty = true
            }
        }
    }
    
    var projectedValue: Sync<Value> { self }
    
    func isDirty() -> Bool { _isDirty }
    mutating func clearDirty() { _isDirty = false }
}
```

#### 5.2 容器類型的自動標記

對於 Dictionary、Array、Set 等容器類型，`@StateNodeBuilder` macro 會自動生成 helper methods，這些方法會在變更時自動標記為 dirty。

**重要設計原則**：**只要調用 set 操作就標記為 dirty，不管操作是否成功改變了值**。這是為了簡化實作和避免複雜的比較邏輯。

##### Dictionary 容器類型

對於標記為 `@Sync` 的 Dictionary 欄位，macro 會自動生成以下 helper methods：

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
}

// Macro 自動生成：
// - updatePlayers(_:forKey:) - 更新或插入值
// - removePlayers(forKey:) - 移除值
// - setPlayers(_:forKey:) - 設定值（updatePlayers 的別名）
```

**使用範例**：
```swift
var state = GameStateRootNode()

// 更新或插入值（總是標記為 dirty）
state.updatePlayers(newState, forKey: alice)
// ✅ isDirty() == true
// ✅ getDirtyFields().contains("players") == true

// 移除值（總是標記為 dirty，即使 key 不存在）
let removed = state.removePlayers(forKey: bob)
// ✅ isDirty() == true（即使 bob 不存在也會標記為 dirty）
```

**注意**：
- `updatePlayers(_:forKey:)` 總是標記為 dirty，即使新值與舊值相同
- `removePlayers(forKey:)` 總是標記為 dirty，即使 key 不存在（返回 nil）

##### Array 容器類型

對於標記為 `@Sync` 的 Array 欄位，macro 會自動生成以下 helper methods：

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var cards: [Card] = []
}

// Macro 自動生成：
// - appendCards(_:) - 在末尾添加元素
// - removeCards(at:) - 移除指定索引的元素
// - insertCards(_:at:) - 在指定索引插入元素
```

**使用範例**：
```swift
var state = GameStateRootNode()

// 添加元素（總是標記為 dirty）
state.appendCards(newCard)
// ✅ isDirty() == true

// 移除元素（總是標記為 dirty）
let removed = state.removeCards(at: 0)
// ✅ isDirty() == true

// 插入元素（總是標記為 dirty）
state.insertCards(newCard, at: 0)
// ✅ isDirty() == true
```

**注意**：
- 所有 Array helper methods 總是標記為 dirty，不管操作是否成功改變了陣列內容

##### Set 容器類型

對於標記為 `@Sync` 的 Set 欄位，macro 會自動生成以下 helper methods：

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var readyPlayers: Set<PlayerID> = []
}

// Macro 自動生成：
// - insertReadyPlayers(_:) - 插入元素（返回 inserted: Bool）
// - removeReadyPlayers(_:) - 移除元素（返回元素或 nil）
```

**使用範例**：
```swift
var state = GameStateRootNode()

// 插入元素（總是標記為 dirty，即使元素已存在）
let result = state.insertReadyPlayers(alice)
// ✅ isDirty() == true（即使 inserted == false 也會標記為 dirty）
// ✅ getDirtyFields().contains("readyPlayers") == true

// 移除元素（總是標記為 dirty，即使元素不存在）
let removed = state.removeReadyPlayers(bob)
// ✅ isDirty() == true（即使 removed == nil 也會標記為 dirty）
```

**重要說明**：
- `insertReadyPlayers(_:)` 總是標記為 dirty，**即使元素已經存在**（`inserted == false`）
- `removeReadyPlayers(_:)` 總是標記為 dirty，**即使元素不存在**（返回 nil）
- 這是設計上的選擇：**只要調用 set 操作就標記為 dirty**，簡化實作並避免複雜的比較邏輯

##### 為什麼採用「總是標記為 dirty」的設計？

1. **簡化實作**：不需要比較新舊值，避免 `Equatable` 約束和複雜的比較邏輯
2. **一致性**：所有 set 操作都有一致的行為，容易理解和維護
3. **效能考量**：雖然可能產生一些「假陽性」（false positive），但可以通過 `clearDirty()` 在適當的時機清除
4. **避免誤判**：確保所有變更都被追蹤，不會遺漏任何可能的狀態變化

#### 5.3 Nested 結構的自動標記

當 nested 結構改變時，自動標記父層級：

```swift
// 當 PlayerState 改變時，自動標記 players Dictionary 為 dirty
state.players[alice].hpCurrent = 50
// 自動標記：players[alice] 為 dirty，進而標記 players 欄位為 dirty
```

#### 5.4 變更通知機制

使用觀察者模式或 Combine 來通知變更：

```swift
protocol StateTreeProtocol {
    /// 變更通知（可選實作）
    var changeNotifier: ChangeNotifier? { get }
}

class ChangeNotifier {
    func notifyFieldChanged(_ fieldName: String, for playerID: PlayerID?) {
        // 通知 SyncEngine 或相關系統
    }
}
```

### 優點
- **開發體驗**：開發者無需手動標記，減少錯誤
- **自動化**：系統自動處理，減少維護成本
- **一致性**：確保所有變更都被正確追蹤

### 挑戰
- Property wrapper 的實作需要仔細設計
- 需要處理各種邊界情況
- 效能開銷需要評估（每次 setter 調用的成本）

---

## 5. 快取優化（Cache Optimization）

### 目標
優化 SyncEngine 的快取機制，減少記憶體使用和計算開銷。

### 設計方向

#### 5.1 增量快取更新

目前每次 diff 計算後會更新整個快照。優化為只更新變更的部分：

```swift
// 優化前：替換整個快照
lastBroadcastSnapshot = currentBroadcastSnapshot

// 優化後：只更新變更的部分
lastBroadcastSnapshot.merge(patches)  // 只更新變更的欄位
```

#### 5.2 快取壓縮

對於大型狀態樹，使用壓縮或序列化來減少記憶體使用：

```swift
// 可選：使用壓縮格式儲存快照
private var lastBroadcastSnapshotCompressed: Data?

// 需要時再解壓縮
func getLastBroadcastSnapshot() -> StateSnapshot? {
    guard let compressed = lastBroadcastSnapshotCompressed else { return nil }
    return try? decompress(compressed)
}
```

#### 5.3 快取過期機制

對於長時間未使用的玩家快照，可以選擇性清除：

```swift
struct CacheEntry {
    let snapshot: StateSnapshot
    let lastAccessed: Date
}

private var lastPerPlayerSnapshots: [PlayerID: CacheEntry] = [:]

func cleanupStaleCache(olderThan interval: TimeInterval) {
    let cutoff = Date().addingTimeInterval(-interval)
    lastPerPlayerSnapshots = lastPerPlayerSnapshots.filter { $0.value.lastAccessed > cutoff }
}
```

### 優點
- **記憶體節省**：只儲存必要的資料
- **效能提升**：減少不必要的快照複製
- **可擴展性**：支援更多玩家和更大的狀態樹

---

## 6. 序列化優化（Serialization Optimization）

### 目標
優化狀態序列化為 JSON 或其他格式的過程。

### 設計方向

#### 6.1 增量序列化

只序列化變更的部分，而不是整個狀態：

```swift
// 優化前：序列化整個快照
let json = try JSONEncoder().encode(fullSnapshot)

// 優化後：只序列化 patches
let json = try JSONEncoder().encode(patches)  // 只包含變更的部分
```

#### 6.2 自訂編碼器

針對 StateSnapshot 和 StatePatch 使用自訂編碼器：

```swift
extension StateSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case values
        case dirtyFields  // 可選：標記哪些欄位是 dirty
    }
    
    func encode(to encoder: Encoder) throws {
        // 自訂編碼邏輯，優化大小
    }
}
```

#### 6.3 二進位格式支援

考慮支援更緊湊的二進位格式（如 MessagePack、Protobuf）：

```swift
protocol StateSnapshotFormat {
    func encode(_ snapshot: StateSnapshot) throws -> Data
    func decode(_ data: Data) throws -> StateSnapshot
}

struct JSONFormat: StateSnapshotFormat { ... }
struct MessagePackFormat: StateSnapshotFormat { ... }
struct ProtobufFormat: StateSnapshotFormat { ... }
```

### 優點
- **頻寬節省**：更小的 payload
- **效能提升**：更快的序列化/反序列化
- **靈活性**：支援多種格式

---

## 7. ~~Per-Player State View 架構~~（已由遞迴過濾解決）

> **已移除**：遞迴過濾功能已經解決了原本需要 Per-Player State View 的問題。
> 
> **替代方案**：使用遞迴過濾，每個 StateNode 可以獨立套用 @Sync 政策：
> 
> ```swift
> // ❌ 原本需要 Per-Player State View
> @StateTreeBuilder
> struct PlayerStateView: StateTreeProtocol {
>     @Sync(.broadcast)
>     var hands: HandState = HandState()
> }
> 
> // ✅ 現在可以用遞迴過濾
> @StateNodeBuilder
> struct PlayerStateNode: StateNodeProtocol {
>     @Sync(.broadcast) var position: Vec2
>     @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
> }
> 
> @StateNodeBuilder
> struct GameStateRootNode: StateNodeProtocol {
>     @Sync(.broadcast)
>     var players: [PlayerID: PlayerStateNode] = [:]
> }
> ```
> 
> 遞迴過濾會自動處理每個玩家的狀態，不需要額外的視圖架構。

---

## 實作優先順序與方案組合

### 一般場景：Dirty Tracking + 改進的 Diff + 遞迴過濾（推薦）

適合大多數遊戲場景（5-50 玩家），實作簡單且效果明顯。

**重要**：遞迴過濾已經實現，可以細分到 subnode 層級。

#### Phase 1: 基礎優化（高優先級）
1. ⏳ **isDirty 機制**：實作基本的 dirty tracking
   - 在 `@Sync` property wrapper 中自動標記變更
   - 提供 `isDirty()` 和 `getDirtyFields()` API
   - **與遞迴過濾配合**：可以追蹤到巢狀 StateNode 的變更
   
2. ⏳ **自動標記**：Property wrapper 層級的自動追蹤
   - 基本類型（Int, String 等）自動標記
   - 容器類型需要手動標記或使用 helper methods
   - **與遞迴過濾配合**：巢狀 StateNode 的變更會自動傳播

3. ⏳ **增量快取更新**：只更新變更的部分
   - 快取合併時只更新 dirty 欄位
   - **與遞迴過濾配合**：只更新變更的 subnode

#### Phase 2: 容器優化（中優先級）
4. ⏳ **Dictionary 優化**：追蹤變更的 keys
   - 只比較和序列化變更的 key-value pairs
   - 使用 path-based diff：`/hands/alice` 而不是 `/hands`
   - **與遞迴過濾配合**：如果值是 StateNode，會遞迴套用過濾

5. ⏳ **Set 優化**：追蹤新增和刪除的元素
   - 使用 set difference 來計算變更

#### 組合效果
```swift
// 使用 Dirty Tracking + 改進的 Diff + 遞迴過濾
@StateNodeBuilder
struct PlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast) var position: Vec2
    @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
}

@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol, DirtyTrackable {
    @Sync(.broadcast)
    var round: Int = 0  // 自動追蹤
    
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]  // 遞迴過濾 + dirty tracking
    
    // 使用時
    mutating func updatePlayerInventory(playerID: PlayerID, items: [Item]) {
        players[playerID]?.inventory[playerID] = items
        // 遞迴過濾會自動處理，dirty tracking 會標記變更
    }
}

// SyncEngine 只處理 dirty 欄位，遞迴過濾會自動套用
if state.isDirty() {
    // 內部會：
    // 1. 取得 dirty 欄位：["players"]
    // 2. 只生成 dirty 欄位的快照（減少序列化開銷）
    // 3. 比較時傳入 dirty 資訊，避免誤判刪除
    // 4. 只比較 dirty 欄位（減少比較開銷）
    let update = try syncEngine.generateDiffWithDirty(for: playerID, from: state)
    state.clearDirtyPaths()
}
```

**關鍵設計**：
- ✅ 只生成 dirty 欄位的快照（減少序列化開銷）
- ✅ 比較時傳入 dirty 資訊（避免誤判刪除）
- ✅ 只比較 dirty 欄位（減少比較開銷）
- ✅ 遞迴過濾自動套用（支援巢狀 StateNode）

**優點**：
- ✅ 實作簡單，容易整合
- ✅ 記憶體開銷低
- ✅ 適合大多數場景
- ✅ 向後相容
- ✅ **遞迴過濾已實現**：可以細分到 subnode 層級

---

### ~~高級場景：Per-Player State View + Dirty Tracking~~（已由遞迴過濾解決）

> **已移除**：遞迴過濾已經解決了原本需要 Per-Player State View 的問題。
> 
> **替代方案**：使用遞迴過濾 + Dirty Tracking：
> - 遞迴過濾可以細分到 subnode 層級
> - Dirty Tracking 可以減少不必要的計算
> - 不需要額外的視圖架構

---

### Phase 3: 進階優化（低優先級）
6. ⏳ **序列化優化**：自訂編碼器和二進位格式
7. ⏳ **快取壓縮和過期**：記憶體優化
8. ⏳ **細粒度 per-player 追蹤**：更精確的變更追蹤（與遞迴過濾配合）

---

## 方案選擇建議

### 決策流程

```
開始
  ↓
使用遞迴過濾（已實現）
  ↓
需要減少計算開銷？
  ├─ 是 → 使用：Dirty Tracking + 改進的 Diff + 遞迴過濾
  └─ 否 → 使用：遞迴過濾（已足夠）
```

**注意**：遞迴過濾已經實現，可以細分到 subnode 層級。Dirty Tracking 是可選的優化。

### 方案對比表

| 面向 | 遞迴過濾<br/>(已實現) | 遞迴過濾 + Dirty Tracking<br/>(推薦) |
|------|---------------------|-------------------------------------|
| **實作複雜度** | ✅ 已實現 | ⚠️ 需要實作 Dirty Tracking |
| **記憶體開銷** | ✅ 低 | ✅ 低 |
| **細粒度控制** | ✅ 支援到 subnode | ✅ 支援到 subnode + 減少計算 |
| **適用玩家數** | 所有場景 | 所有場景 |
| **維護成本** | ✅ 低 | ⚠️ 需要維護 Dirty Tracking |
| **效能提升** | 基礎 | 進一步優化 |

### 建議

1. **遞迴過濾已實現**（✅ 已完成）
   - 可以細分到 subnode 層級
   - 適合所有場景
   - 不需要額外的容器類型或視圖架構

2. **可選優化：Dirty Tracking + 改進的 Diff**
   - 進一步減少計算開銷
   - 適合高頻更新場景
   - 可以與遞迴過濾配合使用

---

## 效能基準測試

在實作每個優化時，應該建立基準測試來驗證效能提升：

```swift
// 範例：比較標準方式和 dirty tracking 方式的效能
func benchmarkDiffGeneration() {
    let standardTime = measure {
        for _ in 0..<1000 {
            _ = try syncEngine.generateDiff(for: playerID, from: state)
        }
    }
    
    let dirtyTrackingTime = measure {
        for _ in 0..<1000 {
            _ = try syncEngine.generateDiffWithDirty(for: playerID, from: state)
        }
    }
    
    print("Standard: \(standardTime)ms")
    print("Dirty Tracking: \(dirtyTrackingTime)ms")
    print("Improvement: \(standardTime / dirtyTrackingTime)x")
}
```

---

## 相關文檔

- [DESIGN_CORE.md](./DESIGN_CORE.md) - 核心概念和設計
- [DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md) - 運行時結構
- [DESIGN_SYNC_FIRSTSYNC.md](./DESIGN_SYNC_FIRSTSYNC.md) - 首次同步機制

---

## 注意事項

1. **向後相容性**：所有優化都應該保持向後相容，不破壞現有 API
2. **可選啟用**：優化功能應該可以選擇性啟用，讓開發者根據需求選擇
3. **效能測試**：每個優化都應該有對應的基準測試
4. **文檔更新**：實作優化後，應該更新相關文檔和範例


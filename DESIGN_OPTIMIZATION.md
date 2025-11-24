# 效能優化計劃

> 本文檔記錄 SwiftStateTree 的後續效能優化計劃和設計方向

## 概述

目前 SwiftStateTree 已經實現了基本的同步機制和 diff 計算。為了進一步提升效能，特別是針對大型狀態樹和高頻更新場景，我們計劃實施以下優化策略。

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

```swift
extension SyncEngine {
    /// 使用自動 dirty tracking 生成 diff
    public mutating func generateDiff<State: StateTreeProtocol>(
        for playerID: PlayerID,
        from state: State,
        useDirtyTracking: Bool = true  // 預設啟用
    ) throws -> StateUpdate {
        if useDirtyTracking && state.isDirty() {
            // 只處理 dirty 欄位
            return try generateDiffWithDirtyTracking(for: playerID, from: state)
        } else {
            // 標準方式：檢查所有欄位
            return try generateDiffStandard(for: playerID, from: state)
        }
    }
}
```

### 優點
- **零配置**：開發者無需手動標記，自動運作
- **向後相容**：可以選擇性啟用，不影響現有程式碼
- **效能提升**：只處理真正改變的欄位

### 挑戰
- Property wrapper 的變更攔截需要仔細設計
- 需要處理 nested 結構的變更追蹤
- **容器類型（Dictionary、Set）的變更偵測較複雜**：這是 Property Wrapper 的根本限制
  - `state.players["alice"] = "Alice"` 不會觸發 property wrapper 的 setter
  - 需要額外機制來追蹤容器內部變更（見第 4 章：Vue 3 Proxy 風格實作）

---

## 2. 細粒度優化（Fine-grained Optimization）

### 目標
支援更細粒度的變更追蹤，特別是針對 per-player 欄位。

### 設計方向

#### 2.1 Per-Player 細粒度追蹤

當只有特定玩家的欄位改變時，其他玩家不需要重新計算：

```swift
// 只有 Alice 的手牌改變
state.hands[alice] = ["card1", "card2"]

// 自動標記：只有 Alice 的 hands 欄位是 dirty
// Bob 和 Charlie 的 diff 計算會跳過 hands 欄位
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

### 優點
- **精確追蹤**：只處理真正改變的部分
- **效能提升**：大型容器中只有小部分改變時，效能提升明顯
- **頻寬節省**：只傳輸改變的部分

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

## 4. Vue 3 Proxy 風格的響應式追蹤

### 目標
實現類似 Vue 3 Proxy 的自動追蹤機制，無需手動標記即可偵測 Dictionary 和 Set 的內部變更。

### 問題背景

Swift 的 `@propertyWrapper` 有一個重要限制：**只能攔截整個變數的賦值，無法攔截容器內部的變更**。

```swift
@Sync(.broadcast)
var players: [PlayerID: String] = [:]

// ✅ 這樣會觸發 setter
state.players = ["alice": "Alice"]

// ❌ 這樣不會觸發 setter（直接修改 Dictionary 內部）
state.players["alice"] = "Alice"  // property wrapper 不知道
state.players["bob"] = "Bob"      // 不會被追蹤
```

這與 Vue 2 的問題類似。Vue 3 使用 Proxy 可以攔截所有操作，包括：
- 屬性讀取 (`get` trap)
- 屬性寫入 (`set` trap)
- 屬性刪除 (`deleteProperty` trap)

### 設計方向：自定義容器類型

在 Swift 中，我們可以通過**自定義容器類型**來模擬 Proxy 行為：

#### 4.1 ReactiveDictionary（類似 Proxy）

```swift
/// 類似 Vue 3 Proxy 的可追蹤 Dictionary
/// 自動攔截所有 Dictionary 操作並標記為 dirty
struct ReactiveDictionary<Key: Hashable, Value>: Sendable {
    // 實際儲存資料的地方
    private var _storage: [Key: Value]
    
    // 追蹤機制：記錄哪些 key 有變化（不論是新增、修改還是刪除）
    private var _isDirty: Bool = false
    private var _dirtyKeys: Set<Key> = []  // ⭐ 關鍵：用這個 Set 來追蹤變更的 keys
    
    private var onChange: (() -> Void)?
    
    init(_ dictionary: [Key: Value] = [:], onChange: (() -> Void)? = nil) {
        self._storage = dictionary
        self.onChange = onChange
    }
    
    // 攔截 subscript 操作（類似 Proxy 的 get/set trap）
    subscript(key: Key) -> Value? {
        get {
            // 讀取時可以記錄依賴（類似 Vue 的 effect tracking）
            return _storage[key]
        }
        set {
            // 寫入時自動標記 dirty（類似 Proxy 的 set trap）
            let wasPresent = _storage[key] != nil
            let oldValue = _storage[key]
            _storage[key] = newValue
            
            // 判斷是否有變化：
            // 1. 新增：wasPresent == false && newValue != nil
            // 2. 修改：wasPresent == true && newValue != nil && oldValue != newValue
            // 3. 刪除：wasPresent == true && newValue == nil
            if wasPresent != (newValue != nil) || oldValue != newValue {
                _isDirty = true
                _dirtyKeys.insert(key)  // ⭐ 記錄這個 key 有變化
                onChange?()  // 自動通知變更
            }
        }
    }
    
    // 攔截所有 Dictionary 操作
    mutating func removeValue(forKey key: Key) -> Value? {
        let value = _storage.removeValue(forKey: key)
        if value != nil {
            // ⭐ 刪除操作：標記這個 key 為 dirty
            _isDirty = true
            _dirtyKeys.insert(key)  // 記錄被刪除的 key
            onChange?()
        }
        return value
    }
    
    mutating func updateValue(_ value: Value, forKey key: Key) -> Value? {
        let oldValue = _storage.updateValue(value, forKey: key)
        // ⭐ 更新操作：標記這個 key 為 dirty（不論是新增還是修改）
        _isDirty = true
        _dirtyKeys.insert(key)  // 記錄被更新的 key
        onChange?()
        return oldValue
    }
    
    // 提供標準 Dictionary 介面
    var keys: Dictionary<Key, Value>.Keys { _storage.keys }
    var values: Dictionary<Key, Value>.Values { _storage.values }
    var count: Int { _storage.count }
    var isEmpty: Bool { _storage.isEmpty }
    
    // Dirty tracking
    var isDirty: Bool { _isDirty }
    
    /// 取得所有有變化的 keys（不論是新增、修改還是刪除）
    /// ⭐ 這是追蹤變更的核心：SyncEngine 可以只處理這些 keys
    var dirtyKeys: Set<Key> { _dirtyKeys }
    
    mutating func clearDirty() {
        _isDirty = false
        _dirtyKeys.removeAll()  // 清除追蹤記錄
    }
    
    // 轉換為標準 Dictionary（用於序列化等）
    func toDictionary() -> [Key: Value] {
        _storage
    }
}
```

**追蹤機制說明**：

1. **`_storage`**：實際儲存資料的 Dictionary
2. **`_dirtyKeys`**：追蹤變更的核心，記錄所有有變化的 keys（不論是新增、修改還是刪除）
3. **操作流程**：
   ```swift
   // 新增
   state.players[alice] = "Alice"
   // → _dirtyKeys.insert(alice)  // 記錄 alice 有變化
   
   // 修改
   state.players[alice] = "Alice Updated"
   // → _dirtyKeys.insert(alice)  // 記錄 alice 有變化
   
   // 刪除
   state.players.removeValue(forKey: alice)
   // → _dirtyKeys.insert(alice)  // 記錄 alice 有變化（被刪除）
   ```

4. **SyncEngine 使用**：
   ```swift
   // SyncEngine 可以只處理 dirty keys
   let dirtyKeys = state.players.dirtyKeys  // [alice, bob]
   for key in dirtyKeys {
       let path = "/players/\(key)"  // JSON Pointer 格式
       let oldValue = lastSnapshot.players[key]
       let newValue = currentSnapshot.players[key]
       
       // ⭐ 根據 oldValue 和 newValue 判斷操作類型
       if let oldValue = oldValue, let newValue = newValue {
           // 更新：oldValue 存在且 newValue 也存在
           if oldValue != newValue {
               patches.append(StatePatch(
                   path: path,
                   operation: .set(newValue)  // 更新操作
               ))
           }
       } else if oldValue != nil && newValue == nil {
           // 刪除：oldValue 存在但 newValue 不存在
           patches.append(StatePatch(
               path: path,
               operation: .delete  // 刪除操作
           ))
       } else if oldValue == nil && newValue != nil {
           // 新增：oldValue 不存在但 newValue 存在
           patches.append(StatePatch(
               path: path,
               operation: .set(newValue)  // 新增操作（也是用 .set）
           ))
       }
   }
   ```
   
   **Patch 操作類型**：
   - `.set(value)`：新增或更新（當 oldValue == nil 時是新增，否則是更新）
   - `.delete`：刪除（當 oldValue != nil 且 newValue == nil 時）
   
   這樣 SyncEngine 可以明確知道每個 key 是新增、更新還是刪除！

#### 4.2 與 @Sync 整合

```swift
// Protocol 來統一處理
protocol ReactiveTrackable {
    var isDirty: Bool { get }
    mutating func clearDirty()
}

extension ReactiveDictionary: ReactiveTrackable {}

@propertyWrapper
struct Sync<Value: Sendable>: Sendable {
    public let policy: SyncPolicy<Value>
    private var _value: Value
    private var _isDirty: Bool = false
    private var onChange: ((Value) -> Void)?
    
    var wrappedValue: Value {
        get { _value }
        set {
            _value = newValue
            _isDirty = true
            onChange?(newValue)
        }
    }
    
    var projectedValue: Sync<Value> { self }
    
    // 特殊處理：當 Value 是 ReactiveTrackable 時
    var isDirty: Bool {
        if let reactive = _value as? any ReactiveTrackable {
            return reactive.isDirty
        }
        return _isDirty
    }
    
    mutating func clearDirty() {
        if var reactive = _value as? any ReactiveTrackable {
            reactive.clearDirty()
            // 注意：需要將修改後的 reactive 重新賦值
            // 這需要更複雜的實作
        } else {
            _isDirty = false
        }
    }
}
```

#### 4.4 使用範例

```swift
@StateTreeBuilder
struct GameStateTree: StateTreeProtocol {
    // 使用 ReactiveDictionary，自動追蹤所有變更
    @Sync(.broadcast)
    var players: ReactiveDictionary<PlayerID, String> = ReactiveDictionary()
    
    // 基本類型仍然使用標準方式
    @Sync(.broadcast)
    var round: Int = 0
}

// 使用時，所有操作都會自動追蹤
var state = GameStateTree()

// ✅ 這些操作都會自動標記為 dirty
state.players[alice] = "Alice"  // 自動追蹤
state.players[bob] = "Bob"      // 自動追蹤
state.players.removeValue(forKey: charlie)  // 自動追蹤

```

### 與 Vue 3 Proxy 的對比

| 特性 | Vue 3 Proxy | Swift ReactiveDictionary |
|------|-------------|-------------------------|
| **攔截讀取** | ✅ `get` trap | ✅ `subscript get` |
| **攔截寫入** | ✅ `set` trap | ✅ `subscript set` |
| **攔截刪除** | ✅ `deleteProperty` | ✅ `removeValue` |
| **攔截方法** | ✅ 所有方法 | ✅ 需要手動實作 |
| **自動追蹤** | ✅ 完全自動 | ✅ 完全自動 |
| **效能** | 中等（Proxy 開銷） | 較好（編譯時優化） |
| **型別安全** | ❌ 運行時 | ✅ 編譯時 |
| **序列化** | ✅ 直接序列化 | ⚠️ 需要轉換 |

### 優點
- **完全自動**：類似 Vue 3，無需手動標記
- **細粒度追蹤**：可以追蹤具體變更的 key
- **型別安全**：編譯時檢查，避免運行時錯誤
- **效能較好**：比運行時 Proxy 更高效

### 挑戰
- **需要包裝**：不能直接使用標準 Dictionary，需要改用 Reactive 版本
- **實作複雜**：需要實作所有常用方法（removeValue, updateValue 等）
- **序列化處理**：需要轉換為標準類型才能序列化
- **向後相容**：現有程式碼需要修改才能使用

### 實作建議

1. **可選使用**：作為優化選項提供，不強制使用
   ```swift
   // 標準方式（向後相容）
   @Sync(.broadcast)
   var players: [PlayerID: String] = [:]
   
   // 優化方式（可選）
   @Sync(.broadcast)
   var players: ReactiveDictionary<PlayerID, String> = ReactiveDictionary()
   ```

2. **提供轉換方法**：方便在標準和 Reactive 之間轉換
   ```swift
   extension ReactiveDictionary {
       init(_ dictionary: [Key: Value]) {
           self.init(dictionary)
       }
   }
   
   extension Dictionary {
       init(_ reactive: ReactiveDictionary<Key, Value>) {
           self = reactive.toDictionary()
       }
   }
   ```

3. **序列化支援**：實作 Codable 來支援序列化
   ```swift
   extension ReactiveDictionary: Codable where Key: Codable, Value: Codable {
       // 序列化時轉換為標準 Dictionary
   }
   ```

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

對於 Dictionary、Set 等容器，在變更時自動標記：

```swift
// Dictionary 自動標記
subscript(key: Key) -> Value? {
    get { dictionary[key] }
    set {
        dictionary[key] = newValue
        markDirty(key: key)  // 自動標記這個 key 為 dirty
    }
}

// Set 自動標記
mutating func insert(_ member: Element) {
    set.insert(member)
    markDirty(element: member)  // 自動標記新增的元素
}

mutating func remove(_ member: Element) {
    set.remove(member)
    markDirty(element: member)  // 自動標記刪除的元素
}
```

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

## 7. Per-Player State View 架構（高級場景）

### 目標
為每個玩家創建獨立的狀態視圖（Per-Player State View），實現完全隔離的狀態計算和追蹤。

### 設計方向

#### 7.1 核心概念

將 per-player 的狀態分離成獨立的子樹，每個玩家有自己的狀態分支：

```swift
// 主狀態樹（包含 broadcast 和所有玩家的狀態）
struct GameStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var round: Int = 0
    
    // Per-player 狀態（在 Dictionary 中）
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: HandState] = [:]
    
    @Sync(.perPlayerDictionaryValue())
    var battles: [PlayerID: PlayerBattleState] = [:]
}

// ⭐ Per-Player State View：每個玩家的專屬狀態視圖
@StateTreeBuilder
struct PlayerStateView: StateTreeProtocol {
    // 只包含這個玩家的狀態
    @Sync(.broadcast)  // 在這個視圖中，所有欄位都是 broadcast（因為只屬於這個玩家）
    var hands: HandState = HandState()
    
    @Sync(.broadcast)
    var battle: PlayerBattleState = PlayerBattleState()
}
```

#### 7.2 架構設計

```swift
// SyncEngine 維護多個 Per-Player State View
struct SyncEngine: Sendable {
    // Broadcast 快照（共用）
    private var lastBroadcastSnapshot: StateSnapshot?
    
    // ⭐ 每個玩家的狀態視圖快照（獨立計算）
    private var lastPlayerStateViews: [PlayerID: StateSnapshot] = [:]
    
    // 從主狀態樹提取玩家的狀態視圖
    func extractPlayerStateView<State: StateTreeProtocol>(
        for playerID: PlayerID,
        from mainState: State
    ) throws -> StateSnapshot {
        // 從主狀態樹中提取這個玩家的所有 per-player 欄位
        let syncFields = mainState.getSyncFields()
        let perPlayerFields = syncFields.filter { 
            $0.policyType != "broadcast" && $0.policyType != "serverOnly" 
        }
        
        var playerValues: [String: SnapshotValue] = [:]
        for field in perPlayerFields {
            let fullSnapshot = try mainState.snapshot(for: playerID)
            if let value = fullSnapshot.values[field.name] {
                playerValues[field.name] = value
            }
        }
        
        return StateSnapshot(values: playerValues)
    }
    
    // 為每個玩家獨立計算 diff
    mutating func generateDiffForPlayer<State: StateTreeProtocol>(
        for playerID: PlayerID,
        from mainState: State
    ) throws -> StateUpdate {
        // 1. 提取這個玩家的狀態視圖
        let currentView = try extractPlayerStateView(for: playerID, from: mainState)
        
        // 2. 取得上次的快照
        guard let lastView = lastPlayerStateViews[playerID] else {
            lastPlayerStateViews[playerID] = currentView
            return .firstSync([])
        }
        
        // 3. 只比較這個玩家的狀態（不需要比較其他玩家）
        let patches = compareSnapshots(from: lastView, to: currentView)
        
        // 4. 更新快照
        lastPlayerStateViews[playerID] = currentView
        
        // 5. 合併 broadcast diff
        let broadcastPatches = try computeBroadcastDiff(from: mainState)
        return .diff(mergePatches(broadcastPatches, patches))
    }
}
```

### 優點
- **完全隔離**：每個玩家的狀態獨立計算，互不影響
- **並行計算**：可以同時計算多個玩家的 diff
- **簡化 dirty tracking**：每個視圖自己管理 dirty 狀態
- **細粒度追蹤**：可以追蹤到每個玩家的具體變更

### 挑戰
- **記憶體開銷**：需要維護多個狀態視圖實例
- **同步複雜度**：需要從主樹提取並保持同步
- **實作複雜度**：需要提取邏輯和維護機制

### 適用場景

**適合使用 Per-Player State View**：
- ✅ 大量玩家（50+）
- ✅ 需要並行計算
- ✅ per-player 狀態複雜且獨立
- ✅ 需要完全隔離計算

**不適合使用 Per-Player State View**：
- ❌ 少量玩家（<10）
- ❌ 記憶體受限
- ❌ per-player 狀態簡單
- ❌ 不需要並行計算

---

## 實作優先順序與方案組合

### 一般場景：Dirty Tracking + 改進的 Diff（推薦）

適合大多數遊戲場景（5-50 玩家），實作簡單且效果明顯。

#### Phase 1: 基礎優化（高優先級）
1. ⏳ **isDirty 機制**：實作基本的 dirty tracking
   - 在 `@Sync` property wrapper 中自動標記變更
   - 提供 `isDirty()` 和 `getDirtyFields()` API
   
2. ⏳ **自動標記**：Property wrapper 層級的自動追蹤
   - 基本類型（Int, String 等）自動標記
   - 容器類型需要手動標記或使用 helper methods

3. ⏳ **增量快取更新**：只更新變更的部分
   - 快取合併時只更新 dirty 欄位

#### Phase 2: 容器優化（中優先級）
4. ⏳ **Dictionary 優化**：追蹤變更的 keys
   - 只比較和序列化變更的 key-value pairs
   - 使用 path-based diff：`/hands/alice` 而不是 `/hands`

5. ⏳ **Set 優化**：追蹤新增和刪除的元素
   - 使用 set difference 來計算變更

#### 組合效果
```swift
// 使用 Dirty Tracking + 改進的 Diff
@StateTreeBuilder
struct GameStateTree: StateTreeProtocol, DirtyTrackable {
    @Sync(.broadcast)
    var round: Int = 0  // 自動追蹤
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: HandState] = [:]  // 需要手動標記或使用 helper
    
    // 使用時
    mutating func updateHand(for playerID: PlayerID, cards: [Card]) {
        hands[playerID] = HandState(cards: cards)
        markDirty("hands", for: playerID)  // 手動標記
    }
}

// SyncEngine 只處理 dirty 欄位
if state.isDirty() {
    let update = try syncEngine.generateDiffWithDirty(for: playerID, from: state)
    state.clearDirtyPaths()
}
```

**優點**：
- ✅ 實作簡單，容易整合
- ✅ 記憶體開銷低
- ✅ 適合大多數場景
- ✅ 向後相容

---

### 高級場景：Per-Player State View + Dirty Tracking（可選）

適合大型遊戲場景（50+ 玩家），需要並行計算和完全隔離。

#### Phase 3: Per-Player State View（可選，高級功能）
7. ⏳ **Per-Player State View 架構**：為每個玩家創建獨立的狀態視圖
   - 從主狀態樹提取 per-player 欄位
   - 為每個玩家維護獨立的狀態視圖快照
   - 支援並行計算多個玩家的 diff

8. ⏳ **與 Dirty Tracking 整合**：每個視圖自己管理 dirty 狀態
   - 每個 PlayerStateView 可以實作 DirtyTrackable
   - 只檢查該玩家的狀態是否 dirty

#### Phase 4: Proxy 風格響應式（可選，高級功能）
9. ⏳ **ReactiveDictionary**：實作類似 Vue 3 Proxy 的 Dictionary 追蹤
10. ⏳ **與 @Sync 整合**：支援 Reactive 容器類型的自動 dirty tracking

#### 組合效果
```swift
// 使用 Per-Player State View + Dirty Tracking
struct SyncEngine: Sendable {
    private var lastPlayerStateViews: [PlayerID: PlayerStateView] = [:]
    
    mutating func generateDiffForPlayer<State: StateTreeProtocol>(
        for playerID: PlayerID,
        from mainState: State
    ) throws -> StateUpdate {
        // 1. 提取玩家的狀態視圖
        let currentView = try extractPlayerStateView(for: playerID, from: mainState)
        
        // 2. 如果視圖支援 Dirty Tracking，只處理 dirty 欄位
        if let dirtyView = currentView as? DirtyTrackable, dirtyView.isDirty() {
            // 只比較 dirty 欄位
            return try generateDiffWithDirty(for: playerID, from: dirtyView)
        } else {
            // 標準比較
            return try generateDiffStandard(for: playerID, from: currentView)
        }
    }
}
```

**優點**：
- ✅ 完全隔離計算
- ✅ 支援並行計算
- ✅ 細粒度追蹤
- ✅ 適合大型場景

**缺點**：
- ⚠️ 記憶體開銷較高
- ⚠️ 實作複雜度較高
- ⚠️ 需要維護多個分支

---

### Phase 5: 進階優化（低優先級）
12. ⏳ **序列化優化**：自訂編碼器和二進位格式
13. ⏳ **快取壓縮和過期**：記憶體優化
14. ⏳ **細粒度 per-player 追蹤**：更精確的變更追蹤

---

## 方案選擇建議

### 決策流程

```
開始
  ↓
玩家數量 < 10？
  ├─ 是 → 使用：Dirty Tracking + 改進的 Diff（一般場景）
  └─ 否 → 玩家數量 < 50？
           ├─ 是 → 使用：Dirty Tracking + 改進的 Diff（一般場景）
           └─ 否 → 需要並行計算？
                    ├─ 是 → 使用：Per-Player State View + Dirty Tracking（高級場景）
                    └─ 否 → 使用：Dirty Tracking + 改進的 Diff（一般場景）
```

### 方案對比表

| 面向 | 一般場景<br/>(Dirty Tracking + Diff) | 高級場景<br/>(Per-Player State View + Dirty Tracking) |
|------|-------------------------------------|------------------------------------------------|
| **實作複雜度** | ✅ 簡單 | ⚠️ 中等 |
| **記憶體開銷** | ✅ 低 | ⚠️ 較高 |
| **計算隔離** | ⚠️ 需要從主樹提取 | ✅ 完全獨立 |
| **並行計算** | ❌ 困難 | ✅ 容易 |
| **適用玩家數** | 5-50 | 50+ |
| **Dirty Tracking** | ✅ 支援 | ✅ 每個分支支援 |
| **維護成本** | ✅ 低 | ⚠️ 需要同步主樹和分支 |

### 建議

1. **優先實作一般場景方案**（Dirty Tracking + 改進的 Diff）
   - 適合大多數場景
   - 實作簡單，效果明顯
   - 向後相容

2. **高級場景方案作為可選優化**（Per-Player State View + Dirty Tracking）
   - 只在需要時使用
   - 適合大型遊戲或需要並行計算的場景
   - 可以與一般場景方案共存

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


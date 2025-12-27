# Macros

SwiftStateTree 提供三個主要 macro，用於產生 metadata 與提升效能。

## 設計說明

Macros 在編譯期執行，提供以下優勢：

- **降低 runtime 成本**：編譯期產生 metadata，避免 runtime reflection
- **提前驗證**：編譯期檢查錯誤，避免 runtime 出錯
- **型別安全**：編譯期型別檢查，確保正確性
- **自動生成**：減少手寫程式碼，降低錯誤率

## @StateNodeBuilder

`@StateNodeBuilder` 用於標記 **StateTree 的節點**（StateNode），自動生成必要的 metadata 和驗證邏輯。

### 功能

- **驗證規則**：確保所有 stored property 都標記為 `@Sync` 或 `@Internal`
- **生成 sync metadata**：產生 `getSyncFields()` 方法
- **生成 dirty tracking**：產生 `isDirty()`、`getDirtyFields()`、`clearDirty()` 方法
- **生成 snapshot 方法**：產生 `snapshot(for:)` 和 `broadcastSnapshot()` 方法

### 使用場景

`@StateNodeBuilder` 用於定義**狀態樹的節點**，這些節點需要：
- 定義同步規則（哪些欄位同步給哪些玩家）
- 作為 StateTree 的根節點或子節點
- 需要 dirty tracking 和 snapshot 功能

**範例**：`GameState` 是根狀態，需要定義同步規則

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)  // 需要定義同步規則
    var players: [PlayerID: PlayerState] = [:]
}
```

### 使用範例

```swift
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    // 必須標記 @Sync 或 @Internal
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    @Internal
    var lastProcessedTimestamp: Date = Date()
    
    // Computed properties 不需要標記
    var totalPlayers: Int {
        players.count
    }
}
```

### 驗證規則

- ✅ **Stored properties**：必須標記 `@Sync` 或 `@Internal`
- ✅ **Computed properties**：自動跳過驗證
- ❌ **未標記的 stored property**：編譯錯誤

### 常見錯誤

#### 錯誤 1：忘記標記 stored property

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    var score: Int = 0  // ❌ 編譯錯誤：必須標記 @Sync 或 @Internal
}
```

**解決方案**：

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.broadcast)  // ✅ 正確
    var score: Int = 0
}
```

#### 錯誤 2：在 class 上使用

```swift
@StateNodeBuilder  // ❌ 編譯錯誤：只支援 struct
class GameState: StateNodeProtocol {
    // ...
}
```

**解決方案**：使用 `struct` 而非 `class`。

### 最佳實踐

1. **明確標記所有 stored properties**：不要遺漏任何欄位
2. **合理使用 `@Internal`**：內部計算用的欄位使用 `@Internal`
3. **使用 `@Sync(.serverOnly)` 而非 `@Internal`**：如果需要同步引擎知道但不同步給 client

## @Payload

`@Payload` 用於標記 Action、Event 和 Response payload，自動生成 metadata。

### 功能

- **生成 field metadata**：產生 `getFieldMetadata()` 方法
- **生成 response type**：Action payload 會額外產生 `getResponseType()` 方法
- **Schema 生成**：用於自動生成 JSON Schema

### 使用範例

#### Action Payload

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
    let deviceID: String?
}

@Payload
struct JoinResponse: ResponsePayload {
    let success: Bool
    let message: String
    let landID: String?
}
```

#### Event Payload

```swift
@Payload
struct PlayerJoinedEvent: ServerEventPayload {
    let playerID: PlayerID
    let name: String
    let timestamp: Date
}

@Payload
struct ChatMessageEvent: ClientEventPayload {
    let playerID: PlayerID
    let message: String
    let timestamp: Date
}
```

### 生成的程式碼

Macro 會自動生成以下方法：

```swift
// 自動生成（簡化版）
extension JoinAction {
    static func getFieldMetadata() -> [FieldMetadata] {
        return [
            FieldMetadata(name: "playerID", type: "PlayerID"),
            FieldMetadata(name: "name", type: "String"),
            FieldMetadata(name: "deviceID", type: "String?")
        ]
    }
    
    static func getResponseType() -> Any.Type {
        return JoinResponse.self
    }
}
```

### 常見錯誤

#### 錯誤 1：忘記標記 @Payload

```swift
// ❌ 錯誤：未標記 @Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
}

// 在 runtime 會 trap
let responseType = JoinAction.getResponseType()  // ❌ Runtime error
```

**解決方案**：

```swift
@Payload  // ✅ 正確
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
}
```

#### 錯誤 2：Action 未定義 Response

```swift
@Payload
struct JoinAction: ActionPayload {
    // ❌ 錯誤：ActionPayload 必須定義 Response
    let playerID: PlayerID
}
```

**解決方案**：

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse  // ✅ 正確
    let playerID: PlayerID
}
```

### 最佳實踐

1. **所有 Payload 都標記 `@Payload`**：確保 metadata 正確生成
2. **使用明確的型別**：避免使用 `Any` 或過於泛型的型別
3. **保持 Payload 簡單**：避免過於複雜的巢狀結構

## @SnapshotConvertible

`@SnapshotConvertible` 用於標記**巢狀的資料結構**，自動生成 `SnapshotValueConvertible` 實作，優化轉換效能。

### 功能

- **自動生成轉換方法**：產生 `toSnapshotValue()` 方法
- **避免 runtime reflection**：不使用 Mirror，大幅提升效能
- **支援巢狀結構**：自動處理巢狀的 `@SnapshotConvertible` 型別

### 使用場景

`@SnapshotConvertible` 用於**巢狀在 StateNode 中的值型別**，這些型別：
- **作為屬性容器**：封裝相關的狀態屬性，組織成有意義的資料結構
- **不需要同步規則**：同步規則由父層 StateNode 的 `@Sync` 決定
- **只需要高效能轉換**：優化序列化效能
- **是值型別**：巢狀在字典、陣列等容器中

**範例**：`PlayerState` 是巢狀在 `GameState.players` 字典中的值，作為玩家屬性的容器

```swift
// PlayerState 作為玩家屬性的容器
@SnapshotConvertible  // 不需要 StateNodeProtocol
struct PlayerState: Codable, Sendable {
    var name: String        // 玩家名稱
    var hpCurrent: Int      // 當前血量
    var hpMax: Int          // 最大血量
    var position: Position  // 位置（也是屬性容器）
}

// Position 作為位置屬性的容器
@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double  // X 座標
    var y: Double  // Y 座標
}
```

**關鍵區別**：
- `@StateNodeBuilder`：用於**狀態樹節點**，需要定義同步規則
- `@SnapshotConvertible`：用於**屬性容器/資料結構**，封裝相關屬性，只需要轉換效能優化

**設計理念**：
- `@SnapshotConvertible` 將相關屬性組織成有意義的容器（如 `PlayerState`、`Position`、`Item`）
- 這些容器作為值型別，可以巢狀在 StateNode 的字典、陣列等集合中
- 同步規則由父層 StateNode 的 `@Sync` 統一管理，容器本身不需要定義同步規則

### 使用範例

#### 基本使用

```swift
@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
    var position: Position
}

@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double
    var y: Double
}
```

#### 在 StateNode 中使用

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // PlayerState 作為屬性容器，使用 @SnapshotConvertible
    
    @Sync(.broadcast)
    var items: [ItemID: Item] = [:]  // Item 也是屬性容器
}

// PlayerState 作為玩家屬性的容器
@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
    var position: Position
}

// Item 作為物品屬性的容器
@SnapshotConvertible
struct Item: Codable, Sendable {
    var id: String
    var name: String
    var count: Int
}
```

**重要區別**：

- **`@StateNodeBuilder + StateNodeProtocol`**：用於**狀態樹的節點**（如 `GameState`），需要定義同步規則（`@Sync`）
- **`@SnapshotConvertible`**：用於**屬性容器/資料結構**（如 `PlayerState`、`Item`），封裝相關屬性，只需要高效能轉換

**為什麼 `PlayerState` 不需要 `StateNodeProtocol`？**

1. **它是屬性容器**：`PlayerState` 封裝了玩家的相關屬性（name, hp, position），作為一個值型別容器
2. **同步規則由父層決定**：`GameState.players` 的 `@Sync(.broadcast)` 決定了整個字典的同步規則
3. **只需要轉換效能**：作為值型別，只需要高效能序列化，不需要獨立的同步規則

### 生成的程式碼

Macro 會自動生成：

```swift
// 自動生成（簡化版）
extension PlayerState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": .string(name),
            "hpCurrent": .int(hpCurrent),
            "hpMax": .int(hpMax),
            "position": try position.toSnapshotValue()  // 遞迴處理巢狀結構
        ])
    }
}
```

### 效能優勢

使用 `@SnapshotConvertible` 可以大幅提升轉換效能：

- **避免 Mirror**：不使用 runtime reflection
- **編譯期優化**：編譯器可以進行更多優化
- **型別安全**：編譯期檢查，避免 runtime 錯誤

### 適用場景

建議在以下場景使用 `@SnapshotConvertible`：

- ✅ **頻繁轉換的型別**：在 StateTree 中頻繁使用的巢狀結構
- ✅ **複雜的巢狀結構**：多層級的巢狀結構
- ✅ **效能關鍵路徑**：需要高效能轉換的型別

### 常見錯誤

#### 錯誤 1：忘記標記巢狀結構

```swift
@SnapshotConvertible
struct PlayerState: Codable {
    var name: String
    var position: Position  // ❌ Position 未標記 @SnapshotConvertible
}

struct Position: Codable {  // 會使用 Mirror，效能較差
    var x: Double
    var y: Double
}
```

**解決方案**：

```swift
@SnapshotConvertible
struct PlayerState: Codable {
    var name: String
    var position: Position
}

@SnapshotConvertible  // ✅ 正確
struct Position: Codable {
    var x: Double
    var y: Double
}
```

#### 錯誤 2：在 protocol 上使用

```swift
@SnapshotConvertible  // ❌ 編譯錯誤：只支援 struct
protocol GameEntity {
    var id: String { get }
}
```

**解決方案**：使用具體的 struct 型別。

### 最佳實踐

1. **標記所有巢狀結構**：確保整個轉換路徑都使用 macro
2. **優先使用基本型別**：String、Int、Bool 等基本型別已經優化
3. **避免過度使用**：簡單的型別可能不需要此 macro

## 效能影響

### @StateNodeBuilder

- **編譯期成本**：增加編譯時間（通常可忽略）
- **Runtime 成本**：降低 runtime 成本（避免 reflection）

### @Payload

- **編譯期成本**：增加編譯時間（通常可忽略）
- **Runtime 成本**：降低 runtime 成本（避免 reflection）

### @SnapshotConvertible

- **編譯期成本**：增加編譯時間（通常可忽略）
- **Runtime 成本**：大幅降低 runtime 成本（避免 Mirror）

**效能測試結果**（參考）：

- 使用 `@SnapshotConvertible`：轉換時間約為使用 Mirror 的 1/10
- 對於複雜的巢狀結構，效能提升更明顯

## 相關文檔

- [StateNode 定義](../core/README.md) - 了解 StateNode 的使用
- [同步規則](../core/sync.md) - 了解 `@Sync` 的使用
- [Schema 生成](../schema/README.md) - 了解 Schema 生成機制

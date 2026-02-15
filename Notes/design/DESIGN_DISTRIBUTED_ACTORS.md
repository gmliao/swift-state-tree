# Distributed Actor 擴展性設計

> **已放棄**：本專案已不再規劃使用 Swift distributed actor。本文檔僅供歷史參考。
>
> 原說明 SwiftStateTree 為未來 distributed actor 支援所做的設計考量與擴展性準備。

## 設計目標

1. **當前模式（單進程）**: 所有 actors 都在單一進程內運行
2. **未來模式（多伺服器）**: 支援 actors 跨進程/跨機器分佈
3. **平滑遷移**: 從單進程模式遷移到多伺服器模式時，代碼變更最小

## 核心設計原則

### 1. 協議抽象

使用協議而非具體類型，讓未來可以替換實作：

- **LandKeeperProtocol**: 抽象 `LandKeeper` 的操作
- **LandManagerProtocol**: 抽象 `LandManager` 的操作
- **DistributedActorSystemProtocol**: 抽象 distributed actor system

### 2. Sendable 和 Codable 要求

所有通訊介面的參數和返回值都必須符合：
- `Sendable`: 可以安全地在並發環境中傳遞
- `Codable`: 可以序列化以跨進程傳輸

### 3. ID 系統

使用結構化的 ID 類型而非簡單字串：
- `LandID`: 結構化的 Land 識別符
- 支援 `Codable`、`Hashable`、`Sendable`
- 與 `String` 互轉以保持向後兼容

## 當前架構（單進程模式）

```
┌─────────────────────────────────┐
│  Single Process                 │
│                                  │
│  ┌──────────────┐               │
│  │ LandKeeper   │ (local actor) │
│  └──────────────┘               │
│                                  │
│  ┌──────────────┐               │
│  │ LandManager  │ (local actor) │
│  └──────────────┘               │
│                                  │
│  ┌──────────────┐               │
│  │Matchmaking   │ (local actor) │
│  │Service       │               │
│  └──────────────┘               │
└─────────────────────────────────┘
```

**特點**:
- 所有 actors 在同一進程內
- 直接引用，無需序列化
- 高效能，低延遲

## 未來架構（多伺服器模式）

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  Server 1        │    │  Server 2        │    │  Server 3        │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │  ┌────────────┐  │    │  ┌────────────┐  │
│  │LandKeeper  │  │    │  │LandKeeper  │  │    │  │LandKeeper  │  │
│  │(distributed)│◄─┼──┼─►│(distributed)│  │    │  │(distributed)│  │
│  └────────────┘  │    │  └────────────┘  │    │  └────────────┘  │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │                  │    │                  │
│  │LandManager │  │    │                  │    │                  │
│  │(distributed)│◄─┼──┼──────────────────┼───►│                  │
│  └────────────┘  │    │                  │    │                  │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │                  │    │                  │
│  │Matchmaking │  │    │                  │    │                  │
│  │Service     │  │    │                  │    │                  │
│  │(distributed)│◄─┼──┼──────────────────┼───►│                  │
│  └────────────┘  │    │                  │    │                  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  ActorSystem            │
                    │  (Location & Routing)   │
                    └─────────────────────────┘
```

**特點**:
- Actors 分佈在多個伺服器上
- 透過 ActorSystem 定位和路由
- 需要序列化以跨進程通訊

## 遷移路徑

### 步驟 1: 實作 Distributed Actor 版本

```swift
// 當前（local actor）
public actor LandKeeper<State: StateNodeProtocol>: LandKeeperProtocol {
    // ...
}

// 未來（distributed actor）
public distributed actor DistributedLandKeeper<State: StateNodeProtocol>: LandKeeperProtocol {
    public typealias ActorSystem = ClusterActorSystem
    
    // 實作相同的協議方法
    // 所有參數和返回值自動序列化
}
```

### 步驟 2: 更新 MatchmakingService

```swift
// 當前（已實作 MatchmakingServiceProtocol）
public actor MatchmakingService<State: StateNodeProtocol, Registry: LandManagerRegistry>: MatchmakingServiceProtocol 
where Registry.State == State {
    private let registry: Registry  // 使用 LandManagerRegistry protocol
    // ...
}

// 未來（distributed actor 版本）
public distributed actor DistributedMatchmakingService<State: StateNodeProtocol>: MatchmakingServiceProtocol {
    public typealias ActorSystem = ClusterActorSystem
    
    // 實作 MatchmakingServiceProtocol 的所有方法
    // 所有參數和返回值自動序列化
}
```

### 步驟 3: 配置 ActorSystem

```swift
// 在 AppContainer 中配置
let actorSystem = ClusterActorSystem("SwiftStateTree") { settings in
    settings.bindHost = "0.0.0.0"
    settings.bindPort = 7337
}

// 使用 distributed actor
let landManager = DistributedLandManager(
    actorSystem: actorSystem,
    // ...
)
```

## 關鍵設計點

### 1. MatchmakingService 與 LandManager 的溝通

**當前設計**:
- `MatchmakingService` 使用 `LandManagerRegistry` protocol（而非具體的 `LandManager<State>` 類型）
- `MatchmakingService` 實作 `MatchmakingServiceProtocol` protocol
- 所有方法參數都是 `Sendable` 和 `Codable`

**未來遷移**:
- 將 `LandManager` 改為 distributed actor（實作 `LandManagerProtocol`）
- 將 `MatchmakingService` 改為 distributed actor（實作 `MatchmakingServiceProtocol`）
- 代碼邏輯無需修改（因為 protocol 介面保持一致）
- Swift Distributed Actors 自動處理序列化

### 2. ID 系統

**LandID 設計**:
```swift
public struct LandID: Hashable, Codable, Sendable {
    public let rawValue: String
    // ...
}
```

**未來擴展**:
- 可以擴展為包含節點資訊（server ID、process ID）
- 支援 distributed actor 的定位需求

### 3. 序列化要求

所有通訊介面必須符合：
- **Sendable**: 確保線程安全
- **Codable**: 支援序列化

**範例**:
```swift
// ✅ 正確：所有參數都是 Sendable 和 Codable
func getOrCreateLand(
    landID: LandID,           // Codable, Sendable
    definition: LandDefinition<State>,  // Sendable
    initialState: State      // Codable, Sendable
) async -> LandContainer<State>  // Sendable

// ❌ 錯誤：包含非 Sendable 類型
func badMethod(closure: () -> Void)  // Closure 不是 Sendable
```

## 實作狀態

### 已完成

- ✅ **LandKeeperProtocol**: 定義了統一的介面
- ✅ **LandManagerProtocol**: 定義了統一的介面
- ✅ **MatchmakingServiceProtocol**: 定義了統一的介面
- ✅ **LandID**: 結構化的 ID 類型
- ✅ **Sendable/Codable 要求**: 所有通訊介面都符合要求
- ✅ **DistributedActorSystemProtocol**: 預留的協議定義

### 待實作（未來）

- 📅 **Distributed Actor 實作**: 使用 Swift Distributed Actors
- 📅 **ActorSystem 配置**: Cluster 設定和路由
- 📅 **序列化優化**: 針對跨進程通訊的效能優化
- 📅 **故障處理**: 節點故障時的恢復機制

## 使用範例

### 當前（單進程）

```swift
// 建立 local actors
let landManager = LandManager<State>(...)
let registry = SingleLandManagerRegistry(landManager: landManager)
let landTypeRegistry = LandTypeRegistry<State>(...)
let matchmakingService = MatchmakingService(registry: registry, landTypeRegistry: landTypeRegistry)

// 直接調用（無需序列化）
let container = await landManager.getOrCreateLand(...)
let result = try await matchmakingService.matchmake(playerID: playerID, preferences: preferences)
```

### 未來（多伺服器）

```swift
// 建立 distributed actors
let actorSystem = ClusterActorSystem("SwiftStateTree")
let landManager = DistributedLandManager(actorSystem: actorSystem, ...)
let registry = DistributedLandManagerRegistry(...)  // 聚合多個 distributed LandManagers
let landTypeRegistry = LandTypeRegistry<State>(...)
let matchmakingService = DistributedMatchmakingService(actorSystem: actorSystem, ...)

// 調用方式相同（自動序列化）
let container = await registry.createLand(...)
let result = try await matchmakingService.matchmake(playerID: playerID, preferences: preferences)
// Swift Distributed Actors 自動處理跨進程通訊
```

## 總結

目前的設計已經為 distributed actor 做好了準備：

1. **協議抽象**: 使用協議而非具體類型
2. **序列化準備**: 所有參數和返回值都是 `Sendable` 和 `Codable`
3. **ID 系統**: 結構化的 ID 類型，易於擴展
4. **向後兼容**: 當前代碼在遷移後仍可正常運行

未來只需要：
1. 實作 distributed actor 版本（實作相同協議）
2. 配置 ActorSystem
3. 替換實例創建（從 local 改為 distributed）

代碼邏輯無需修改，因為協議介面保持一致。


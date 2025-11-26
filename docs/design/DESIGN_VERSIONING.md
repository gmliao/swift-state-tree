# Schema Versioning 設計

> 本文檔說明 SwiftStateTree 的 Schema 版本控制機制
> 
> 相關文檔：
> - [DESIGN_CORE.md](./DESIGN_CORE.md) - 核心概念與 StateTree 結構
> - [DESIGN_SYNC_FIRSTSYNC.md](./DESIGN_SYNC_FIRSTSYNC.md) - 首次同步機制

## 概述

SwiftStateTree 採用**欄位級版本資訊**作為主要版本管理方式，透過 `@Since` 標記實現 schema evolution，無需手動撰寫資料庫 migration 程式，即可自動處理舊資料相容性。

### 核心設計哲學

> **StateTree 的 Schema 是 DSL 來定義的，不是資料庫定義。**  
> DB 只是保存實體資料的 JSON。  
> 版本控制由 DSL（`@Since`）主導，而不由 DB schema 主導。

這是 SwiftStateTree 之所以比 Colyseus、Socket.IO、純 JSON 方案更強大的根本原因之一。

---

## 欄位版本：`@Since(n)`（核心機制）

### 基本語法

採用「欄位級版本資訊」作為主要版本管理方式：

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // 沒標 = since 1

    @Sync(.broadcast)
    @Since(2)
    var weather: WeatherState = .sunny  // v2 才新增
}
```

### `@Since(n)` 的規則

- **沒標 `@Since` ⇒ 視為 `@Since(1)`**
- `@Since(n)` 表示此欄位是在版本 n 才加入
- 版本差異由工具層推理，不需要額外在 StateTree 上手寫 `version: n`

---

## StateTree 整體版本計算

### 計算方式

**StateTree 整體版本 = max(所有欄位的 since)**

**範例**：

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // @Since(1)

    @Sync(.broadcast)
    @Since(2)
    var weather: WeatherState = .sunny  // @Since(2)
}
```

→ 整體 `GameStateRootNode` 的版本 = **2**

> 不必在 struct 上寫 `@StateNodeBuilder(version: 2)`，由工具（macro / schema builder）自動推得。

---

## 自動補齊缺欄位（Backward Compatibility）

這是方案最重要的能力，實現完整的 schema evolution。

### Persistence 讀取舊 snapshot 時

當從資料庫載入舊版本的 snapshot 時：

```json
{
  "players": { ... }
  // 沒有 weather（因為舊版 v1）
}
```

載入時程式會：

1. `players`（since 1）→ 正常 decode
2. `weather`（since 2）→ **JSON 裡沒有，使用 default 值補上**

🔥 **這就完成了「舊資料 → 新 schema」的自動補齊**  
🔥 **無需 DB Migration / 無需手動寫轉換程式**

等於你擁有完整的「schema evolution」能力。

### 實作邏輯

```swift
// Pseudo-code: Persistence layer 的處理邏輯
func loadSnapshot(from json: [String: Any], schemaVersion: Int) -> GameStateRootNode {
    var state = GameStateRootNode()
    
    // Decode existing fields
    if let playersData = json["players"] {
        state.players = try decode(playersData)
    }
    
    // Auto-fill missing fields with defaults
    if schemaVersion < 2 {
        // weather field doesn't exist in old snapshot
        // Use default value from property initializer
        state.weather = .sunny  // Default value
    } else {
        // New snapshot has weather field
        if let weatherData = json["weather"] {
            state.weather = try decode(weatherData)
        }
    }
    
    return state
}
```

---

## Realm 不需要有版本的概念

### 設計重點

Realm 的設計重點：

- 內部永遠操作「最新版本的 Swift struct」
- 不需要知道「這房間以前是 v1 還 v2」
- 版本處理是在 *Realm 邊界* 完成

### 在「載入 snapshot」邊界做

1. 從 DB 拿到舊 JSON + 舊版本（例如 v1）
2. Persistence / migration layer 自動補齊缺欄位
3. 回傳「**完整 v 最新版**」的 StateTree 給 Realm

Realm 內部完全不需要版本邏輯。

> **Realm only knows the latest schema.  
> Version compatibility is handled outside Realm.**

### 架構示意

```
┌─────────────────────────────────────┐
│  Realm (RealmActor)                 │
│  - 只操作最新版本的 StateTree       │
│  - 不知道版本概念                   │
└─────────────────────────────────────┘
              ↑
              │ 載入時已補齊所有欄位
              │
┌─────────────────────────────────────┐
│  Persistence Layer                  │
│  - 從 DB 讀取舊 JSON                │
│  - 自動補齊缺欄位（用 default）     │
│  - 回傳完整最新版 StateTree         │
└─────────────────────────────────────┘
              ↑
              │
┌─────────────────────────────────────┐
│  Database (PostgreSQL + JSONB)      │
│  - 只存 JSON blob                   │
│  - 不需要 ALTER TABLE               │
└─────────────────────────────────────┘
```

---

## Client 基本不用管版本

### 原因

因為：

- Server 永遠傳「最新版」的 StateTree 給 client
- Client SDK 是依照最新版本 codegen 的型別
- 缺欄位問題已在 server Persistence 處理掉（補 default）

### 特殊情況

**Client 只有一種情況需要版本資訊：**

- 舊 client 連到新版 server，需要 RPC 轉換
- 這由你將來做的 RPC adapter / feature flag 處理即可

一般遊戲或 app，用不到 client-side version negotiation。

---

## 與 Persistence 的關係（PostgreSQL + JSONB）

### 資料庫設計

- Snapshot 存成 JSONB
- DB schema 幾乎不改（不需要 ALTER TABLE）
- 缺欄位完全在程式端補起來
- DB 本身只保存 blob，不需跟 schema 雙向綁死

這跟 Firestore、DynamoDB、Supabase Table JSONB 的演進模式非常接近且可靠。

### 範例：PostgreSQL Schema

```sql
CREATE TABLE realm_snapshots (
    id UUID PRIMARY KEY,
    realm_id VARCHAR(255) NOT NULL,
    snapshot JSONB NOT NULL,
    version INTEGER NOT NULL,  -- 記錄 snapshot 的版本
    created_at TIMESTAMP DEFAULT NOW()
);

-- 不需要為每個新欄位 ALTER TABLE
-- 版本資訊只存在 JSONB 的 metadata 中
```

---

## 對工程師 & CI/CD 的好處

### 工程師

- ✅ 不需要寫資料庫 migration
- ✅ StateTree 加欄位 **不會爆**
- ✅ 老 snapshot 永遠能讀
- ✅ 新欄位用 default 自動補起來（不用寫 migration 程式）

### CI/CD

- ✅ 新版程式推出 → 舊資料照樣跑
- ✅ 不需要等待「資料庫升級」這種繁瑣步驟
- ✅ Deployment 更快速、風險更低

這個設計對團隊是非常友善的。

---

## 實作方向建議

### Macro 擴展

`@StateNodeBuilder` macro 需要擴展以支援 `@Since`：

```swift
@attached(peer)
public macro Since(_ version: Int) = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "SinceMacro"
)
```

### Schema Builder

Schema builder 需要：

1. 掃描所有欄位的 `@Since` 標記
2. 計算整體版本 = max(所有欄位的 since)
3. 生成版本資訊到 schema metadata

### Persistence Layer

Persistence layer 需要：

1. 讀取 snapshot 時檢查版本
2. 自動補齊缺欄位（使用 default 值）
3. 確保回傳給 Realm 的 StateTree 永遠是最新完整版本

---

## 完整範例

### 定義 StateTree（v1 → v2 演進）

```swift
// v1: 初始版本
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // @Since(1)
    
    @Sync(.broadcast)
    var round: Int = 0  // @Since(1)
}

// v2: 新增 weather 欄位
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // @Since(1)
    
    @Sync(.broadcast)
    var round: Int = 0  // @Since(1)
    
    @Sync(.broadcast)
    @Since(2)
    var weather: WeatherState = .sunny  // @Since(2) - 新欄位
}

// 整體版本 = max(1, 1, 2) = 2
```

### 載入舊 snapshot（v1 → v2）

```swift
// 舊 snapshot (v1)
let oldSnapshot: [String: Any] = [
    "players": [...],
    "round": 5
    // 沒有 weather
]

// Persistence layer 自動處理
let state = persistence.loadSnapshot(from: oldSnapshot, version: 1)
// state.players = [...] (正常 decode)
// state.round = 5 (正常 decode)
// state.weather = .sunny (自動補 default)

// Realm 收到的是完整 v2 版本的 StateTree
```

---

## 最終結論

> **是，目前的 `@Since` 設計已完整達成：**
> 
> - ✅ 欄位版本化
> - ✅ 自動補齊缺欄位
> - ✅ 舊資料相容
> - ✅ 無痛 schema evolution
> - ✅ Realm 無版本感
> 
> **工程師與 CI/CD 都能因此變得更輕鬆。**

這方案完全成熟，可以直接寫進 SwiftStateTree 1.0 設計裡。


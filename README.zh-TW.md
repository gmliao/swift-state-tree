# SwiftStateTree

一個基於 Swift 的多人遊戲伺服器框架，採用 **單一 StateTree + 同步規則 + Land DSL** 的設計理念。

## 🌳 什麼是 StateTree？

StateTree 是結合前端框架的狀態管理想法與後端資料過濾經驗的產物。透過狀態樹的方式表達伺服器狀態，可以直接將資料以 reactive 的方式同步給客戶端，讓客戶端能夠自動響應狀態變更。

> **Note**
> StateTree 本身是一個 programming model（語意模型），用來描述伺服器端狀態、行為與同步的組織方式。本專案是該模型的一個 Swift reference implementation。

詳細的架構概念說明請參考 [架構概念總覽](docs/programming-model.zh-TW.md)。

## 🎮 示範影片

觀看示範遊戲的實際運行：

[![示範遊戲](https://img.youtube.com/vi/SsYCn9oA0pc/0.jpg)](https://www.youtube.com/watch?v=SsYCn9oA0pc)

## 📝 關於專案

### 為什麼是 Swift？

因為 Swift（🐦 雨燕）會停留在樹上（stay on tree）... 所以是 **Swift** + **Stay** + **Tree** = **SwiftStateTree**！😄

**其他動物呢？**
- 🐍 **蟒蛇（Python）**：似乎不太停留在樹上
- 🦀 **螃蟹（Rust）**：也不爬樹
- 🐹 **地鼠（Go）**：不太喜歡樹上吧
- 🐘 **大象（PHP）**：你在開玩笑嗎？

**結論：只有 Swift 會停留在 StateTree 上。**

*（這是一個幽默的命名解釋，實際上我一開始命名的時候沒有想到這個雙關，後來才發現...XD 選擇 Swift 是因為其語言特性（DSL、Macro、Struct、Actor）非常適合實現 StateTree 的設計理念。）*

本專案為個人興趣嗜好專案，旨在探索和實驗多人遊戲伺服器架構設計。

### 專案動機

最初的想法是建立一個類似 [Colyseus](https://colyseus.io/) 的 schema 同步功能框架。在整理想法之後，決定透過 StateTree 的方式來表達網路同步模型，讓開發者可以透過不同的同步策略來控制不同使用者觀察到的視角。

在學習 Swift 的過程中，發現 Swift 的幾個特性非常適合實現這個想法：
- **DSL（Domain-Specific Language）**：可以建立清晰的領域特定語法
- **Macro**：編譯期代碼生成，提供型別安全和自動化
- **Struct（值型別）**：適合狀態的快照和不可變性
- **Actor**：提供並發安全和狀態隔離

雖然歡迎討論和建議，但主要目的在於技術探索和學習。

## 🎯 設計理念

SwiftStateTree 採用以下核心設計：

- 🌳 **單一權威狀態樹**：用一棵 `StateTree` 表示整個領域的狀態
- 🔄 **同步規則 DSL**：使用 `@Sync` 規則控制伺服器要把哪些資料同步給誰
- 🏛️ **Land DSL**：定義領域、Action/Event 處理、Tick 設定
- 💻 **UI 計算交給客戶端**：伺服器只送「邏輯資料」，UI 渲染由客戶端處理
- 🔧 **自動 Schema 生成**：從伺服器定義自動產生 JSON Schema，支援 TypeScript客戶端 SDK 生成，確保型別安全

## 📦 模組架構

| 模組 | 說明 |
|------|------|
| **SwiftStateTree** | 核心模組（StateTree、Land DSL、Sync、Runtime、SchemaGen） |
| **SwiftStateTreeTransport** | Transport 層（WebSocketTransport、TransportAdapter、Land 管理） |
| **SwiftStateTreeHummingbird** | Hummingbird 整合（LandServer、JWT/Guest、Admin 路由） |
| **SwiftStateTreeBenchmarks** | 基準測試執行檔 |

## 🚚 傳輸編碼格式（Transport Encodings）

SwiftStateTree 目前支援 **三種**傳輸編碼組合。建議預設使用 **MessagePack**，搭配 opcode array 協議、PathHash 與執行期 dynamic-key（slot）壓縮，以獲得更小的封包與更快的解析速度。

| 模式 | Message 編碼 | StateUpdate 編碼 | 說明 |
|---|---|---|---|
| **JSON（除錯用）** | `json` | `jsonObject` | 最好閱讀、最容易除錯 |
| **Opcode JSON（精簡）** | `opcodeJsonArray` | `opcodeJsonArray` | JSON 陣列格式更精簡，適合作為過渡方案 |
| **MessagePack（預設）** | `messagepack` | `opcodeMessagePack` | 封包最小、解析最快 |

完整細節與效能數據請參考：[Transport Evolution](docs/transport_evolution.zh-TW.md)。

## 📦 系統要求

- Swift 6.0+
- **macOS**（原生開發，支援 Apple Silicon）
- **Windows**：支援使用 VSCode/Cursor 的 [Dev Containers](https://code.visualstudio.com/docs/devcontainers/containers) 進行開發（配置檔案：`.devcontainer/devcontainer.json`）

## 🏃 快速開始

### 1. 克隆並構建

```bash
git clone https://github.com/your-username/SwiftStateTree.git
cd SwiftStateTree

# Note: The sdk directory uses lowercase to match other directories
# (Examples, Notes, Sources, Tests, Tools, docs)

swift build
```

### 2. 運行範例

啟動 DemoServer（包含 Cookie 遊戲和 Counter 範例）：
```bash
cd Examples/Demo
swift run DemoServer
```

伺服器預設運行在 `http://localhost:8080`。

在另一個終端生成客戶端代碼並啟動 WebClient：
```bash
cd Examples/Demo/WebClient
npm install  # 首次運行需要安裝依賴
npm run codegen  # 生成客戶端代碼
npm run dev
```

WebClient 會運行在另一個端口（通常是 `http://localhost:5173`），可在瀏覽器中訪問並導航到 Counter Demo 頁面。

**其他可用範例：**
- 🍪 [Cookie Clicker 範例](docs/examples/cookie-clicker.zh-TW.md) - 完整的多玩家遊戲範例，包含私有狀態、升級系統、定期 Tick 處理等進階功能

### 3. 查看詳細文檔

- 📖 [完整文檔索引](docs/index.zh-TW.md)
- 🚀 [快速開始指南](docs/quickstart.zh-TW.md)
- 📐 [架構概觀](docs/overview.zh-TW.md)
- 🔎 [深度研究筆記](deep-research/README.zh-TW.md)

### 4. 最簡單範例

以下是一個簡化的計數器範例，展示核心概念。完整可運行的原始碼請參考：
- **伺服器端定義**：[`Examples/Demo/Sources/DemoContent/CounterDemoDefinitions.swift`](Examples/Demo/Sources/DemoContent/CounterDemoDefinitions.swift)
- **伺服器主程式**：[`Examples/Demo/Sources/DemoServer/main.swift`](Examples/Demo/Sources/DemoServer/main.swift)
- **客戶端 Vue 組件**：[`Examples/Demo/WebClient/src/views/CounterPage.vue`](Examples/Demo/WebClient/src/views/CounterPage.vue)

#### 伺服器端（Swift）

```swift
import SwiftStateTree
import SwiftStateTreeHummingbird

// 1. 定義狀態
@StateNodeBuilder
struct CounterState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

// 2. 定義 Action
@Payload
struct IncrementAction: ActionPayload {
    typealias Response = IncrementResponse
}

@Payload
struct IncrementResponse: ResponsePayload {
    let newCount: Int
}

// 3. 定義 Land
let counterLand = Land("counter", using: CounterState.self) {
    AccessControl {
        AllowPublic(true)
        MaxPlayers(10)
    }
    
    Lifetime {
        Tick(every: .milliseconds(100)) { (_: inout CounterState, _: LandContext) in
            // Empty tick handler
        }
    }
    
    Rules {
        HandleAction(IncrementAction.self) { state, action, ctx in
            state.count += 1
            return IncrementResponse(newCount: state.count)
        }
    }
}

// 4. 啟動伺服器（簡化版，完整版請參考原始碼）
@main
struct DemoServer {
    static func main() async throws {
        // Create LandHost to manage HTTP server and game logic
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080
        ))

        // Register land type
        try await host.register(
            landType: "counter",
            land: counterLand,
            initialState: CounterState(),
            webSocketPath: "/game/counter",
            configuration: LandServerConfiguration(
                allowGuestMode: true,
                allowAutoCreateOnJoin: true
            )
        )

        // Run unified server
        try await host.run()
    }
}
```

#### Codegen 自動生成

所有客戶端代碼都是從伺服器的 schema 自動生成的，整合非常簡單：

```bash
# 從 schema.json 生成客戶端代碼
npm run codegen

# 或從運行中的伺服器直接獲取 schema
npm run codegen:server
```

**生成的檔案結構：**
```
src/generated/
├── counter/
│   ├── useCounter.ts      # Vue composable（自動生成）
│   ├── index.ts           # StateTree 類別
│   ├── bindings.ts        # 類型綁定
│   └── testHelpers.ts     # 測試輔助函數
├── defs.ts                # 共享類型定義（State、Action、Response）
└── schema.ts              # Schema 元數據
```

**Codegen 自動生成的內容：**

1. **State 類型定義**：從伺服器的 `CounterState` 自動生成對應的 TypeScript 類型
   ```typescript
   // 自動生成：src/generated/defs.ts
   export interface CounterState {
     count: number  // 對應伺服器的 @Sync(.broadcast) var count: Int
   }
   ```

2. **Action 函數**：每個伺服器的 Action 都會生成對應的客戶端函數
   ```typescript
   // 自動生成：src/generated/counter/useCounter.ts
   export function useCounter() {
     return {
       state: Ref<CounterState | null>,      // 響應式狀態
       increment: (payload: IncrementAction) => Promise<IncrementResponse>,
       // ... 其他 action 函數
     }
   }
   ```

3. **完整的類型安全**：所有 Action 的 payload 和 response 都有完整的 TypeScript 類型

**優勢：**
- ✅ **類型安全**：TypeScript 類型完全對應伺服器定義
- ✅ **零配置**：一次命令生成所有需要的代碼
- ✅ **自動同步**：伺服器變更後重新執行 codegen 即可更新
- ✅ **開箱即用**：生成的 composable 可直接在 Vue 組件中使用

#### 客戶端（Vue 3）

使用 codegen 生成的 composable，整合非常簡單：

```vue
<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'
import { useCounter } from './generated/counter/useCounter'

// 使用生成的 composable，自動包含 state 和所有 action 函數
const { state, isJoined, connect, disconnect, increment } = useCounter()

onMounted(async () => {
  await connect({ wsUrl: 'ws://localhost:8080/game' })
})

onUnmounted(async () => {
  await disconnect()
})
</script>

<template>
  <div v-if="!isJoined || !state">Connecting...</div>
  <div v-else>
    <!-- 直接使用生成的 state，完全類型安全 -->
    <h2>Count: {{ state.count ?? 0 }}</h2>
    <!-- 使用生成的 action 函數 -->
    <button @click="increment({})" :disabled="!isJoined">+1</button>
  </div>
</template>
```

#### 運行範例

**1. 啟動伺服器：**
```bash
cd Examples/Demo
swift run DemoServer
```
伺服器會在 `http://localhost:8080` 啟動，提供兩個遊戲端點：
- Cookie 遊戲：`ws://localhost:8080/game/cookie`
- Counter 範例：`ws://localhost:8080/game/counter`

**2. 生成客戶端代碼：**
```bash
cd WebClient
npm run codegen
```

**3. 啟動客戶端：**
```bash
npm run dev
```
然後在瀏覽器中打開 `http://localhost:5173`，導航到 Counter Demo 頁面。

**關鍵點：**
- 伺服器使用 `@StateNodeBuilder` 定義狀態樹，`@Sync(.broadcast)` 控制同步策略
- 客戶端使用生成的 composable（如 `useCounter`），由 schema 自動生成
- 在 template 中直接使用 `state.count`，Vue 會自動處理響應式更新
- 使用 composable 提供的 action 方法（如 `increment`）來發送操作

## 📁 專案結構

```
SwiftStateTree/
├── Sources/
│   ├── SwiftStateTree/              # 核心模組
│   ├── SwiftStateTreeTransport/     # Transport 層
│   ├── SwiftStateTreeHummingbird/   # Hummingbird 整合
│   └── SwiftStateTreeBenchmarks/    # 基準測試
├── Tests/                           # 單元測試
├── Examples/                        # 範例專案
│   └── Demo/
├── docs/                            # 正式文檔
└── Notes/                           # 設計與開發筆記
```

詳細的模組說明請參考 [docs/overview.zh-TW.md](docs/overview.zh-TW.md)。

## 💡 核心概念

### StateTree：單一權威狀態樹

使用 `@StateNodeBuilder` 定義狀態樹，透過 `@Sync` 屬性控制同步策略：

```swift
@StateNodeBuilder
struct GameStateTree: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
}
```

### 同步規則

- `.broadcast`：廣播給所有 client
- `.perPlayerSlice()`：Dictionary 專用，自動切割 `[PlayerID: Element]` 只同步該玩家的 slice（使用頻率高）
- `.perPlayer(...)`：需要手動提供 filter function，依玩家過濾（適用於任何類型，需要自定義邏輯時使用）
- `.masked(...)`：同型別遮罩（所有玩家看到相同遮罩值）
- `.serverOnly`：伺服器內部用，不同步給 client
- `.custom(...)`：完全客製化過濾邏輯

### Land DSL

定義領域邏輯、Action/Event 處理、Tick 設定：

```swift
let gameLand = Land("game-room", using: GameStateTree.self) {
    AccessControl { MaxPlayers(4) }
    Lifetime { Tick(every: .milliseconds(100)) { ... } }
    Rules { HandleAction(...) { ... } }
}
```

**詳細說明請參考：**
- 📖 [核心概念文檔](docs/core/README.zh-TW.md)
- 🔄 [同步規則詳解](docs/core/sync.zh-TW.md)
- 🏛️ [Land DSL 指南](docs/core/land-dsl.zh-TW.md)

## 📚 文檔

完整的文檔請參考 [docs/index.zh-TW.md](docs/index.zh-TW.md)，包含：

- 🚀 [快速開始](docs/quickstart.zh-TW.md) - 最小可行範例
- 📐 [架構概觀](docs/overview.zh-TW.md) - 系統設計與模組說明
- 🏛️ [Land DSL](docs/core/land-dsl.zh-TW.md) - 領域定義指南
- 🔄 [同步規則](docs/core/sync.zh-TW.md) - 狀態同步詳解
- 🌐 [Transport](docs/transport/README.zh-TW.md) - 網路傳輸層
- 🐦 [Hummingbird](docs/hummingbird/README.zh-TW.md) - 伺服器整合

設計與開發筆記請參考 [`Notes/`](Notes/index.md)（計劃的狀態索引在 [`Notes/plans/README.md`](Notes/plans/README.md)），實驗資料在 [`deep-research/`](deep-research/README.md)。

## 🧪 測試

本專案使用 **Swift Testing**（Swift 6 的新測試框架）進行單元測試。

### 運行測試

```bash
# 運行所有單元測試
swift test

# 運行 E2E 與協議測試 (需要啟動 DemoServer)
cd Tools/CLI && npm test
```

**E2E 測試覆蓋**:
- ✅ 核心功能: Actions, Events, State Sync, Error Handling, Multi-Encoding
- ✅ 生命週期: Tick Handler, OnJoin Handler
- ⚠️ 部分覆蓋: Per-Player State, Broadcast State (單一客戶端)
- ❌ 未覆蓋: Multi-Player Scenarios, OnLeave Handler

詳細的 E2E 測試文檔請參閱 [Tools/CLI/README.md](Tools/CLI/README.md)。

### 編寫測試

使用 `@Test` 屬性和 `#expect()` 進行斷言：

```swift
import Testing
@testable import SwiftStateTree

@Test("Description of what is being tested")
func testYourFeature() throws {
    let state = YourStateTree()
    let result = state.someMethod()
    #expect(result == expectedValue)
}
```

## 🤝 貢獻

本專案為個人興趣專案，歡迎討論和建議！如果有想法或問題，可以透過 Issue 或 Pull Request 提出。

如果需要提交代碼，請遵循以下步驟：

1. Fork 本倉庫
2. 創建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 開啟 Pull Request

### 代碼規範

- 遵循 Swift API 設計指南
- 使用 Swift 6 並發特性（Actor、async/await）
- 確保所有公開 API 符合 `Sendable`
- 為新功能添加測試用例
- **所有程式碼註解必須使用英文**（包括 `///` 文檔註解和 `//` 行內註解）

詳細的開發指南請參考 [AGENTS.md](AGENTS.md)。

## 📄 許可證

本專案採用 MIT 許可證。

## 🔗 相關資源

- [Swift 官方文檔](https://swift.org/documentation/)
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

---

**注意**：本專案正在積極開發中，API 可能會發生變化。建議在生產環境使用前仔細測試。

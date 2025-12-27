# SwiftStateTree

一個基於 Swift 的多人遊戲伺服器框架，採用 **單一 StateTree + 同步規則 + Land DSL** 的設計理念。

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

## 📦 系統要求

- Swift 6.0+
- macOS 14.0+

## 🚀 安裝

### Swift Package Manager

在你的 `Package.swift` 中添加依賴：

```swift
dependencies: [
    .package(url: "https://github.com/your-username/SwiftStateTree.git", from: "1.0.0")
]
```

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

啟動伺服器（單房間模式）：
```bash
cd Examples/HummingbirdDemo
swift run SingleRoomDemo
```

伺服器預設運行在 `http://localhost:8080`。

在另一個終端啟動 WebClient：
```bash
cd Examples/HummingbirdDemo/WebClient
npm install  # 首次運行需要安裝依賴
npm run dev
```

WebClient 會運行在另一個端口（通常是 `http://localhost:5173`），可在瀏覽器中訪問。

### 3. 查看詳細文檔

- 📖 [完整文檔索引](docs/index.md)
- 🚀 [快速開始指南](docs/quickstart.md)
- 📐 [架構概觀](docs/overview.md)

### 4. 最簡單範例

以下是一個完整的計數器範例，展示如何建立伺服器和 Vue 客戶端：

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
    Rules {
        HandleAction(IncrementAction.self) { state, action, ctx in
            state.count += 1
            return IncrementResponse(newCount: state.count)
        }
    }
}

// 4. 啟動伺服器
@main
struct CounterServer {
    static func main() async throws {
        let server = try await LandServer.makeServer(
            configuration: .init(allowGuestMode: true),
            land: counterLand,
            initialState: CounterState()
        )
        try await server.run()
    }
}
```

#### 客戶端（Vue 3）

```vue
<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'
import { useCounter } from './generated/counter/useCounter'

// 使用生成的 composable
const {
  state,
  isJoined,
  connect,
  disconnect,
  increment
} = useCounter()

onMounted(async () => {
  await connect({
    wsUrl: 'ws://localhost:8080/game'
  })
})

onUnmounted(async () => {
  await disconnect()
})

async function handleIncrement() {
  await increment({})
}
</script>

<template>
  <div>
    <h1>計數器: {{ state?.count ?? 0 }}</h1>
    <button @click="handleIncrement" :disabled="!isJoined">
      +1
    </button>
  </div>
</template>
```

**關鍵點：**
- 伺服器使用 `@StateNodeBuilder` 定義狀態樹，`@Sync(.broadcast)` 控制同步策略
- 客戶端使用生成的 composable（如 `useCounter`），由 schema 自動生成
- 在 template 中直接使用 `state?.count`，Vue 會自動處理響應式更新
- 使用 composable 提供的 action 方法（如 `increment`）來發送操作

**注意：** 使用前需要先運行 schema 生成工具來產生 composable 和型別定義。完整流程請參考 `Examples/HummingbirdDemo`。

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
│   └── HummingbirdDemo/
├── docs/                            # 正式文檔
└── Notes/                           # 設計與開發筆記
```

詳細的模組說明請參考 [docs/overview.md](docs/overview.md)。

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
- 📖 [核心概念文檔](docs/core/README.md)
- 🔄 [同步規則詳解](docs/core/sync.md)
- 🏛️ [Land DSL 指南](docs/core/land-dsl.md)

## 📚 文檔

完整的文檔請參考 [docs/index.md](docs/index.md)，包含：

- 🚀 [快速開始](docs/quickstart.md) - 最小可行範例
- 📐 [架構概觀](docs/overview.md) - 系統設計與模組說明
- 🏛️ [Land DSL](docs/core/land-dsl.md) - 領域定義指南
- 🔄 [同步規則](docs/core/sync.md) - 狀態同步詳解
- 🌐 [Transport](docs/transport/README.md) - 網路傳輸層
- 🐦 [Hummingbird](docs/hummingbird/README.md) - 伺服器整合

設計與開發筆記請參考 `Notes/` 目錄。

## 🧪 測試

本專案使用 **Swift Testing**（Swift 6 的新測試框架）進行單元測試。

### 運行測試

```bash
# 運行所有測試
swift test

# 運行特定測試
swift test --filter StateTreeTests.testGetSyncFields
```

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

歡迎貢獻代碼！請遵循以下步驟：

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

本專案採用 MIT 許可證。詳見 [LICENSE](LICENSE) 文件。

## 🔗 相關資源

- [Swift 官方文檔](https://swift.org/documentation/)
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

---

**注意**：本專案正在積極開發中，API 可能會發生變化。建議在生產環境使用前仔細測試。

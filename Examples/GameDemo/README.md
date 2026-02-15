# Hero Defense 遊戲示範

使用 SwiftStateTree 建構的確定性多人塔防遊戲示範。

## 概覽

此示範包含：
- 使用固定點運算的確定性遊戲邏輯
- 伺服器權威的狀態同步機制
- 即時多人連線玩法
- system-based 架構（Movement、Combat、Monster、Turret systems）

## 專案結構

```
GameDemo/
├── Sources/
│   ├── GameContent/          # 核心遊戲邏輯
│   │   ├── Actions/          # 伺服器 actions
│   │   ├── Events/           # 客戶端 events
│   │   ├── States/           # 遊戲狀態定義
│   │   ├── Systems/          # 遊戲系統（Movement、Combat 等）
│   │   └── Config/           # 遊戲設定
│   ├── GameServer/           # 伺服器可執行檔
│   └── SchemaGen/            # Schema 產生工具
├── Tests/                    # 單元測試
├── WebClient/                # Web 客戶端（Vue.js + Phaser）
└── CliClient/                # CLI 測試客戶端
```

## 建置

```bash
# 建置專案
swift build

# Release 版本建置
swift build -c release
```

## 啟動伺服器

```bash
# 啟動遊戲伺服器
swift run GameServer

# 指定編碼模式（預設：messagepack）
TRANSPORT_ENCODING=json swift run GameServer
TRANSPORT_ENCODING=jsonOpcode swift run GameServer
```

伺服器預設運行於 `http://localhost:8080`。

## 測試

### 單元測試

執行所有單元測試：

```bash
cd Examples/GameDemo
swift test
```

執行指定測試套件：

```bash
# MovementSystem 測試
swift test --filter GameSystemTests

# Deterministic RNG 測試
swift test --filter DeterministicTests
```

**重要**：修改遊戲邏輯（Systems、States、Actions、Events）後，務必執行單元測試以確保正確性：

```bash
swift test
```

### E2E 測試

E2E 測試會驗證完整遊戲流程（包含 server-client 通訊）。

**前置需求**：
- 已安裝 Node.js 與 npm
- GameServer 必須啟動（或使用自動化測試腳本）

**執行 E2E 測試**：

```bash
# 方案 1：自動化（建議 - 會處理 server 啟動/關閉）
cd Tools/CLI
npm run test:e2e:game:ci

# 方案 2：手動
# Terminal 1：啟動 server
cd Examples/GameDemo
swift run GameServer

# Terminal 2：執行測試
cd Tools/CLI
npm test -- scenarios/game/test-demo-game.json
```

**重要**：修改遊戲邏輯或伺服器設定後，務必執行 E2E 測試以驗證端到端功能：

```bash
cd Tools/CLI
npm run test:e2e:game:ci
```

### 測試覆蓋範圍

- **單元測試**：遊戲系統（Movement、Combat、Monster 生成）、確定性 RNG、狀態管理
- **E2E 測試**：完整遊戲流程（actions、events、state sync）、多種編碼模式

## 開發流程

調整遊戲邏輯時建議流程：

1. **修改遊戲程式碼**
2. **執行單元測試**：
   ```bash
   cd Examples/GameDemo
   swift test
   ```
3. **執行 E2E 測試**：
   ```bash
   cd Tools/CLI
   npm run test:e2e:game:ci
   ```
4. **確認所有測試通過**再提交

## 遊戲系統

### MovementSystem
負責玩家與怪物的移動邏輯：
- `updatePlayerMovement`：玩家朝目標位置移動
- `updateMonsterMovement`：怪物朝基地移動
- `clampToWorldBounds`：確保位置在世界邊界內

### CombatSystem
負責戰鬥邏輯：
- 玩家武器傷害與射程計算
- 炮塔傷害與射程計算
- 攻擊間隔限制
- 自動鎖定邏輯

### MonsterSystem
負責怪物生成與行為：
- 確定性怪物生成
- 怪物與基地互動
- 獎勵分配

### TurretSystem
負責炮塔放置驗證：
- 位置驗證
- 與基地距離檢查
- 碰撞檢測

## 設定

遊戲設定定義於 `Sources/GameContent/Config/GameConfig.swift`：
- 世界大小：128x72 單位
- 基地位置：中心點 (64, 36)
- Tick 間隔：50ms
- 怪物生成頻率與生命值
- 武器與炮塔數值

## 架構說明

### ECS-inspired system-based architecture（系統模式）

本專案採用 **ECS-inspired system-based architecture**（類似 ECS 架構，下稱 systems (ECS-inspired)），將遊戲邏輯組織為靜態函數系統，並以 deterministic、server-authoritative 的執行模型為前提：

- **數據與行為分離**：數據定義在 `States/`（如 `PlayerState`, `MonsterState`），行為定義在 `Systems/`（如 `MovementSystem`, `CombatSystem`）
- **Function-first 設計**：使用 `enum` + `static func` 而非 `class`，降低隱藏狀態與繼承耦合
- **顯式依賴注入**：依賴（config, RNG, logger, tickId）透過 `LandContext` 顯式傳遞
- **可預測 / 可重播**：計算邏輯以可重現為目標，副作用集中在 handler / ctx 邊界

#### 工程觀察（偏向性、非保證）

在某些條件下（例如介面明確、範例充分、測試可即時驗證），systems (ECS-inspired) 的函數簽名與顯式依賴**可能有助於對齊** AI 產出的呼叫方式，並降低猜測空間。但這並不保證正確性，仍需測試、lint、review 作為防線。

#### 與傳統 OOP 的取捨（trade-off）

| 特性 | ECS-inspired system-based architecture（當前） | 傳統 OOP |
|------|----------------------|----------|
| **AI 理解** | 較容易從函數簽名推導 | 通常需要理解繼承層次 |
| **測試** | 較簡單，只需 context | 通常需要 mock 較完整的依賴鏈 |
| **依賴** | 較明確在參數中 | 較多隱含在構造函數中 |
| **狀態** | 較少隱藏狀態 | 較多封裝在對象中 |
| **組合** | 函數較易獨立組合 | 通常需要理解對象關係 |

**結論（偏向性的觀察）**：傳統 OOP 封裝有其價值（可讀性、維護性與邊界保護），而 systems (ECS-inspired) 在 AI 輔助開發場景下**在某些條件下**可能更容易對齊與維護。這是一種工程取捨，而非取代。

#### 單元測試作為 guardrails（AI agent 約束）

此設計的單元測試 setup 成本較低（state + minimal ctx 即可），因此更適合作為 AI agent workflow 的 guardrails，用來快速驗證 invariants 與防止偏離。

```swift
@Test("CombatSystem.getWeaponDamage calculates base damage correctly")
func testGetWeaponDamageBase() {
    let ctx = createCombatTestContext()
    let damage = CombatSystem.getWeaponDamage(level: 0, ctx)
    #expect(damage == 5)
}

@Test("CombatSystem.canPlayerFire returns true when enough time has passed")
func testCanPlayerFireWhenReady() {
    var player = PlayerState()
    player.lastFireTick = 0
    let ctx = createCombatTestContext(tickId: 10)
    let canFire = CombatSystem.canPlayerFire(player, ctx)
    #expect(canFire == true)
}
```

### Context Pattern（上下文模式）

Systems 透過 `LandContext` 訪問服務與元資料：
- `ctx.services`：服務容器（config, RNG 等）
- `ctx.tickId`：當前 tick ID
- `ctx.logger`：日誌記錄器
- `ctx.playerID`：當前玩家 ID

這種設計確保：
- 依賴明確：所有依賴都在函數簽名中可見
- 易於測試：可以輕鬆創建測試用的 context
- 無全局狀態：避免隱藏的全局依賴

### Deterministic Math（確定性數學）

所有遊戲計算使用 `SwiftStateTreeDeterministicMath` 進行跨平台一致性：
- 使用 Int32 固定點運算（scale factor: 1000）
- 避免平台相關的浮點運算差異
- 支援重播和確定性模擬

## License

請參考根目錄的 LICENSE。

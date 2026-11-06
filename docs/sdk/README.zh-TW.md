[English](README.md) | [中文版](README.zh-TW.md)

# TypeScript SDK 架構

SwiftStateTree TypeScript SDK 提供客戶端函式庫，用於連接和操作 SwiftStateTree 伺服器。本文件說明分層架構以及不同框架應如何整合 SDK。

## 架構總覽

```
┌─────────────────────────────────────────────────────────────────┐
│                       框架特定層                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  useHeroDefense │  │   Cocos Hook    │  │   原生 JS       │  │
│  │   (Vue 3)       │  │   (Cocos)       │  │                 │  │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  │
│           │                    │                    │           │
├───────────┴────────────────────┴────────────────────┴───────────┤
│                       生成程式碼層                               │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                  HeroDefenseStateTree                        │ │
│  │  - 類型安全的狀態存取                                         │ │
│  │  - 類型安全的動作                                             │ │
│  │  - 類型安全的事件                                             │ │
│  │  - 類型安全的 Map 訂閱 (players.onAdd/onRemove)              │ │
│  └──────────────────────────┬──────────────────────────────────┘ │
│                             │                                    │
├─────────────────────────────┴────────────────────────────────────┤
│                        SDK 核心層                                │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    StateTreeView                             │ │
│  │  - WebSocket 連線管理                                        │ │
│  │  - 狀態同步（快照、補丁）                                     │ │
│  │  - 低階 onPatch 回呼                                         │ │
│  └──────────────────────────┬──────────────────────────────────┘ │
│                             │                                    │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                   StateTreeRuntime                           │ │
│  │  - 多 Land 路由                                              │ │
│  │  - 訊息分發                                                  │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## 各層職責

### SDK 核心層 (`@swiftstatetree/sdk`)

基礎層提供：

- **StateTreeRuntime**：管理 WebSocket 連線並將訊息路由到適當的 Land
- **StateTreeView**：表示特定 Land 狀態樹的視圖
  - 處理狀態同步（快照、補丁）
  - 提供低階 `onPatch()` 回呼以觀察原始補丁
  - 框架無關，純 TypeScript

### 生成程式碼層（Codegen）

從伺服器 schema 生成的類型安全包裝器：

- **`{LandName}StateTree`**：應用程式的主要進入點
  - 以類型安全介面包裝 `StateTreeView`
  - 提供 `state`、`actions`、`events` 存取器
  - 提供 Map 訂閱（例如 `players.onAdd()`、`players.onRemove()`）

範例：

```typescript
// 生成的 HeroDefenseStateTree
class HeroDefenseStateTree {
    readonly view: StateTreeView
    
    // 類型安全的狀態存取
    get state(): HeroDefenseState { ... }
    
    // 類型安全的動作
    readonly actions = {
        moveTo(position: Position): void { ... },
        attack(targetId: string): void { ... }
    }
    
    // 類型安全的事件
    readonly events = {
        onDamageDealt(callback: (event: DamageDealtEvent) => void): () => void { ... }
    }
    
    // 類型安全的 Map 訂閱
    readonly players: MapSubscriptions<PlayerState>
}
```

### 框架特定層

將生成程式碼與特定 UI 框架整合的適配器：

| 框架 | 適配器 | 響應式機制 |
|-----------|---------|------------|
| Vue 3 | `useHeroDefense()` | `ref()`、`reactive()`、`computed()` |
| React | `useHeroDefense()` | `useState()`、`useEffect()` |
| Cocos | 自訂包裝器 | Cocos 信號/事件 |
| Phaser | 直接使用 | 手動更新 |
| 原生 JS | 直接使用 | 回呼函式 |

## 使用模式

### 模式一：Vue 3 組件

使用生成的 composable 獲得響應式狀態：

```typescript
// 在 Vue 組件中
import { useHeroDefense } from './generated/hero-defense/useHeroDefense'

const { state, actions, events, currentPlayerID } = useHeroDefense(runtime, landID)

// state 是響應式的 - 模板自動更新
// actions 是可呼叫的方法
// events 提供訂閱函式
```

### 模式二：Phaser/遊戲引擎（框架無關）

直接使用 `HeroDefenseStateTree`：

```typescript
// 在 Phaser 場景中
import { HeroDefenseStateTree } from './generated/hero-defense'

class GameScene extends Phaser.Scene {
    private tree: HeroDefenseStateTree
    private playerManager: PlayerManager
    
    setStateTree(tree: HeroDefenseStateTree) {
        this.tree = tree
        
        // 訂閱 Map 變更
        tree.players.onAdd((playerID, playerState) => {
            this.playerManager.createPlayer(playerID, playerState)
        })
        
        tree.players.onRemove((playerID) => {
            this.playerManager.removePlayer(playerID)
        })
    }
    
    update() {
        // 直接讀取狀態（非響應式）
        const players = this.tree.state.players
        this.playerManager.updatePlayers(players)
    }
}
```

### 模式三：低階補丁觀察

進階用例可觀察原始補丁：

```typescript
const tree = new HeroDefenseStateTree(view)

// 低階：觀察所有補丁
tree.view.onPatch((patch, decodedValue) => {
    console.log(`${patch.op} at ${patch.path}:`, decodedValue)
})
```

## Map 訂閱

生成的程式碼為 Map 屬性提供類型安全的訂閱：

```typescript
interface MapSubscriptions<T> {
    onAdd(callback: (key: string, value: T) => void): () => void
    onRemove(callback: (key: string) => void): () => void
}
```

這些會自動為任何定義為 Map（具有動態鍵的物件）的狀態屬性生成：

```swift
// 伺服器端定義
@StateNodeBuilder
class HeroDefenseLand {
    var players: [String: PlayerState] = [:]  // 生成 MapSubscriptions<PlayerState>
}
```

## 錯誤與連線中斷

各請求的結果：

| 情況 | `view.join()` | `view.sendAction()` |
|---|---|---|
| Server 回應 | resolve `{ success: true, playerID, ... }` | resolve 回應內容 |
| Server 拒絕或回報錯誤 | resolve `{ success: false, reason }` | 以 `Error` reject（帶 error frame 的 `code`、`details`） |
| Runtime 未連線／view 未 join | reject（`Runtime not connected`） | reject（`Not joined to land`） |
| 等待中連線關閉、呼叫 `runtime.disconnect()` 或 `runtime.removeView()` | 以 `ConnectionClosedError` reject | 以 `ConnectionClosedError` reject |

`ConnectionClosedError`（由 `@swiftstatetree/sdk` 匯出）表示已不可能收到回應：

- `kind`：`'close'`（WebSocket 關閉）、`'disconnect'`（client 呼叫了 `disconnect()`）或 `'viewRemoved'`；
- `closeCode`、`closeReason`、`wasClean`：`kind` 為 `'close'` 時的 WebSocket 關閉資訊。

每個等待中的請求只會結束一次：關閉之後才到的回應會被忽略。連線關閉時 runtime 會銷毀它的 view，因此重新連線前的 view 不再處於 join 狀態，其 `sendAction()` 會 reject；請在新連線上建立並 join 新的 view。目前沒有逐請求的 timeout；需要時請自行為呼叫加上期限。

```typescript
import { ConnectionClosedError } from '@swiftstatetree/sdk'

try {
  await view.sendAction('Move', payload)
} catch (error) {
  if (error instanceof ConnectionClosedError) {
    // 重新連線，再建立並 join 新的 view
  } else {
    // server 拒絕了這個 action
  }
}
```

### 連線與重新連線

- 對同一個 URL 的 connect 進行中時再呼叫 `connect(url)`，會回傳同一個 promise，不會開第二個 socket；連到其他 URL 則會被拒絕（`Already connecting to <url>`）。請等它完成，或先呼叫 `disconnect()`。
- connect 進行中呼叫 `disconnect()` 會中止它：該 connect 以 `ConnectionClosedError`（`kind: 'disconnect'`）reject，尚在建立中的 socket 建立完成時即被關閉。
- `disconnect()` 之後，舊 socket 晚到的事件（open、message、error、close）都會被忽略，因此 `disconnect()` 後立即 `connect()` 是安全的；live／replay 切換就是這樣做的。
- 目前連線仍開啟時（包含 server 正在關閉的連線）呼叫 connect 會被拒絕（`Already connected`）。
- `StateTreeSession` 依呼叫順序一次只執行一個模式切換。`session.disconnect()` 會取消執行中與所有排隊中的切換：每個都以 `ConnectionClosedError`（`kind: 'disconnect'`）reject，模式維持不變。產生的 Vue composable 行為相同：connect 進行中再呼叫 `connect()` 會回傳進行中的那個，`disconnect()` 會讓進行中的 connect 在下一個 await 停止，join 途中連線關閉會讓 connect reject 並設定 `lastError`。

### 傳遞語意：至多一次（at most once）

action 至多被傳遞一次：

- **連線關閉時，等待中的 action 會被 reject，其結果未知。** `ConnectionClosedError` 表示不可能再收到回應，但不代表伺服器是否套用了該 action：可能在關閉前已套用，也可能根本沒收到。
- **不會自動重送。** SDK 不會重送 action 或 client event，CLI 與壓測工具也不會。是否重送由 app 決定；伺服器會把重送的 action 再套用一次。
- **以 firstSync 為準。** 重新連線後，新 view 在 firstSync 收到的狀態就是伺服器對該玩家的完整視角。要知道某個 action 是否生效，請從這份狀態判斷，而不是從被 reject 的 promise。重建之所以精確，是因為每次 disconnect 與 close 時 runtime 都會銷毀它的 view：新的 view 從空狀態開始，所以客戶端離線期間在伺服器上被移除的玩家或欄位就不會出現（#219，已用 convergence 與通過 replay 驗證的錄製做端對端確認）。
- **在有 tick 的 land 上，action 的回應只是 ACK，代表「已排入佇列」，不代表「已套用」。** handler 在之後的 tick 執行，它的回傳值不會送到 client。請從狀態讀取結果。
- **每個操作至多套用一次，需要在 payload 裡放 ID。** 不能重複發生的操作（例如購買），請在 action 的 payload 中放一個 ID，並讓 land 的 handler 把已套用過的 ID 記在 land 狀態裡，上限由 app 決定。transport 刻意不內建去重：在狀態裡去重是決定性的，會隨 land 一起 replay，放在狀態以外就不會。範例見[必須至多套用一次的 action](../core/land-dsl.zh-TW.md#必須至多套用一次的-action)。

`firstSync` 更新不一定是完整視角。伺服器也會在現有連線上把更新標為 `firstSync`，用來重設某個動態 key scope（例如有其他玩家加入時）；此時它的 patch 只是一般的 diff。因此 view 會像套用 diff 一樣把 firstSync 的 patch 套到狀態上，而不會清空狀態；runtime 的動態 key 表在每次 disconnect 與 close 時清空，並由該 frame 在解碼時重新定義。

## 選擇正確的層級

| 使用場景 | 建議層級 |
|----------|-------------------|
| Vue/React UI 組件 | 框架特定層 (`useHeroDefense`) |
| Phaser/Cocos 遊戲場景 | 生成程式碼層 (`HeroDefenseStateTree`) |
| 自訂遊戲引擎 | 生成程式碼層 (`HeroDefenseStateTree`) |
| 除錯/日誌 | SDK 核心層 (`StateTreeView.onPatch`) |
| 建立新的框架適配器 | SDK 核心層 + 生成程式碼層 |

## 最佳實踐

1. **不要混用層級**：如果使用 Vue，就用 `useHeroDefense()`。如果使用 Phaser，就直接用 `HeroDefenseStateTree`。

2. **避免重複包裝**：生成的 `StateTree` 已經是框架無關的中間層。不要建立額外的包裝介面。

3. **使用 Map 訂閱管理集合**：對於玩家/實體管理，優先使用 `onAdd`/`onRemove` 而非手動比對差異。

4. **保持遊戲邏輯框架無關**：遊戲管理器（如 `PlayerManager`）應依賴 `HeroDefenseStateTree`，而非 Vue/React hooks。

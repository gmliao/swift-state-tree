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

# TypeScript SDK 設計

> 本文檔說明 **TypeScript SDK 的設計方向和實作規劃**。
>
> **本文檔定位**：TypeScript SDK 的具體設計（現況、規劃、API 設計）
>
> **相關文檔**：
> - **[DESIGN_CLIENT_SDK.md](./DESIGN_CLIENT_SDK.md)**：跨語言 SDK 架構設計和 codegen 理念（General）
>   - Codegen 架構設計（JSON Schema 中間格式、多語言生成器架構等）
>   - 生成器介面、模板引擎等通用設計
>
> **本文檔分成兩層**：
> - **已落地（以 repo 現況為準）**：`sdk/ts/src/core` + `sdk/ts/src/types`（Runtime/View/Protocol/WebSocket 抽象）
> - **Roadmap（接下來要做）**：TypeScript 版 schema codegen，產生「每個 land 一個 `StateTree` 類別」，提供有型別資訊的樹狀 state，以及 function-based 的 actions / events，適合 Vue、React 等前端框架使用

## 目標

### 核心目標

1. **`StateTree` 是一個類別**：綁定到單一 land（或由 factory 產生），包含狀態樹 + 行為（actions/events）。
2. **狀態是「有型別資訊的樹狀結構」可直接存取**：
   - 從 `schema.json` 生成完整的 TypeScript 型別定義
   - **框架無關設計**：生成的 state 是純 JavaScript 物件，適合 Vue、React 等框架使用
   - **Patch in-place 更新**：state 更新採用 patch 機制（而非整棵替換），讓框架可以追蹤深層變化
   - **可以直接存取深層屬性，例如 `state.players[0].name`，並有完整的型別提示**
3. **Action / Event 都是 function**：
   - `tree.actions.addGold({ amount: 1 })`
   - `tree.events.chat({ message: 'hi' })`
   - `tree.on.chatMessage((e) => { ... })`
4. **Schema 是唯一真相**：`schema.json` 變更 → 重新 codegen → TS types/constants/StateTree 對齊。

### 長期目標

- 從伺服端輸出的 `schema.json` 產生跨平台 SDK 所需的型別/常數，保持可重現：schema 變更 → 重跑 codegen → 各平台 SDK 自動對齊。
- 以 schema 為核心做版本同步：schema 版本升級 → TS/Unity SDK 主版號同步提升。

---

## 現況（repo 已有的 TS SDK Core）

目前 `sdk/ts` 已是一個可用的 npm package：`@swiftstatetree/sdk`，重點在「協議層 + 同步」。

**核心類別**
- `sdk/ts/src/core/runtime.ts`：`StateTreeRuntime`（管理單一 WebSocket、解碼/路由訊息）
- `sdk/ts/src/core/view.ts`：`StateTreeView`（綁定 land，負責 join、state snapshot/update/patch、sendAction/sendEvent/onServerEvent）

**現況 API（已可用）**

```ts
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'

const runtime = new StateTreeRuntime()
await runtime.connect('ws://localhost:8080/game')

const view = runtime.createView('demo-game', {
  onStateUpdate: (state) => {
    // 現況：SDK 會提供 plain object (Record<string, any>)
    // 問題：沒有型別資訊，無法直接存取深層屬性，例如 state.players[0].name
    // UI 端自行決定 ref/reactive 的策略
  }
})

await view.join()
await view.sendAction('AddGold', { amount: 1 })
view.sendEvent('Chat', { message: 'hi' })
view.onServerEvent('ChatMessage', (payload) => {
  // payload: any（現況，沒有型別安全）
})
```

> 這層會維持「低耦合、可跨環境（Node/Browser）」：不直接依賴 Vue，也不強迫型別安全（先跑得動，再由 codegen 補上 DX）。
>
> **現況限制**：`StateTreeView` 提供的 `state` 是 `Record<string, any>`，沒有型別資訊，無法直接存取深層屬性（例如 `state.players[0].name`）。Codegen 的目標就是解決這個問題。

---

## Roadmap：Codegen 之後的「Developer-facing API」

### 1) 生成的 `StateTree` 類別（每個 land 一個）

Codegen 的輸出重點不是把 Core 改掉，而是**在 Core 之上加一層「對應 schema 的 wrapper」**，提供完整的型別安全。

```ts
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { DemoGameStateTree } from './generated/demo-game'  // 從專案的 generated 目錄匯入

const runtime = new StateTreeRuntime()
await runtime.connect(url)

const tree = new DemoGameStateTree(runtime, {
  playerID: 'p1'
})

await tree.join()

// ✅ 有完整型別資訊的樹狀 state，可以直接存取深層屬性
tree.state.players['p1']  // 型別：string | undefined
tree.state.playerScores['p1']  // 型別：number | undefined
tree.state.playerPrivateStates['p1']?.gold  // 型別：number | undefined
tree.state.playerPrivateStates['p1']?.inventory[0]  // 型別：string | undefined

// ✅ actions / events 都是 function，有完整的型別提示
await tree.actions.addGold({ amount: 1 })  // amount 有型別檢查
tree.events.chat({ message: 'hi' })  // message 有型別檢查

// ✅ server events 訂閱也是 function（回傳 unsubscribe），payload 有型別
const off = tree.on.chatMessage((e) => {
  console.log(e.message)  // e.message 有型別：string
  console.log(e.from)      // e.from 有型別：string
})
off()
```

**建議形狀（共通基底）**
- `tree.state`：樹狀 state（**型別由 schema 推導，例如 `DemoGameState`**）
- `tree.actions.*`：Action functions（回傳 `Promise<Response>`，payload 有型別）
- `tree.events.*`：Client event functions（回傳 `void`，payload 有型別）
- `tree.on.*`：Server event subscription functions（回傳 `() => void`，payload 有型別）
- `tree.join()` / `tree.destroy()`：生命週期

### 2) 前端框架整合（Vue / React 等）

生成的 `StateTree` 是**框架無關**的，各框架可以自行決定如何處理 reactive/ref：

**Vue 使用範例**

```ts
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { DemoGameStateTree } from './generated/demo-game'  // 從專案的 generated 目錄匯入
import { reactive } from 'vue'

const runtime = new StateTreeRuntime()
await runtime.connect(url)

const tree = new DemoGameStateTree(runtime, { playerID: 'p1' })
await tree.join()

// 使用 Vue reactive 包裝 state
const state = reactive(tree.state)

// ✅ 有完整型別資訊，可以直接存取深層屬性
state.players['p1']  // 型別：string | undefined，Vue 會追蹤變化
state.playerPrivateStates['p1']?.gold  // 型別：number | undefined
state.playerPrivateStates['p1']?.inventory[0]  // 型別：string | undefined

// 在 Vue template 中可以直接使用
// <template>
//   <div>{{ state.playerPrivateStates[playerID]?.gold }}</div>
//   <div v-for="item in state.playerPrivateStates[playerID]?.inventory">
//     {{ item }}
//   </div>
// </template>
```

**React 使用範例**

```ts
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { DemoGameStateTree } from './generated/demo-game'  // 從專案的 generated 目錄匯入
import { useState, useEffect } from 'react'

const runtime = new StateTreeRuntime()
await runtime.connect(url)

const tree = new DemoGameStateTree(runtime, { playerID: 'p1' })
await tree.join()

// 使用 React state
const [state, setState] = useState(tree.state)

// 監聽 state 更新
useEffect(() => {
  // tree.state 會透過 patch in-place 更新
  // 可以選擇使用 setState 觸發重新渲染，或使用其他狀態管理方案
  const interval = setInterval(() => {
    setState({ ...tree.state })  // 觸發重新渲染
  }, 100)
  return () => clearInterval(interval)
}, [])

// ✅ 有完整型別資訊，可以直接存取深層屬性
state.players['p1']  // 型別：string | undefined
state.playerPrivateStates['p1']?.gold  // 型別：number | undefined
```

**關鍵設計原則**
- **框架無關**：生成的 `StateTree` 不依賴任何前端框架，是純 TypeScript/JavaScript
- **Patch in-place 更新**：state 更新採用 patch 機制（而非整棵替換），讓框架可以追蹤深層變化
- **型別安全**：生成的型別確保可以直接存取深層屬性，例如 `state.players[0].name`，並且有完整的型別提示和檢查
- **框架自行決定 reactive 策略**：Vue 可以用 `reactive()`，React 可以用 `useState` 或其他狀態管理方案

---

## TS Codegen 規格

### 輸入
- `schema.json`（由 Swift `SchemaGen` 輸出，型別定義見 `docs/protocol/SCHEMA_DEFINITION.md`）

### Codegen 工具位置

Codegen 工具放在 TS SDK package 內，作為可執行的 CLI：

- Codegen 工具位置：`sdk/ts/codegen/` 或 `sdk/ts/src/codegen/`
- 可透過 npm script 或直接執行：`npx @swiftstatetree/sdk codegen --input schema.json --output ./src/generated`

### 生成檔案位置（由使用者指定）

**重要**：生成檔案位置由呼叫者自行指定，通常生成到 Vue/React 專案的原始碼目錄，方便管理：

```
your-vue-project/
  src/
    generated/          # 使用者指定的輸出目錄
      schema.ts         # SCHEMA_VERSION + land/action/event ids
      defs.ts           # defs → TS types
      demo-game/
        index.ts        # DemoGameStateTree + re-exports
        bindings.ts     # actions/events/on 的 mapping
```

**使用範例**：

```bash
# 在 Vue/React 專案中執行
npx @swiftstatetree/sdk codegen \
  --input ./schema.json \
  --output ./src/generated

# 或使用 npm script
npm run codegen
```

**生成的檔案要 commit**：生成的檔案應該 commit 到 Vue/React 專案的 repository 中，確保版本控制和團隊協作。

### 命名規則（重點：function-based API）

Schema 裡常見是 `PascalCase`（如 `AddGold`, `ChatMessage`），但在 TS 端建議：
- `AddGold` → `actions.addGold(...)`
- `Chat` → `events.chat(...)`
- `ChatMessage` → `on.chatMessage(handler)`

空 payload 的處理（建議二選一）
- `actions.ping(): Promise<void>`（不接受參數）
- `actions.ping(payload?: never): Promise<void>`（保留 payload 概念但避免亂傳）

### 型別策略（先能用，再逐步加強）

分階段落地會比較順：
1. **Stage A：types/constants**：從 `defs` 生成 TS types + ids
   - 生成完整的 TypeScript 型別定義（例如 `DemoGameState`, `PlayerPrivateState`）
   - 確保可以直接存取深層屬性，例如 `state.players[0].name`
2. **Stage B：function wrappers**：生成 `StateTree` 類別（actions/events/on 全部變 function）
   - `tree.state` 有完整的型別資訊
   - `tree.actions.*` / `tree.events.*` / `tree.on.*` 都有型別提示
   - 實現 patch in-place 更新機制，讓框架可以追蹤深層變化
3. **Stage C（可選）：validators**：例如 Zod，用於 payload/runtime 驗證（CLI/Playground 特別有用）

---

## Workflow

### 現況（已可用）
1. `sdk/ts` 提供協議層核心，`Tools/CLI` / `Tools/Playground` 直接依賴 `@swiftstatetree/sdk` 共用實作。

### Roadmap（codegen）
1. 伺服端透過 `SchemaGen` 生成 `schema.json`
2. 在 Vue/React 專案中執行 codegen，生成到專案的原始碼目錄（例如 `src/generated/`）
   - 生成完整的 TypeScript 型別定義
   - 生成 `StateTree` 類別，提供有型別的 `state` 屬性
   - 實現 patch in-place 更新機制，適合 Vue、React 等框架使用
3. 應用層改用 generated 的 `StateTree` 取得型別安全 + 直覺 API
   - 各框架自行決定如何處理 reactive/ref（Vue 用 `reactive()`，React 用 `useState` 等）
4. 生成的檔案 commit 到專案 repository，確保版本控制

## 版本與相容性

- 生成檔輸出 `SCHEMA_VERSION` 常數，並在連線/join 時透過 metadata（或 handshake）回報給 server。
- **生成的檔案要 commit**：生成的檔案應該 commit 到 Vue/React 專案的 repository 中，確保：
  - 版本控制和團隊協作
  - CI/CD 流程不需要重新生成
  - 可以追蹤 schema 變更歷史

---

## 設計決策（已確認）

1. **`StateTree` 是否「一個 instance 對應一個 land」？**
   - ✅ 是，一個 instance 對應一個 land（目前 `StateTreeView` 是這樣）

2. **`StateTreeRuntime` 是否仍保留「同一個 WS 管多個 land view」？**
   - ✅ 是，`StateTreeRuntime` 仍保留「同一個 WS 管多個 land view」（生成的 `StateTree` 只是一層 wrapper）

3. **前端框架整合方式：**
   - ✅ 框架無關設計：生成的 `StateTree` 不依賴任何前端框架
   - ✅ Patch in-place 更新：state 更新採用 patch 機制，讓框架可以追蹤深層變化
   - ✅ 各框架自行決定 reactive 策略：Vue 可以用 `reactive()`，React 可以用 `useState` 等
   - ✅ 確保可以直接存取深層屬性，例如 `state.players[0].name`，並且有完整的型別提示

4. **你希望 actions/events/on 的輸出形狀是：**
   - ✅ `tree.actions.* / tree.events.* / tree.on.*`（已確認採用此方式）

5. **Codegen 工具位置：**
   - ✅ 放在 `sdk/ts/codegen/` 或 `sdk/ts/src/codegen/`（而不是 `scripts/`）

6. **生成檔案位置：**
   - ✅ 由呼叫者自行指定，通常生成到 Vue/React 專案的原始碼目錄（例如 `src/generated/`）
   - ✅ 生成的檔案要 commit 到專案 repository 中

---

## 相關文檔

- **[SCHEMA_DEFINITION.md](../protocol/SCHEMA_DEFINITION.md)**：Schema 格式定義（codegen 的輸入格式）
- **[DESIGN_CLIENT_SDK.md](./DESIGN_CLIENT_SDK.md)**：跨語言 SDK 架構設計和 codegen 理念（General）
  - Codegen 架構設計（JSON Schema 中間格式、多語言生成器架構等）
  - 生成器介面、模板引擎等通用設計
  - ⚠️ 注意：該文件中的 `StateTreeClient` API 設計範例已過時，請以本文檔為準


# Codegen 生成的測試工具使用指南

## 概述

當你運行 codegen 時，如果指定了 `--test-framework vitest`，會自動生成測試工具文件：

```
generated/
  demo-game/
    testHelpers.ts  # 自動生成的測試工具 ✅ 已生成
```

**✅ 已成功生成！** 文件位置：`src/generated/demo-game/testHelpers.ts`

## 生成的文件

### 1. `createMockState()` - 創建 Mock State

自動分析 State 類型結構，生成默認值：

```typescript
import { createMockState } from '../generated/demo-game/testHelpers'

// 使用默認值
const state = createMockState()

// 覆蓋特定字段
const state = createMockState({
  totalCookies: 500,
  ticks: 100
})
```

### 2. `createMockUseDemoGame()` - 創建 Mock Composable

自動生成完整的 mock composable，包含所有 actions 和 events：

```typescript
import { createMockUseDemoGame } from '../generated/demo-game/testHelpers'

const mockComposable = createMockUseDemoGame(initialState)
// mockComposable 包含：
// - state, currentPlayerID, isConnecting, isConnected, isJoined, lastError
// - clickCookie, buyUpgrade (所有 client events 和 actions)
// - connect, disconnect
```

### 3. `testWithDemoGamePlayer()` - 高級 Helper (Vitest)

簡化的測試設置：

```typescript
import { testWithDemoGamePlayer } from '../generated/demo-game/testHelpers'

// 一行代碼設置測試環境
const mockComposable = testWithDemoGamePlayer('player-1', {
  cookies: 100,
  name: 'Test Player',
  cookiesPerSecond: 5
})
```

## 使用範例

### 簡化後的測試代碼

**之前（手動維護）**：
```typescript
it('displays player info', async () => {
  const mockState = createMockState({
    players: {
      'player-1': createMockPlayer('player-1', { cookies: 100 })
    },
    privateStates: {
      'player-1': createMockPrivateState()
    }
  })
  const mockComposable = createMockUseDemoGame(mockState)
  const { useDemoGame } = await import('...')
  vi.mocked(useDemoGame).mockReturnValue(mockComposable)
  // ... 15+ 行設置代碼
})
```

**現在（Codegen 生成）**：
```typescript
it('displays player info', async () => {
  const mockComposable = testWithDemoGamePlayer('player-1', { cookies: 100 })
  const { useDemoGame } = await import('...')
  vi.mocked(useDemoGame).mockReturnValue(mockComposable)
  // 只需要 2-3 行！
})
```

## 優勢

1. **自動同步**：Schema 改變時，測試工具自動更新
2. **類型安全**：基於生成的類型，100% 類型匹配
3. **零維護**：不需要手動維護 mock 工具
4. **LLM 友好**：簡潔的 API，容易生成測試代碼

## 運行 Codegen

```bash
# 生成測試工具（Vitest）
npm run codegen

# 或手動指定
npx @swiftstatetree/sdk codegen \
  --input http://localhost:8080/schema \
  --output ./src/generated \
  --framework vue \
  --test-framework vitest
```

## 注意事項

- 生成的 `testHelpers.ts` 文件是自動生成的，不要手動編輯
- 如果 schema 改變，重新運行 codegen 即可更新測試工具
- 測試工具會自動包含所有 Actions 和 Events



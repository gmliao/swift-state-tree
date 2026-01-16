# SwiftStateTree E2E Test Coverage Analysis

## Core Features of SwiftStateTree

### 1. **Actions (HandleAction)** ✅ **FULLY COVERED**
- **Counter**: `IncrementAction` - 測試 action 執行和 response
- **Cookie**: `BuyUpgradeAction` - 測試成功和失敗情況
- **Coverage**: Action execution, response handling, error cases

### 2. **Client Events (HandleEvent)** ✅ **FULLY COVERED**
- **Cookie**: `ClickCookieEvent` - 測試 event 發送和 state 更新
- **Coverage**: Event sending, state mutation via events

### 3. **State Synchronization** ✅ **FULLY COVERED**
- **Counter**: 驗證 `count` 更新
- **Cookie**: 驗證 `totalCookies`, `privateStates` 更新
- **Coverage**: State sync via assert, diff updates

### 4. **Error Handling** ✅ **FULLY COVERED**
- **Cookie**: `expectError` 測試未註冊的 action
- **Coverage**: Error codes, error messages

### 5. **Multi-Encoding Support** ✅ **FULLY COVERED**
- `test:e2e:all` 測試 `jsonObject` 和 `opcodeJsonArray`
- **Coverage**: Different transport encoding modes

### 6. **Per-Player State (perPlayerSlice)** ⚠️ **PARTIALLY COVERED**
- **Cookie**: 驗證 `privateStates` 存在
- **Missing**: 未驗證 per-player state 的隔離性（多玩家場景）

### 7. **Broadcast State** ⚠️ **PARTIALLY COVERED**
- **Cookie**: 驗證 `totalCookies` (broadcast)
- **Missing**: 未測試多玩家同時看到相同的 broadcast state

### 8. **Tick Handler** ✅ **FULLY COVERED**
- **Cookie**: `test-tick.json` - 驗證 `ticks` 字段每 300ms 自動增加
- **Coverage**: Tick handler execution, automatic state updates

### 9. **OnJoin Handler** ✅ **FULLY COVERED**
- **Cookie**: `test-onjoin.json` - 驗證玩家加入時狀態初始化
- **Coverage**: OnJoin handler execution, player state initialization

### 10. **OnLeave Handler** ❌ **NOT TESTED**
- **Cookie**: 有 OnLeave handler（清理玩家狀態）
- **Missing**: 未測試玩家離開時的清理邏輯

### 11. **Multi-Player Scenarios** ❌ **NOT TESTED**
- **Missing**: 沒有測試多個客戶端同時連接
- **Missing**: 沒有測試玩家之間的狀態同步
- **Missing**: 沒有測試 broadcast vs per-player state 的區別

### 12. **StateSync Handler** ❌ **NOT TESTED**
- **Counter/Cookie**: 有 StateSync handler，但未驗證是否執行
- **Missing**: 未測試 sync 頻率或 sync callback

### 13. **Access Control** ❌ **NOT TESTED**
- **Missing**: 未測試 `CanJoin`, `MaxPlayers` 等訪問控制

### 14. **Lifetime Management** ❌ **NOT TESTED**
- **Missing**: 未測試 `DestroyWhenEmpty`, `OnFinalize` 等

## Summary

### ✅ Well Covered (7/14)
1. Actions (HandleAction)
2. Client Events (HandleEvent)
3. State Synchronization
4. Error Handling
5. Multi-Encoding Support
6. Tick Handler ✅ **NEW**
7. OnJoin Handler ✅ **NEW**

### ⚠️ Partially Covered (2/14)
8. Per-Player State (只驗證存在，未測試隔離性)
9. Broadcast State (只驗證值，未測試多玩家同步)

### ❌ Not Covered (5/14)
10. OnLeave Handler
11. Multi-Player Scenarios
12. StateSync Handler
13. Access Control
14. Lifetime Management

## Recommendations

### High Priority (Core Functionality)
1. **Multi-Player Test**: 測試多個客戶端同時連接，驗證狀態同步
2. ~~**Tick Test**: 驗證 tick handler 是否正確執行（例如 cookie 的 `ticks` 字段）~~ ✅ **DONE**
3. ~~**OnJoin Test**: 驗證玩家加入時狀態初始化~~ ✅ **DONE**

### Medium Priority (Important Features)
4. **OnLeave Test**: 驗證玩家離開時的清理邏輯
5. **Per-Player State Isolation**: 驗證不同玩家看到不同的 per-player state
6. **Broadcast State Sync**: 驗證多玩家同時看到相同的 broadcast state

### Low Priority (Edge Cases)
7. **StateSync Handler**: 測試 sync callback
8. **Access Control**: 測試 CanJoin, MaxPlayers
9. **Lifetime Management**: 測試 DestroyWhenEmpty

## Conclusion

現有的 counter 和 cookie 測試覆蓋了 **核心的 action/event/state sync 功能**，這是最重要的部分。但缺少：
- **多玩家場景測試**（這對於驗證狀態同步很重要）
- **生命週期測試**（OnJoin/OnLeave）
- **Tick 測試**（驗證自動更新）

建議添加這些測試來完善覆蓋率。

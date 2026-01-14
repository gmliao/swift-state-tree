# 自動化測試說明

## 前置條件

1. **啟動遊戲伺服器**
   ```bash
   cd Examples/GameDemo
   swift run GameServer
   ```
   伺服器應該會在 `ws://localhost:8080/game/hero-defense` 啟動

2. **生成代碼**
   ```bash
   cd Examples/GameDemo/CliClient
   npm run generate
   ```

## 運行自動化測試

```bash
cd Examples/GameDemo/CliClient
npm run test [wsUrl] [playerName] [roomId]
```

### 範例

```bash
# 使用默認設置
npm run test

# 指定伺服器 URL
npm run test ws://localhost:8080/game/hero-defense

# 指定玩家名稱和房間 ID
npm run test ws://localhost:8080/game/hero-defense auto-test-001 room-123
```

## 測試內容

自動化測試會執行以下操作：

1. **連接和加入遊戲**
   - 連接到 WebSocket 伺服器
   - 加入遊戲房間
   - 驗證連接成功

2. **開始遊戲**
   - 發送 `play` action
   - 驗證 action 執行成功

3. **自動移動測試**（每 3 秒）
   - 在固定範圍內隨機選擇位置
   - 發送 `moveTo` event
   - 驗證玩家位置是否更新

4. **自動動作測試**（每 5 秒）
   - 隨機選擇以下動作之一：
     - `shoot` - 向隨機位置射擊
     - `placeTurret` - 放置炮塔（如果有足夠資源）
     - `upgradeWeapon` - 升級武器（如果有足夠資源）

5. **狀態驗證**
   - 定期檢查遊戲狀態
   - 驗證玩家位置變化
   - 驗證資源變化
   - 驗證炮塔數量變化

## 測試時長

預設測試時長為 **30 秒**，可以在 `src/auto-test.ts` 中修改 `testDuration` 變數。

## 測試結果

測試結束後會顯示：
- ✅ 通過的測試數量
- ❌ 失敗的測試數量
- 📊 最終遊戲狀態

## 注意事項

- 確保伺服器正在運行
- 確保網路連接正常
- 測試會自動清理連接
- 如果測試失敗，檢查伺服器日誌以獲取更多資訊

# Mixed Encoding Test

這個測試腳本用於驗證在同一個 WebSocket 連線中混合使用 JSON（text frame）和 MessagePack（binary frame）的可行性。

## 使用方法

```bash
# 使用預設 URL (ws://localhost:8080/game)
npm run test-mixed-encoding

# 指定自訂 URL
npm run test-mixed-encoding -- --url ws://localhost:8080/game
```

## 測試內容

這個腳本會測試：

1. **發送 JSON 訊息（text frame）**
   - 建立 WebSocket 連線
   - 發送 JSON 格式的訊息（使用 text frame）
   - 驗證訊息成功發送

2. **發送二進制訊息（binary frame）**
   - 在同一個連線中發送二進制格式的訊息（使用 binary frame）
   - 驗證訊息成功發送

3. **接收並識別訊息類型**
   - 接收來自 server 的訊息
   - 正確識別 text frame 和 binary frame
   - 驗證兩種格式都能正確處理

## 預期結果

如果測試通過，應該看到：

```
✅ Send JSON (text frame): JSON message sent successfully
✅ Send Binary (binary frame): Binary message sent successfully
✅ Receive Text Frame: Successfully received and identified text frame
✅ Receive Binary Frame: Successfully received and identified binary frame

🎉 All tests passed! WebSocket supports mixed encoding.
   ✅ Text frames (JSON) work correctly
   ✅ Binary frames (MessagePack) work correctly
   ✅ Both can be used in the same connection
```

## 注意事項

- 這個測試使用簡單的二進制資料模擬 MessagePack（不是真正的 MessagePack 編碼）
- 主要目的是驗證 WebSocket 協議支援在同一個連線中混合使用 text 和 binary frame
- 實際的 MessagePack 實作需要正確的編碼/解碼邏輯

## 技術細節

- **Text Frame**: WebSocket 協議中的文字訊息類型，用於傳送 UTF-8 編碼的文字
- **Binary Frame**: WebSocket 協議中的二進制訊息類型，用於傳送任意二進制資料
- **混合使用**: 在同一個 WebSocket 連線中，可以交替使用 text 和 binary frame，協議會自動處理

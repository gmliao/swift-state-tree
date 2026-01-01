# 歸檔的 Benchmark 數據

本目錄包含已過時的 benchmark 數據文件。

## 過時原因

這些文件是 2025-12-31 之前的測試數據，具有以下問題：

1. **未明確區分編碼模式**：未明確區分 Serial/Parallel 編碼模式
2. **測試套件隔離問題**：可能在同一 process 中連續運行多個測試套件，存在狀態污染
3. **未啟用平行編碼優化**：未使用最新的平行編碼優化
4. **數據可能不穩定**：由於測試方法問題，數據可能不準確

## 文件列表

- `transport-sync-dirty-on.txt` - ⚠️ 過時（2025-12-31 之前）
- `transport-sync-dirty-off.txt` - ⚠️ 過時（2025-12-31 之前）
- `transport-sync-players-dirty-on.txt` - ⚠️ 過時（2025-12-31 之前）
- `transport-sync-players-dirty-off.txt` - ⚠️ 過時（2025-12-31 之前）

## 建議

**不建議使用這些舊版數據進行容量估算**。

請使用最新的 benchmark 數據（帶時間戳的文件），這些數據：
- 明確區分了 Serial/Parallel 編碼模式
- 每個測試套件在獨立 process 中運行
- 已啟用平行編碼優化
- 數據更穩定可靠

最新數據請參考 `PERFORMANCE_CAPACITY_ESTIMATION.md` 文檔。

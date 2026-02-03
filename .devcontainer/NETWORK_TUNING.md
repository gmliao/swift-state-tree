# Network Performance Tuning for Load Testing

## TCP 參數說明

本容器已配置以下 TCP 參數以優化 WebSocket 負載測試性能：

### 1. `net.ipv4.tcp_max_syn_backlog=4096`
**作用**: SYN 請求佇列大小  
**預設**: 1024  
**調整**: 4096  
**影響**: 允許更多並發連線建立，避免在大量連線時 SYN 丟失

### 2. `net.core.somaxconn=4096`
**作用**: Listen socket 的最大連線佇列  
**預設**: 128-1024 (視系統而定)  
**調整**: 4096  
**影響**: 允許 listen() 系統調用接受更多並發連線

### 3. `net.ipv4.tcp_tw_reuse=1`
**作用**: TIME_WAIT 狀態的連線重用  
**預設**: 0 (關閉)  
**調整**: 1 (啟用)  
**影響**: 加速連線清理，防止連續測試時 TIME_WAIT 堆積

### 4. `net.ipv4.tcp_fin_timeout=30`
**作用**: FIN-WAIT-2 狀態超時時間  
**預設**: 60 秒  
**調整**: 30 秒  
**影響**: 加速連線關閉流程，減少資源占用

## 測試場景需求

這些參數針對以下測試場景優化：
- **高並發連線**: 500-2000+ WebSocket 連線
- **連續測試**: 多次測試間隔短，需要快速清理 TIME_WAIT
- **大量房間**: 100-600+ 遊戲房間同時運行

## 如何重建容器應用設定

### 方法 1: VS Code / Cursor (推薦)
1. 按 `F1` 或 `Ctrl+Shift+P` 開啟命令面板
2. 輸入 "Dev Containers: Rebuild Container"
3. 等待容器重建完成 (約 2-3 分鐘)

### 方法 2: 命令列
```bash
# 停止當前容器
docker stop <container_id>

# 刪除容器
docker rm <container_id>

# VS Code 會自動重建容器（當你重新打開專案時）
```

## 驗證設定是否生效

重建容器後，執行：

```bash
cat /proc/sys/net/ipv4/tcp_max_syn_backlog
# 應該顯示: 4096

cat /proc/sys/net/core/somaxconn
# 應該顯示: 4096

cat /proc/sys/net/ipv4/tcp_tw_reuse
# 應該顯示: 1

cat /proc/sys/net/ipv4/tcp_fin_timeout
# 應該顯示: 30
```

## 注意事項

### Docker Desktop 限制
- 某些 Docker Desktop 版本可能不支援 `--sysctl` 參數
- 如果重建失敗，請檢查 Docker Desktop 版本和設定

### 權限需求
- 這些參數需要容器有足夠權限
- 如果使用 rootless Docker，可能無法設定某些參數

### 回退方案
如果容器無法啟動，可以：
1. 移除 `runArgs` 配置
2. 保持原有的自動調整機制（每次測試前檢查並調整）

## 效能對比

### 設定前 (動態調整)
```
每次測試啟動時：
✓ 檢查參數 (~0.1s)
✓ 調整參數 (~0.1s)
✓ 顯示調整訊息
```

### 設定後 (持久化)
```
容器啟動時：
✓ 參數已預設為優化值
✓ 測試腳本檢測到參數正確
✓ 顯示 "System parameters already optimal"
```

**效能提升**: 每次測試節省 ~0.2s（微小但乾淨）

## 相關檔案

- `/workspace/.devcontainer/devcontainer.json` - 容器配置
- `/workspace/Examples/GameDemo/ws-loadtest/scripts/run-ws-loadtest.sh` - 測試腳本（包含參數檢查）

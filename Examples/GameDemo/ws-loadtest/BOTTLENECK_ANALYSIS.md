# Transport Profiling 瓶頸分析報告

## 測試設定

- **100 rooms** (200 connections): `profile-bottleneck.json`，15+30+10 秒
- **300 rooms** (600 connections): `profile-300rooms.json`，20+40+15 秒

## 主要發現

### 1. Actor/Event-loop Lag 是關鍵指標

Transport profile 的 `lag_ms` 代表 profiler ticker 的漂移（預期 1000ms，實際偏差）：

| 負載 | lag p50 | lag p95 | lag p99 | lag max |
|------|---------|---------|---------|---------|
| 100 rooms | ~0.5ms | ~4ms | ~10ms | ~11ms |
| 300 rooms | 1.1ms | 4.1ms | **164.6ms** | **164.6ms** |

**300 rooms 時出現 164ms 的 lag 尖峰**，代表該秒內 actor/event-loop 被阻塞約 164ms。

### 2. Lag 尖峰與斷線的關聯

在 300-room 測試中：

- **ts 1770015258340**：`lag_ms: 164.56`（ticker 延遲 164ms）
- **下一秒 ts 1770015259340**：`disconnects: 600`（全部 600 連線斷開）
- **System metrics**：ts 1770015258 時 CPU 從 215% 降到 62%

推論：當 lag 飆高時，伺服器處理變慢，可能導致 client timeout 或連線異常，進而大量斷線。

### 3. 歷史 Scalability 結果（summary.json）

| Rooms | 結果 | RTT p95 | Update p95 | Disconnect Rate |
|-------|------|---------|------------|-----------------|
| 100 | ✅ Pass | 5–6ms | 104–105ms | 0% |
| 300 | ❌ Fail | 129ms | 151ms | - |
| 500 | ❌ Fail | 250ms | 221ms | 8.96% |
| 700 | ❌ Fail | 147ms | 214ms | 36.3% |

瓶頸約在 **300 rooms** 開始出現。

### 4. 瓶頸位置推論

- **decode/handle**：`handle_ms` 有樣本時約 p95 0.03ms，非常低
- **stateUpdates**：已補插桿（broadcast、syncState、firstSync、syncBroadcastOnly 路徑）
- **lag_ms**：最敏感，lag 飆高時伴隨斷線與 CPU 變化

**結論**：瓶頸較可能來自 **actor/event-loop 飽和**，而非單一 decode/handle/encode 路徑。可能原因包括：

1. **單一 process 負載過高**：300+ rooms、600+ connections 在同一 process
2. **Hummingbird/NIO event loop 競爭**：WebSocket、tick、sync 共用同一 executor
3. **TransportAdapter actor 排隊**：多個 Land 的 adapter 競爭同一個 global executor

### 5. 建議方向

1. **水平擴展**：多 process / 多機分散 rooms
2. **減少 per-room 負載**：例如降低 sync 頻率、縮小 state diff
3. **優化 broadcast 路徑**：300 rooms × 2 players × 10 sync/s ≈ 6000 sends/s
4. **監控 lag_ms**：在 production 用 `lag_ms` 作為 overload 預警

### 6. Profiling 快速驗證（100 / 200 rooms）

不需測到爆掉，100 和 200 rooms 即可看出趨勢：

```bash
cd Examples/GameDemo/ws-loadtest
./scripts/run-profile-100-200.sh
```

會產生 `results/profile-100/transport-profile.jsonl` 和 `results/profile-200/transport-profile.jsonl`。比較兩者的 `stateUpdates`、`encode_ms`、`send_ms`、`lag_ms` 即可判斷瓶頸在 encode 還是 send。

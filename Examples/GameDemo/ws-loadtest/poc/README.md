# Transport Actor vs Queue POC

獨立驗證：Actor 與 Queue 的 producer 端延遲差異。

## 情境

模擬 500 個 producer（TransportAdapter）同時向單一 sink 發送，每 producer 20 次，共 10,000 次。

## 執行

```bash
cd Examples/GameDemo/ws-loadtest/poc
swift run -c release
```

## 結果範例

```
                    Actor          Queue         Ratio
Latency p50 (ms):        0.286         0.000    285.61x
Latency p95 (ms):        0.377         0.012    31.45x
Latency p99 (ms):        0.459         0.053    8.65x
Throughput (msg/s):    1491389     3398566    2.28x
```

## 結論

Queue 明顯優於 Actor：
- **延遲**：Queue p95 約 0.01ms，Actor 約 0.38ms（約 31x）
- **吞吐**：Queue 約 2.3x 更高

Actor 的 serialization 造成 producer 排隊等候，是瓶頸來源。改用 lock-free queue 可顯著改善。

# EncodingBenchmark 測試結果比較

## 測試配置
- **編碼格式**: MessagePack (PathHash) 和 JSON Object
- **迭代次數**: 10 次 sync
- **測試時間**: 2026-01-24

---

## 1. 單房間模式 vs 多房間模式比較

### MessagePack (PathHash) 編碼

| 模式 | 配置 | 總玩家數 | 編碼方式 | 執行時間 | 總 Bytes | Bytes/Sync |
|------|------|---------|---------|---------|----------|------------|
| 單房間 | 10 players | 10 | Serial | 40.33ms | 41,000 | 4,100 |
| 單房間 | 10 players | 10 | Parallel | 35.01ms | 41,000 | 4,100 |
| 單房間 | 5 players | 5 | Parallel | 10.85ms | 10,780 | 1,078 |
| 多房間 | 2 rooms × 5 players | 10 | Serial | 11.61ms | 460 | 46 |
| 多房間 | 2 rooms × 5 players | 10 | Parallel | 13.39ms | 460 | 46 |
| 多房間 | 4 rooms × 5 players | 20 | Serial | 10.31ms | 920 | 92 |
| 多房間 | 4 rooms × 5 players | 20 | Parallel | 14.33ms | 920 | 92 |

### JSON Object 編碼

| 模式 | 配置 | 總玩家數 | 編碼方式 | 執行時間 | 總 Bytes | Bytes/Sync |
|------|------|---------|---------|---------|----------|------------|
| 單房間 | 10 players | 10 | Parallel | 16.88ms | 192,440 | 19,244 |
| 多房間 | 2 rooms × 5 players | 10 | Parallel | 6.31ms | 1,880 | 188 |

---

## 2. 並行編碼效能比較

### 單房間模式（10 players）

| 編碼方式 | 執行時間 | 總 Bytes | Speedup |
|---------|---------|----------|---------|
| Serial | 40.33ms | 41,000 | 1.00x |
| Parallel | 35.01ms | 41,000 | **1.15x** |

**觀察**: 並行編碼在單房間模式下有約 15% 的效能提升。

### 多房間模式（2 rooms × 5 players = 10 total）

| 編碼方式 | 執行時間 | 總 Bytes | Speedup |
|---------|---------|----------|---------|
| Serial | 11.61ms | 460 | 1.00x |
| Parallel | 13.39ms | 460 | **0.87x** (較慢) |

**觀察**: 在多房間模式下，並行編碼反而較慢。這可能是因為：
- 房間間並行處理的開銷
- 狀態較小（HeroDefenseState 初始狀態簡單）
- 並行編碼的 overhead 在小狀態下不划算

---

## 3. 多房間擴展性測試

### MessagePack (PathHash) - Parallel Encoding

| 房間數 | 每房間玩家數 | 總玩家數 | 執行時間 | 總 Bytes | Bytes/Sync | 每房間 Bytes/Sync |
|--------|------------|---------|---------|----------|------------|------------------|
| 2 | 5 | 10 | 13.39ms | 460 | 46 | 23 |
| 4 | 5 | 20 | 14.33ms | 920 | 92 | 23 |

**觀察**:
- 執行時間隨房間數增加而略微增加（13.39ms → 14.33ms，+7%）
- Bytes 隨房間數線性增加（460 → 920，2x）
- 每房間的 Bytes/Sync 保持穩定（約 23 bytes/sync）

---

## 4. 編碼格式比較

### 單房間模式（10 players, Parallel）

| 編碼格式 | 執行時間 | 總 Bytes | Bytes/Sync | vs JSON Object |
|---------|---------|----------|------------|----------------|
| JSON Object | 16.88ms | 192,440 | 19,244 | 100% |
| MessagePack (PathHash) | 35.01ms | 41,000 | 4,100 | **21.3%** |

**觀察**: MessagePack (PathHash) 比 JSON Object 節省約 78.7% 的 bytes。

### 多房間模式（2 rooms × 5 players, Parallel）

| 編碼格式 | 執行時間 | 總 Bytes | Bytes/Sync | vs JSON Object |
|---------|---------|----------|------------|----------------|
| JSON Object | 6.31ms | 1,880 | 188 | 100% |
| MessagePack (PathHash) | 13.39ms | 460 | 46 | **24.5%** |

**觀察**: MessagePack (PathHash) 比 JSON Object 節省約 75.5% 的 bytes。

---

## 5. 關鍵發現

### 狀態大小差異

**單房間模式（BenchmarkState）**:
- 10 players: 4,100 bytes/sync
- 使用簡化的 BenchmarkState，狀態較大

**多房間模式（HeroDefenseState）**:
- 2 rooms × 5 players: 46 bytes/sync（每房間 23 bytes/sync）
- 使用真實的 HeroDefenseState，但初始狀態較簡單
- 等待時間（200ms）可能不夠讓狀態充分發展（怪物生成、攻擊等）

### 並行處理效能

1. **房間內並行編碼**（單房間模式）:
   - 10 players: 1.15x speedup
   - 在較多玩家時有效

2. **房間間並行處理**（多房間模式）:
   - 執行時間隨房間數增加而略微增加
   - 並行處理的 overhead 在小狀態下可能不划算

3. **混合並行**（多房間 + 房間內並行）:
   - 2 rooms × 5 players: 並行編碼反而較慢
   - 可能是因為狀態較小，並行 overhead 超過收益

---

## 6. 建議

1. **增加等待時間**: 多房間模式可以增加等待時間，讓 HeroDefense 的 tick 產生更多狀態變化（怪物、攻擊等）
2. **測試更大狀態**: 測試更多玩家或更長時間運行，讓狀態更豐富
3. **測試不同編碼格式**: 比較所有編碼格式在多房間模式下的表現
4. **效能分析**: 分析並行編碼在多房間模式下的 overhead

---

## 測試命令範例

```bash
# 單房間模式
swift run EncodingBenchmark --format messagepack-pathhash --players 10 --iterations 10 --parallel true

# 多房間模式
swift run EncodingBenchmark --format messagepack-pathhash --rooms 4 --players-per-room 5 --iterations 10 --parallel true

# 比較序列 vs 並行
swift run EncodingBenchmark --format messagepack-pathhash --rooms 2 --players-per-room 5 --iterations 10 --compare-parallel

# 測試所有格式
swift run EncodingBenchmark --rooms 4 --players-per-room 5 --iterations 10 --all
```

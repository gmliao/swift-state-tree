[English](README.md) | [中文版](README.zh-TW.md)

# Hero Defense replay fixtures

錄製格式 2.5（#154）。讀取端會把較舊的錄製視為不支援而拒絕，因此每當錄製版本改變，都要用目前版本的
server 重新產生這些檔案。

| 檔案 | 使用者 | 產生方式 |
|------|--------|----------|
| `1-hero-defense.json` | replay land 清單、手動 replay | headless，逐位元組可重現（見下方） |
| `2-hero-defense.json` | replay land 清單、手動 replay（`Tools/CLI/scripts/playwright-replay-e2e.sh`） | headless，逐位元組可重現（見下方） |
| `3-hero-defense.json` | `HeroDefenseReplayStateParityTests`、`Tools/CLI/src/verify-replay-record.ts` | 由 client 驅動的 session，在 live GameServer 上錄製（見下方） |

## 1 與 2：headless

在 `Examples/GameDemo` 以 release 執行：

```bash
swift run -c release ReevaluationRunner --record --seed-id 1 --players 1 --move-every 30 --ticks 600 \
  --output reevaluation-records/1-hero-defense.json
swift run -c release ReevaluationRunner --record --seed-id 2 --players 1 --move-every 30 --ticks 520 \
  --output reevaluation-records/2-hero-defense.json
```

以 `swift run -c release ReevaluationRunner --input reevaluation-records/<file> --verify` 檢查每個檔案。

## 3：live 錄製

由 client 驅動的錄製，包含 lifecycle 的 join 與 leave、一個 `PlaceTurret` client event，以及
`PlayerShoot` / `TurretFire` server event。在 repository 根目錄執行：

```bash
cd Examples/GameDemo && ENABLE_REEVALUATION=true swift run GameServer   # localhost:8080
# 在另一個 shell
cd Tools/CLI && npx tsx src/cli.ts script -u ws://localhost:8080/game/hero-defense -l hero-defense \
  -s scenarios/game/test-replay-near-base-shoot.json --state-update-encoding messagepack
```

`--state-update-encoding` 必須與 server 的編碼一致（GameServer 預設為 messagepack）；CLI 自己的預設是
`jsonObject`。

情境結束時 client 離開，land 被銷毀，server 會寫出
`reevaluation-records/hero-defense-<timestamp>-<id>.json`。把該檔改名為 `3-hero-defense.json`，再以
`swift run -c release ReevaluationRunner --input reevaluation-records/3-hero-defense.json --verify` 檢查。

此目錄中其他的 `*.json` 是本機錄製，不納入版本控制。

# SwiftStateTree Playground

Vue 3 + Vuetify + TypeScript 的 SwiftStateTree WebSocket Playground

這是一個通用的測試工具，可以用來測試任何 SwiftStateTree 伺服器。只需要上傳對應的 JSON Schema 即可。

## 功能特色

- ✅ 上傳 JSON Schema 動態連線（不寫死）
- ✅ 狀態樹視覺化顯示
- ✅ 發送 Action 和 Event
- ✅ 即時訊息日誌
- ✅ 響應式設計

## 安裝

```bash
cd Examples/Playground
npm install
```

## 開發

```bash
npm run dev
```

應用會在 `http://localhost:3000` 啟動

## 建置

```bash
npm run build
```

## 使用方式

1. **上傳 Schema**
   - 點擊「上傳 JSON Schema」選擇 schema.json 檔案
   - 或直接在文字框中貼上 JSON Schema
   - 點擊「解析 Schema」

2. **連線**
   - 確認 WebSocket URL（預設: `ws://localhost:8080/game`）
   - 點擊「連線」

3. **查看狀態樹**
   - 連線後，狀態會自動顯示在「狀態樹」面板
   - 狀態會即時更新

4. **發送 Action**
   - 切換到「Actions」標籤
   - 選擇 Land 和 Action
   - 輸入 Payload（JSON 格式）
   - 點擊「發送 Action」

5. **發送 Event**
   - 切換到「Events」標籤
   - 選擇 Land
   - 輸入 Event 名稱和 Payload
   - 點擊「發送 Event」

6. **查看日誌**
   - 切換到「日誌」標籤
   - 查看所有收發的訊息

## 專案結構

```
Examples/SwiftStateTreePlayground/
├── src/
│   ├── components/       # Vue 組件
│   │   ├── ActionPanel.vue
│   │   ├── EventPanel.vue
│   │   ├── LogPanel.vue
│   │   └── StateTreeViewer.vue
│   ├── composables/       # Composition API
│   │   ├── useSchema.ts
│   │   └── useWebSocket.ts
│   ├── plugins/          # Vuetify 設定
│   │   └── vuetify.ts
│   ├── types/            # TypeScript 類型定義
│   │   ├── index.ts
│   │   ├── schema.ts
│   │   └── transport.ts
│   ├── App.vue
│   └── main.ts
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## 技術棧

- Vue 3 (Composition API)
- Vuetify 3
- TypeScript
- Vite
- Pinia


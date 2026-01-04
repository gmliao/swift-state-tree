# SwiftStateTree Admin

Vue 3 + Vuetify + TypeScript 的 SwiftStateTree 管理工具

這是一個 Web 介面的管理工具，用於管理 SwiftStateTree 伺服器上的 lands。

## 功能特色

- ✅ 列出所有 lands
- ✅ 查看 land 詳情和統計資訊
- ✅ 刪除 lands（需要 admin 權限）
- ✅ 系統統計資訊
- ✅ API Key 或 JWT Token 認證
- ✅ 響應式設計

## 安裝

```bash
cd Tools/Admin
npm install
```

## 開發

```bash
npm run dev
```

應用會在 `http://localhost:3001` 啟動

## 建置

```bash
npm run build
```

## 使用方式

### 1. 初始設定

1. 開啟應用後，點擊右上角的「設定」按鈕
2. 輸入伺服器 URL（例如: `http://localhost:8080`）
3. 選擇認證方式：
   - **API Key**: 輸入管理員 API Key
   - **JWT Token**: 輸入 JWT Token（需包含 admin 角色）
4. 點擊「儲存」

設定會自動儲存到瀏覽器的 localStorage，下次開啟時會自動載入。

### 2. 查看系統統計

在左側面板可以看到系統統計資訊：
- 總 Lands 數
- 總玩家數

點擊右上角的重新整理圖示可以更新統計資訊。

### 3. 管理 Lands

在右側面板可以看到所有 lands 的列表：

- **點擊 land ID**: 選中該 land（會以藍色背景標示）
- **點擊資訊圖示**: 查看該 land 的詳細資訊
- **點擊刪除圖示**: 刪除該 land（需要 admin 權限）

### 4. 查看 Land 詳情

點擊 land 的資訊圖示後，會彈出詳情對話框，顯示：
- Land ID
- 玩家數量
- 建立時間
- 最後活動時間

在詳情對話框中也可以直接刪除該 land。

### 5. 刪除 Land

刪除操作需要 admin 權限。系統會要求確認，因為此操作無法復原。

刪除後會自動重新載入 lands 列表和系統統計。

## API 端點

此工具使用以下 Admin API 端點：

- `GET /admin/lands` - 列出所有 lands
- `GET /admin/lands/:landID` - 獲取 land 統計資訊
- `DELETE /admin/lands/:landID` - 刪除 land（需要 admin 權限）
- `GET /admin/stats` - 獲取系統統計

所有端點都需要認證（API Key 或 JWT Token）。

## 認證方式

### API Key

在請求標頭中設定 `X-API-Key`。

### JWT Token

在請求標頭中設定 `Authorization: Bearer <token>`。

JWT Token 需要包含適當的管理員角色（admin、operator 或 viewer）。

## 專案結構

```
Tools/Admin/
├── src/
│   ├── components/       # Vue 組件
│   │   ├── LandList.vue
│   │   ├── LandDetails.vue
│   │   └── SystemStats.vue
│   ├── composables/      # Composition API
│   │   └── useAdminAPI.ts
│   ├── plugins/          # Vuetify 設定
│   │   └── vuetify.ts
│   ├── types/            # TypeScript 類型定義
│   │   └── admin.ts
│   ├── App.vue
│   └── main.ts
├── package.json
├── tsconfig.json
├── vite.config.ts
└── index.html
```

## 技術棧

- Vue 3 (Composition API)
- Vuetify 3
- TypeScript
- Vite
- Pinia

## 參考

此工具參考了 `Tools/Playground` 的結構和設計，但專注於管理功能而非 WebSocket 測試。

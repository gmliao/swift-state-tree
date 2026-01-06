# Hero Defense - Phaser Client

Vue 3 + Vuetify + Phaser 3.x 遊戲客戶端

## 安裝

```bash
npm install
```

## 開發

```bash
# 先確保 SDK 已構建
npm run predev

# 啟動開發伺服器
npm run dev
```

## 生成 TypeScript 綁定

在運行客戶端之前，需要先生成 schema 和 TypeScript 綁定：

```bash
# 方法 1: 完整流程（推薦）
# 會自動生成 schema.json 和 TypeScript 綁定
npm run generate

# 方法 2: 分步執行
npm run schema:generate  # 生成 schema.json
npm run codegen          # 生成 TypeScript 綁定（包含 Vue composable）

# 方法 3: 純 Phaser 版本（不使用 Vue）
# 如果只需要 Phaser 遊戲場景，不需要 Vue UI，可以使用：
npm run codegen:vanilla  # 只生成 framework-agnostic 的 StateTree class

# 方法 4: 從運行中的伺服器生成
# 1. 確保伺服器正在運行（swift run GameServer）
# 2. 生成綁定（不需要 schema.json）
npm run codegen:server

# 方法 5: 自動流程（開發時）
# predev 和 prebuild 會自動執行 schema:generate 和 codegen
npm run dev  # 會自動執行完整流程
```

### Framework 選擇

- **`--framework vue`**（預設）：生成 Vue composable (`useHeroDefense.ts`)，適合有 Vue UI 的專案
- **無 framework**：只生成 `HeroDefenseStateTree` class，適合純 Phaser 或 vanilla TypeScript 專案

## 構建

```bash
npm run build
```

## 使用

### 完整流程

1. **生成 schema 和 TypeScript 綁定**（首次使用或更新遊戲定義後）：
   ```bash
   # 方法 1: 一鍵生成（推薦）
   npm run generate  # 會自動執行 schema:generate 和 codegen
   
   # 方法 2: 分步執行
   npm run schema:generate  # 生成 schema.json
   npm run codegen          # 生成 TypeScript 綁定
   
   # 方法 3: 從運行中的伺服器
   # 先啟動伺服器，然後：
   npm run codegen:server
   ```

2. **啟動遊戲伺服器**：
   ```bash
   cd ../../
   swift run GameServer
   ```

3. **啟動客戶端**（會自動執行完整流程）：
   ```bash
   npm run dev  # 會自動執行 schema:generate 和 codegen
   ```

### 開發流程

- 修改遊戲定義（`Sources/GameContent/GameDefinitions.swift`）後：
  1. 重新生成：`npm run generate`（推薦，一鍵完成）
  2. 或直接運行 `npm run dev`（會自動執行完整流程）

4. 在瀏覽器中打開連接頁面，輸入：
   - WebSocket 網址：`ws://localhost:8080/game/hero-defense`
   - 玩家名稱：你的名稱
   - 房間 ID（選填）：留空則自動創建新房間

5. 點擊「開始遊戲」進入 Phaser 遊戲畫面

## 遊戲控制

- **方向鍵** 或 **WASD**：移動角色
- **空格鍵**：發送 PlayAction（增加分數）

# StateTree App 應用探索（概念草案）

> 說明：本文件僅為「如何把現有架構延伸到 App」的探索草案，尚未列入當前實作計畫。內容聚焦於可能的使用方式、可行性與擴充點，保留後續調整彈性。

## 適用場景（概念）

StateTree 架構在理論上可延伸到 App 開發，特別是：

- **即時推送類型的 App**：SNS（Twitter、Facebook）、即時通訊（WhatsApp、Telegram）、協作工具（Slack、Discord）
- **需要狀態同步的 App**：雲端筆記（Notion）、任務管理（Todoist）、雲端儲存（Dropbox）
- **複雜狀態管理的 App**：電商 App、社交 App、協作工具

## 核心優勢（假設導入後）

1. **單一狀態樹**：統一管理狀態，避免多套快取/資料源
2. **聲明式同步規則**：用 `@Sync` 描述同步策略，減少手寫同步邏輯
3. **一致通訊模式**：Action（請求）+ Event（推送），沿用現有伺服器模型
4. **型別安全 DSL**：若導入宏/代碼生成，可保持客戶端型別一致

## 狀態同步方式（推測使用方式）

若沿用現行伺服器設計，App 端可能以下列方式取得/更新狀態：

#### 1. 初始狀態獲取（Action）

```swift
// 用戶打開 Timeline
let response = await client.action(.fetchTimeline(page: 0))
// Response 包含完整的狀態快照
state.timeline = response.data.timeline
```

#### 2. 即時狀態更新（Event 推送）

```swift
// Server 推送新狀態
On(SNSServerEvent.newPost) { state, post, ctx in
    // 直接更新本地狀態
    state.timeline.insert(post, at: 0)
}

On(SNSServerEvent.postUpdated) { state, post, ctx in
    // 更新現有貼文（例如按讚數變化）
    if let index = state.timeline.firstIndex(where: { $0.id == post.id }) {
        state.timeline[index] = post
    }
}
```

**特點（暫定假設）**：
- **單一真實來源（Single Source of Truth）**：伺服器仍是權威，App 端持有裁切後的快取
- **聲明式同步**：`@Sync` 規則可望沿用，但需再定義適用於本地快取/離線場景的語義
- **事件驅動**：狀態變化來自 Action Response 和 Event 推送；離線/重連行為尚待設計

## 與目前主流做法比較

### 與常見做法的概念對比（簡表）

| 面向 | 傳統方案 (Redux/Vuex/MVVM/TCA) | StateTree 架構（假設導入 App） |
| ---- | ------------------------------ | ------------------------------- |
| 狀態來源 | 多處快取 + API + WebSocket 手動整合 | 單一 StateTree + `@Sync` 規則裁切 |
| 通訊 | API + WebSocket 需自行編排 | Action + Event 統一格式 |
| 型別安全 | 依語言/框架各自處理 | 期望透過宏/codegen 與伺服器型別一致 |
| 離線/重連 | 需自行處理 | 尚未設計，保留彈性 |

## SNS App 概念範例（簡化示意）

- **狀態樹概念**：以 `@Sync(.cache/.cloud/.local/.memory)` 描述 timeline、通知、草稿、UI 狀態的同步與快取；僅作概念示意，未在核心 DSL 落地。
- **Action/Event 概念**：Action 取得或更新 timeline/貼文；Server 以 Event 推送新貼文、通知、上線狀態。型別與 payload 細節留待未來決策。
- **離線/重連**：需額外設計（衝突解決、增量同步、重放策略），此處只說明可能的資料流。

## 其他應用場景（概念化）

- **即時通訊**：重點是訊息有序與已讀回報；可用 `@Sync(.local)` 存會話、`.memory` 存目前緩衝訊息，Event 用於新訊息/已讀回推。程式碼建議保持最小：單一 handler 接新訊息，單一 handler 處理已讀狀態。
- **協作/聊天室**：核心是頻道列表與目前頻道狀態；`@Sync(.cloud)` 放頻道資料、`.memory` 放當前頻道/在線成員，Event 推播上線/下線。程式碼以一個 switch 處理「userOnline/userOffline/channelUpdated」即可。
- **未來新增功能**：可先用文字 + 最小示意程式碼描述資料流，等決策後再展開完整型別。保持 handler 數量少、以概念 payload 命名即可。

## 新增 feature 的最小模板（示意）

- 以「狀態欄位 + Action + Event + Handler」的四步最小骨架描述，型別和 payload 可先用佔位符。
- `@Sync` 先寫最直覺策略（如 .broadcast/.memory），之後再調 perPlayer/masked。
- Handler 只保留一條 happy path，錯誤/重試與離線衝突留待後續。

```swift
// 狀態樹：用佔位型別 + 直覺 Sync 策略
@StateTree
struct FeatureState {
    @Sync(.broadcast) var items: [Item] = []  // 後續可改 perPlayer/masked
}

// Action：只列 case 名稱/參數，回傳先用佔位
enum FeatureRPC: Codable {
    case addItem(name: String)
}

// Event：先用單一 case 名稱 + 簡單 payload
enum FeatureEvent: Codable {
    case itemAdded(Item)
}

// DSL 骨架：一條 happy path，必要時再補錯誤處理/同步策略
let feature = Realm("feature-demo", using: FeatureState.self) {
    Action(FeatureAction.self) { state, action, ctx -> ActionResult in
        switch action {
        case .addItem(let name):
            let item = Item(id: UUID().uuidString, name: name)
            state.items.append(item)
            await ctx.sendEvent(.itemAdded(item), to: .all)
            return .success(.empty) // 後續可改成回傳明細或快照
        }
    }

    On(FeatureEvent.self) { state, event, ctx in
        switch event {
        case .itemAdded: break  // 先保留掛鉤，必要時再處理
        }
    }
}
```

- 若要新增更多 case，先列名稱/參數即可，細節等決策後再展開。

# StateTree App 開發應用指南

> StateTree 設計在 App 開發中的應用，特別是即時推送類型的 App（SNS、即時通訊、協作工具）

## 適用場景

StateTree 設計不僅適用於遊戲伺服器，也非常適合 App 開發，特別是：

- **即時推送類型的 App**：SNS（Twitter、Facebook）、即時通訊（WhatsApp、Telegram）、協作工具（Slack、Discord）
- **需要狀態同步的 App**：雲端筆記（Notion）、任務管理（Todoist）、雲端儲存（Dropbox）
- **複雜狀態管理的 App**：電商 App、社交 App、協作工具

## 核心優勢

1. **單一狀態樹**：取代 Redux/Vuex/TCA，統一管理所有狀態
2. **聲明式同步規則**：不需要寫分散的同步邏輯
3. **清晰的通訊模式**：RPC（API 呼叫）+ Event（即時推送）
4. **型別安全的 DSL**：編譯時檢查，避免執行時錯誤

## 狀態同步方式

### StateTree 的狀態同步方式

StateTree 採用兩種方式同步狀態：

#### 1. 初始狀態獲取（RPC）

```swift
// 用戶打開 Timeline
let response = await client.rpc(.fetchTimeline(page: 0))
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

**特點**：
- **單一真實來源（Single Source of Truth）**：本地 state 是權威狀態
- **聲明式同步**：`@Sync` 規則自動處理同步策略
- **事件驅動**：狀態變化來自 RPC Response 和 Event 推送

## 與目前主流做法比較

### vs Redux / Vuex

**Redux/Vuex：**
```javascript
// 需要手動管理分散的邏輯
const FETCH_TIMELINE = 'FETCH_TIMELINE'
const ADD_POST = 'ADD_POST'

function timelineReducer(state = initialState, action) {
    switch (action.type) {
        case FETCH_TIMELINE:
            return { ...state, timeline: action.payload }
        case ADD_POST:
            return { ...state, timeline: [action.payload, ...state.timeline] }
    }
}

// 手動處理 API 和 WebSocket
async function fetchTimeline() {
    const posts = await api.get('/timeline')
    dispatch({ type: FETCH_TIMELINE, payload: posts })
}

websocket.on('newPost', (post) => {
    dispatch({ type: ADD_POST, payload: post })
})
```

**StateTree：**
```swift
@StateTree
struct SNSAppState {
    // 聲明式同步規則：自動處理快取、雲端同步
    @Sync(.cache(ttl: .minutes(5)))
    @Sync(.cloud(endpoint: "/api/timeline"))
    var timeline: [Post] = []
}

// RPC 自動處理 API 呼叫和狀態更新
RPC(SNSRPC.fetchTimeline) { state, page, ctx -> RPCResponse in
    let posts = try await ctx.api.get("/timeline?page=\(page)")
    state.timeline = posts  // 自動更新，自動同步
    return .success(.timeline(posts))
}

// Event 自動處理即時推送
On(SNSServerEvent.newPost) { state, post, ctx in
    state.timeline.insert(post, at: 0)  // 自動更新，自動同步
}
```

### vs MVVM + Reactive Programming

**SwiftUI + Combine：**
```swift
class TimelineViewModel: ObservableObject {
    @Published var timeline: [Post] = []
    
    // 需要手動管理多個資料源
    func fetchTimeline() {
        // 檢查快取、API 呼叫、更新狀態、更新快取
        // WebSocket 處理、錯誤處理...
    }
}
```

**StateTree：**
```swift
// 聲明式定義，自動處理所有同步邏輯
@Sync(.cache(ttl: .minutes(5)))
@Sync(.cloud(endpoint: "/api/timeline"))
var timeline: [Post] = []
```

### vs TCA (The Composable Architecture)

**TCA：**
- 需要定義 State + Action + Reducer
- 手動處理副作用（API、WebSocket）
- 沒有自動同步策略

**StateTree：**
- 更簡潔的 DSL
- 混合模式：簡單用獨立 handler，複雜用統一 handler
- 聲明式同步規則

## SNS App 完整範例

### 狀態樹定義

```swift
@StateTree
struct SNSAppState {
    // 用戶資料（本地持久化 + 雲端同步）
    @Sync(.local(key: "user_profile"))
    @Sync(.cloud(endpoint: "/api/user"))
    var currentUser: User?
    
    // Timeline（快取 + 雲端同步）
    @Sync(.cache(ttl: .minutes(5)))
    @Sync(.cloud(endpoint: "/api/timeline"))
    var timeline: [Post] = []
    
    // 通知（即時推送，僅記憶體）
    @Sync(.memory)
    var notifications: [Notification] = []
    
    // 未讀數量（本地計算）
    @Sync(.memory)
    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }
    
    // 草稿（僅本地持久化）
    @Sync(.local(key: "drafts"))
    var drafts: [DraftPost] = []
    
    // UI 狀態（僅記憶體）
    @Sync(.memory)
    var uiState: UIState = UIState()
    
    // 連線狀態
    @Sync(.memory)
    var connectionStatus: ConnectionStatus = .disconnected
}

struct User: Codable {
    let id: String
    let username: String
    let avatar: URL?
    var followersCount: Int
    var followingCount: Int
}

struct Post: Codable, Identifiable {
    let id: String
    let authorID: String
    let content: String
    let createdAt: Date
    var likesCount: Int
    var commentsCount: Int
    var isLiked: Bool
}

struct Notification: Codable, Identifiable {
    let id: String
    let type: NotificationType
    let fromUser: User
    let postID: String?
    var isRead: Bool
    let createdAt: Date
}

enum NotificationType: Codable {
    case like(postID: String)
    case comment(postID: String)
    case follow
    case mention(postID: String)
}
```

### RPC 定義（API 呼叫）

```swift
enum SNSRPC: Codable {
    // 查詢操作
    case fetchTimeline(page: Int)
    case fetchUserProfile(userID: String)
    case fetchPost(postID: String)
    
    // 狀態修改（需要立即回饋）
    case createPost(content: String)
    case likePost(postID: String)
    case unlikePost(postID: String)
    case followUser(userID: String)
    case unfollowUser(userID: String)
    case markNotificationAsRead(notificationID: String)
}
```

### Event 定義（即時推送）

```swift
// Client -> Server Event
enum SNSClientEvent: Codable {
    case viewPost(postID: String)        // 追蹤用戶行為
    case scrollTimeline(position: Int)   // 分析用
    case heartbeat
}

// Server -> Client Event（即時推送）
enum SNSServerEvent: Codable {
    case newPost(Post)                   // 新貼文出現
    case postUpdated(Post)               // 貼文被更新（例如按讚數變化）
    case notification(Notification)      // 新通知
    case userOnline(userID: String)      // 用戶上線
    case userOffline(userID: String)     // 用戶下線
}

enum GameEvent: Codable {
    case fromClient(SNSClientEvent)
    case fromServer(SNSServerEvent)
}
```

### App 定義（DSL）

```swift
let snsApp = App("sns-app", using: SNSAppState.self) {
    Config {
        BaseURL("https://api.snsapp.com")
        WebSocketURL("wss://realtime.snsapp.com")
        CachePolicy(.expiresAfter(.minutes(5)))
    }
    
    AllowedClientEvents {
        SNSClientEvent.viewPost
        SNSClientEvent.scrollTimeline
        SNSClientEvent.heartbeat
    }
    
    // ========== RPC 處理（API 呼叫） ==========
    
    // 簡單的查詢：獨立 handler
    RPC(SNSRPC.fetchTimeline) { state, page, ctx -> RPCResponse in
        let posts = try await ctx.api.get("/timeline?page=\(page)")
        if page == 0 {
            state.timeline = posts  // 刷新
        } else {
            state.timeline.append(contentsOf: posts)  // 載入更多
        }
        return .success(.timeline(posts))
    }
    
    // 複雜的狀態修改：統一 handler
    RPC(SNSRPC.self) { state, rpc, ctx -> RPCResponse in
        switch rpc {
        case .createPost(let content):
            return await handleCreatePost(&state, content, ctx)
        case .likePost(let postID):
            return await handleLikePost(&state, postID, ctx)
        default:
            return await handleOtherRPC(&state, rpc, ctx)
        }
    }
    
    // ========== Event 處理（即時推送） ==========
    
    // 簡單的 Event：獨立 handler
    On(SNSClientEvent.heartbeat) { state, _, ctx in
        state.connectionStatus = .connected
    }
    
    // 複雜的 Event：統一 handler（處理即時推送）
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromServer(.newPost(let post)):
            // 新貼文推送到 Timeline
            state.timeline.insert(post, at: 0)
            if !ctx.isCurrentPage(.timeline) {
                showNotification("新貼文：\(post.content.prefix(50))...")
            }
            
        case .fromServer(.notification(let notification)):
            // 新通知推送到通知列表
            state.notifications.insert(notification, at: 0)
            updateBadge(count: state.unreadCount)
            
        case .fromClient(.viewPost(let postID)):
            // 追蹤用戶行為（分析用）
            analytics.track("view_post", params: ["post_id": postID])
            
        default:
            break
        }
    }
}

// Handler 函數
private func handleCreatePost(
    _ state: inout SNSAppState,
    _ content: String,
    _ ctx: AppContext
) async -> RPCResponse {
    let post = try await ctx.api.post("/posts", body: ["content": content])
    state.timeline.insert(post, at: 0)
    await ctx.sendEvent(.fromServer(.newPost(post)), to: .followers)
    return .success(.post(post))
}
```

## 其他應用場景

### 即時通訊 App（WhatsApp、Telegram）

```swift
@StateTree
struct ChatAppState {
    @Sync(.local) var conversations: [Conversation]
    @Sync(.memory) var messages: [Message]
    @Sync(.memory) var onlineUsers: Set<UserID>
}

On(SNSServerEvent.newMessage) { state, message, ctx in
    state.messages.append(message)
    playNotificationSound()
}
```

### 協作工具（Slack、Discord）

```swift
@StateTree
struct CollaborationAppState {
    @Sync(.cloud) var channels: [Channel]
    @Sync(.memory) var currentChannel: Channel?
    @Sync(.memory) var onlineUsers: Set<UserID>
}

On(SNSServerEvent.userOnline) { state, userID, ctx in
    state.onlineUsers.insert(userID)
}
```

## 跨平台實現：Android / 其他平台

### 實現可行性

StateTree 設計的核心理念是**語言無關的協議和架構**，可以跨平台實現：

1. **狀態樹結構**：可以用任何語言實現（Swift、Kotlin、TypeScript、Rust 等）
2. **同步規則**：`@Sync` 可以用 annotation/decorator 實現
3. **RPC + Event 協議**：使用標準的序列化格式（JSON、Protobuf、MsgPack）
4. **DSL**：每個語言可以用自己的方式實現（Kotlin DSL、TypeScript decorators）

### Android (Kotlin) 實現範例

#### 狀態樹定義

```kotlin
@StateTree
data class SNSAppState(
    // 用戶資料（本地持久化 + 雲端同步）
    @Sync(SyncPolicy.Local("user_profile"))
    @Sync(SyncPolicy.Cloud("/api/user"))
    var currentUser: User? = null,
    
    // Timeline（快取 + 雲端同步）
    @Sync(SyncPolicy.Cache(ttl = Duration.ofMinutes(5)))
    @Sync(SyncPolicy.Cloud("/api/timeline"))
    var timeline: List<Post> = emptyList(),
    
    // 通知（即時推送）
    @Sync(SyncPolicy.Memory)
    var notifications: List<Notification> = emptyList(),
    
    // UI 狀態
    @Sync(SyncPolicy.Memory)
    var uiState: UIState = UIState()
)

@StateTree
annotation class StateTree

enum class SyncPolicy {
    Local(val key: String),
    Cloud(val endpoint: String),
    Cache(val ttl: Duration),
    Memory
}
```

#### RPC 定義

```kotlin
sealed class SNSRPC {
    data class FetchTimeline(val page: Int) : SNSRPC()
    data class CreatePost(val content: String) : SNSRPC()
    data class LikePost(val postID: String) : SNSRPC()
}
```

#### DSL 定義（Kotlin DSL）

```kotlin
val snsApp = App("sns-app", SNSAppState::class) {
    config {
        baseURL = "https://api.snsapp.com"
        webSocketURL = "wss://realtime.snsapp.com"
    }
    
    allowedClientEvents {
        SNSClientEvent.ViewPost::class
        SNSClientEvent.Heartbeat::class
    }
    
    // RPC 處理
    rpc(SNSRPC.FetchTimeline::class) { state, rpc, ctx ->
        val posts = ctx.api.get("/timeline?page=${rpc.page}")
        state.timeline = if (rpc.page == 0) posts else state.timeline + posts
        RPCResponse.Success(RPCResultData.Timeline(posts))
    }
    
    // Event 處理
    on(SNSClientEvent.Heartbeat::class) { state, event, ctx ->
        state.connectionStatus = ConnectionStatus.Connected
    }
    
    on(GameEvent::class) { state, event, ctx ->
        when (event) {
            is GameEvent.FromServer -> when (event.serverEvent) {
                is SNSServerEvent.NewPost -> {
                    state.timeline = listOf(event.serverEvent.post) + state.timeline
                }
                is SNSServerEvent.Notification -> {
                    state.notifications = listOf(event.serverEvent.notification) + state.notifications
                }
            }
            is GameEvent.FromClient -> { /* 處理 client event */ }
        }
    }
}
```

### TypeScript / JavaScript 實現範例

#### 狀態樹定義

```typescript
@StateTree
class SNSAppState {
    @Sync({ local: { key: "user_profile" }, cloud: { endpoint: "/api/user" } })
    currentUser?: User;
    
    @Sync({ cache: { ttl: "5m" }, cloud: { endpoint: "/api/timeline" } })
    timeline: Post[] = [];
    
    @Sync({ memory: true })
    notifications: Notification[] = [];
}

function StateTree(target: any) { /* 實作 */ }
function Sync(options: SyncOptions) { /* 實作 */ }
```

#### DSL 定義

```typescript
const snsApp = App("sns-app", SNSAppState, {
    config: {
        baseURL: "https://api.snsapp.com",
        webSocketURL: "wss://realtime.snsapp.com"
    },
    
    allowedClientEvents: [
        SNSClientEvent.ViewPost,
        SNSClientEvent.Heartbeat
    ],
    
    rpc: {
        [SNSRPC.FetchTimeline]: async (state, rpc, ctx) => {
            const posts = await ctx.api.get(`/timeline?page=${rpc.page}`);
            state.timeline = rpc.page === 0 ? posts : [...state.timeline, ...posts];
            return { success: true, data: { timeline: posts } };
        }
    },
    
    events: {
        [SNSClientEvent.Heartbeat]: (state, event, ctx) => {
            state.connectionStatus = ConnectionStatus.Connected;
        },
        
        [GameEvent]: (state, event, ctx) => {
            if (event.type === "fromServer") {
                switch (event.serverEvent.type) {
                    case "newPost":
                        state.timeline = [event.serverEvent.post, ...state.timeline];
                        break;
                }
            }
        }
    }
});
```

### 跨平台實現的優勢

1. **統一的架構**：
   - 所有平台使用相同的設計理念
   - 狀態結構可以共享（使用相同的資料模型）
   - RPC/Event 協議可以跨平台

2. **協議層標準化**：
   - 序列化格式統一（JSON、Protobuf）
   - RPC 和 Event 的協議定義可以共享
   - 狀態樹結構可以跨平台共享

3. **開發體驗一致**：
   - iOS 和 Android 使用相似的 DSL
   - 學習成本低（一次學習，多平台適用）
   - 測試邏輯可以共享（狀態變化邏輯）

### 實現建議

1. **核心模組（語言無關）**：
   - 定義協議格式（JSON Schema、Protobuf）
   - 定義狀態樹結構（可以用 JSON Schema 描述）
   - 定義 RPC/Event 協議

2. **平台特定實現**：
   - **Swift**：使用 Swift Macros、Property Wrappers
   - **Kotlin**：使用 Kotlin DSL、Annotations
   - **TypeScript**：使用 Decorators、Type System

3. **共享層**：
   - 狀態模型定義（可以用 JSON Schema 生成）
   - RPC/Event 型別定義（可以用 Protobuf 生成）
   - 測試邏輯（狀態變化測試可以跨平台共享）

### 與現有跨平台方案比較

#### vs Flutter / React Native

**Flutter/RN：**
- 需要寫平台特定程式碼
- 狀態管理分散（Redux、MobX）

**StateTree：**
- 統一的架構設計
- 每個平台用原生語言實現（性能更好）
- 狀態管理集中且一致

#### vs KMM (Kotlin Multiplatform)

**KMM：**
- 共享業務邏輯
- UI 層還是需要平台特定

**StateTree：**
- 可以配合 KMM 使用
- 共享狀態樹定義和處理邏輯
- UI 層用各平台原生框架

## 實際場景對比

### 場景：用戶打開 Timeline

**目前主流做法需要寫：**
1. 檢查快取
2. 載入快取數據（如果有）
3. 發送 API 請求
4. 處理 Response
5. 更新狀態
6. 更新快取
7. 連接 WebSocket
8. 處理 WebSocket 事件
9. 更新狀態
10. 錯誤處理

**StateTree 只需要寫：**
1. 定義狀態樹（聲明同步規則）
2. 定義 RPC handler（處理 API）
3. 定義 Event handler（處理推送）

其他都是自動處理的。

這就是 StateTree 的核心優勢：**用狀態樹同步狀態，通過聲明式規則自動處理同步邏輯，而不是手動管理**。


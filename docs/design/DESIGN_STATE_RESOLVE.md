# Resolver：為 Action 提供上下文資料

## 前置條件

**重要**：實作 Resolver 機制前，必須先將 Action 和 Event handler 改為同步（sync）版本。

- Action handler 必須是 `sync` 的（不能使用 `async`）
- Event handler 必須是 `sync` 的（不能使用 `async`）
- 所有 resolve 操作都必須在 Action/Event 執行前完成
- 這確保了狀態變更的可預測性、可追蹤性與可回放性

---

## 目標

`@Resolvers` attribute 用於在 Action 或 Event handler 上宣告：

- 該 handler **會使用哪些 Resolver**；
- 只有宣告的 Resolver 才會被執行（安全機制）；
- Resolver 與 Output 型別的對應關係可從 `ContextResolver` protocol 自動推導。

**核心概念**：

- **Resolver 提供資料（ResolverOutput），不是 State**
- **ResolverOutput 不會進入 StateTree，不會 sync、不 diff、不持久化**
- **ResolverOutput 是上下文資料，供 Action 參考使用**
- **只有 StateNode 會進入 StateTree 並同步給客戶端**
- **只有放在 `@Resolvers` 上面的 Resolver 才會執行 resolve**

---

## 語法概觀

直接在 Action 或 Event handler 上使用 `@Resolvers` attribute：

```swift
@Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self)
struct GameLand {
    static var body: some LandDSL {
        AccessControl { ... }
        Rules { ... }
        Lifetime { ... }

        // Action handler 上宣告需要的 resolvers
        @Resolvers(UserProfileResolver, ProductInfoResolver)
        HandleAction(UpdateCart.self) { state, action, ctx in
            let profile = ctx.userProfile  // 同步存取，型別為 UserProfileInfo
            let productInfo = ctx.productInfo  // 同步存取，型別為 ProductInfo
            // 使用這些資料來更新 state
        }

        // Event handler 也可以使用
        @Resolvers(UserProfileResolver)
        HandleEvent(ClientEvents.ready) { state, event, ctx in
            let profile = ctx.userProfile  // 同步存取
            // ...
        }
    }
}
```

### 基本語法

```swift
@Resolvers(ResolverType1, ResolverType2, ...)
HandleAction(ActionType.self) { state, action, ctx in
    // 只有宣告的 resolver 才會被執行
    let info1 = ctx.info1  // ✅ 可以存取（例如 ctx.userProfile）
    let info2 = ctx.info2  // ✅ 可以存取（例如 ctx.productInfo）
    // let info3 = ctx.info3  // ❌ 編譯錯誤或 runtime 錯誤（未宣告）
}
```

- `ResolverType`：符合 `ContextResolver` 的 Resolver 型別
- Resolver 與 Output 型別的對應關係可從 protocol 定義自動推導：`UserProfileResolver.Output` → `UserProfileInfo`
- **只有宣告的 Resolver 才會執行 resolve**，未宣告的即使程式碼中使用了也不會執行（安全機制）

**預設行為**：所有宣告的 resolver 都會在 Action/Event 執行前並行 resolve

---

## ResolverOutput Protocol

所有 Resolver 輸出的資料型別必須符合 `ResolverOutput` protocol：

```swift
public protocol ResolverOutput: Codable & Sendable {
    // 目前為空 protocol，提供類型標記與未來擴展性
    // 所有 Resolver 輸出的資料型別都必須符合此 protocol
}
```

這個 protocol 的作用：

- **類型標記**：明確區分 ResolverOutput 和 StateNode
- **編譯時檢查**：確保只有符合 protocol 的型別才能作為 Resolver 的 Output
- **未來擴展**：未來可以在 protocol 中添加共用的方法或屬性
- **語意清晰**：與 `StateNodeProtocol` 對稱，提供一致的設計模式

---

## ResolverOutput vs StateNode：資料歸屬規則

| 類別               | 來源        | 會進 StateTree？ | 可改變同步行為？             | 用途               |
| ---------------- | --------- | ------------- | -------------------- | ---------------- |
| **StateNode**    | server 狀態 | ✔             | ✔（broadcast/private） | 權威狀態，需同步給客戶端    |
| **ResolverOutput** | 外部資料來源    | ✘             | ✘                    | 上下文資料，僅供 Action 參考 |

### 使用原則

- **同步要用的資料** → 一定要寫入 StateTree（StateNode）
- **Action 需要但不需同步的資料** → 放在 ResolverOutput
- **大量、頻繁變動資料（如股票報價）** → 不應進入 Tree（會爆 diff），用 Resolver 供應
- **永續或邏輯核心資料** → 一律進 Tree（需進 sync）

**範例**：

```swift
// ❌ 錯誤：把需要同步的資料放在 ResolverOutput
struct PlayerHP: ResolverOutput {
    let current: Int
    let max: Int
}

// ✅ 正確：需要同步的資料放在 StateNode
@StateTree
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
}

struct PlayerState: Codable {
    var hpCurrent: Int
    var hpMax: Int
}

// ✅ 正確：不需要同步的參考資料放在 ResolverOutput
struct ProductInfo: ResolverOutput {
    let id: ProductID
    let name: String
    let price: Decimal
    let stock: Int
}

// ✅ 正確：所有 ResolverOutput 都必須符合 ResolverOutput protocol
struct UserProfileInfo: ResolverOutput {
    let userID: UserID
    let name: String
    let email: String
    let level: Int
    let createdAt: Date
}
```

---

## 使用方式

所有在 `@Resolvers` 中宣告的 resolver 都會在 Action/Event 執行前並行 resolve：

```swift
@Resolvers(ProductInfoResolver, UserProfileResolver, ShopConfigResolver)
HandleAction(UpdateCart.self) { state, action, ctx in
    // 所有宣告的 resolver 在 Action 執行前就已經完成
    // ctx.productInfo、ctx.userProfile 等已有值
    let productInfo = ctx.productInfo  // 同步存取，型別為 ProductInfo
    let profile = ctx.userProfile      // 同步存取，型別為 UserProfileInfo
    
    // 使用已載入的資料來更新 state
    state.cart.items.append(CartItem(
        productID: action.productID,
        name: productInfo.name,
        price: productInfo.price
    ))
}
```

**行為**：

- 所有在 `@Resolvers` 中宣告的 resolver 都會在 Action/Event 執行前並行執行 `resolve()`（async 操作）
- `ctx.xxx` 的存取是同步的（資料已預先載入）
- **Runtime 可以並行執行所有宣告的 resolvers**，提升吞吐量
- **關鍵**：因為 Action 必須是 sync 的，所以所有 resolve 操作都必須在 Action 執行前完成

---

## 同步性分離原則

### 核心原則

**所有會改動 State 的操作必須是同步的，只有 Resolver（資料載入）操作可以是非同步的。**

這是為了確保狀態變更的可預測性、可追蹤性與可回放性。具體規則如下：

### 必須同步的操作（State Mutation）

以下操作**必須是同步的**，不能使用 `async`：

- **Action Handler**：`HandleAction` 內的所有邏輯（必須是 sync）
- **Event Handler**：`HandleEvent` 或 `On(ClientEvents)` 內的所有邏輯（必須是 sync）
- **Lifetime Handlers**：`OnJoin`、`OnLeave`、`OnTick`、`OnShutdown` 等（必須是 sync）
- **`ctx.xxx` 的存取**：同步存取，所有 resolve 操作都在 Action/Event 執行前完成（例如 `ctx.userProfile`、`ctx.productInfo`）

這些操作的共同特點是**會直接修改 State**，因此必須在單一同步執行緒中完成，確保狀態變更是原子性且可預測的。

### 允許非同步的操作（Data Resolution）

只有以下操作**允許使用 `async`**：

- **Resolver.resolve**：從外部資料來源（DB、Redis、API）載入資料

這些操作屬於**資料 IO**，不直接修改 state，因此可以非同步執行。

### 資料流設計

正確的模式是：

1. **非同步載入資料**（`resolve()`）→ 將結果放入 `LandContext`
   - 所有在 `@Resolvers` 中宣告的 resolver 都會在 Action/Event 執行前並行 resolve
2. **同步處理邏輯**（`HandleAction` / `OnJoin` / `OnTick`）→ 基於已載入的資料修改 state
   - `ctx.xxx` 的存取是 sync 的（資料已預先載入）
3. **Action 完成後** → StateTree 計算 diff → 同步給客戶端

這樣設計的好處：

- **可預測性**：state mutation 是同步的，不會有競態條件
- **可回放性**：同步的 state mutation 易於重現與除錯
- **效能**：所有宣告的 resolver 可以並行執行，但 state mutation 保證順序

### 完整實作範例

#### 1. 定義 ResolverOutput

```swift
// ResolverOutput 必須符合 ResolverOutput protocol
public struct ProductInfo: ResolverOutput {
    let id: ProductID
    let name: String
    let price: Decimal
    let stock: Int
    let description: String
}

public struct UserProfileInfo: ResolverOutput {
    let userID: UserID
    let name: String
    let email: String
    let level: Int
    let createdAt: Date
}
```

#### 2. 實作 ContextResolver

```swift
// ✅ 正確：ProductInfoResolver 實作 ContextResolver protocol
public struct ProductInfoResolver: ContextResolver {
    public typealias Output = ProductInfo
    
    // ✅ 允許 async：資料載入操作
    public static func resolve(
        ctx: ResolverContext
    ) async throws -> ProductInfo {
        // 從 Action payload 取得 productID
        let action = ctx.actionPayload as? UpdateCartAction
        let productID = action?.productID
        
        // 可以根據 currentState 決定載入策略（例如檢查快取）
        let state = ctx.currentState as? GameState
        if let productID = productID,
           let cachedProduct = state?.productCache[productID] {
            return cachedProduct
        }
        
        // 從外部系統載入資料（DB、Redis、API 等）
        guard let productID = productID else {
            throw ResolverError.missingParameter("productID")
        }
        let data = try await ctx.services.database.fetchProduct(by: productID)
        
        // 直接返回 Output
        return ProductInfo(
            id: data.id,
            name: data.name,
            price: data.price,
            stock: data.stock,
            description: data.description
        )
    }
}

// ✅ 正確：UserProfileResolver 實作 ContextResolver protocol
public struct UserProfileResolver: ContextResolver {
    public typealias Output = UserProfileInfo
    
    public static func resolve(
        ctx: ResolverContext
    ) async throws -> UserProfileInfo {
        // 可以從 Action/Event payload 取得 userID（如果有的話）
        let action = ctx.actionPayload as? GetUserProfileAction
        let event = ctx.eventPayload as? UserProfileRequestEvent
        let targetUserID = action?.userID ?? event?.userID ?? ctx.playerID
        
        // 可以根據 currentState 決定載入策略
        let state = ctx.currentState as? GameState
        if let cachedProfile = state?.userProfileCache[targetUserID] {
            return cachedProfile
        }
        
        // 從外部系統載入使用者資料
        let user = try await ctx.services.userService.getUser(by: targetUserID)
        
        // 直接返回 Output
        return UserProfileInfo(
            userID: user.id,
            name: user.name,
            email: user.email,
            level: user.level,
            createdAt: user.createdAt
        )
    }
}
```

#### 3. 在 Action 中使用

```swift
// ✅ 正確：HandleAction 必須 sync（會改動 state）
@Resolvers(ProductInfoResolver, UserProfileResolver)
HandleAction(UpdateCart.self) { state, action, ctx in
    // 同步處理邏輯並修改 state
    // ctx.productInfo 和 ctx.userProfile 已在 Action 執行前並行 resolve
    let productInfo = ctx.productInfo  // 同步存取，型別為 ProductInfo
    let profile = ctx.userProfile      // 同步存取，型別為 UserProfileInfo
    
    // 使用已載入的資料來更新 state
    state.cart.items.append(CartItem(
        productID: action.productID,
        name: productInfo.name,
        price: productInfo.price
    ))
    
    // 記錄使用者操作
    state.lastUpdatedBy = profile.userID
}

// ❌ 錯誤：HandleAction 不能 async
@Resolvers(ProductInfoResolver)
HandleAction(UpdateCart.self) { state, action, ctx async in
    // 這會破壞同步性原則
}
```

#### 4. ResolverContext 的定義（參考）

```swift
// ResolverContext 提供 resolver 執行時需要的輸入資訊
public struct ResolverContext: Sendable {
    public let landID: String
    public let playerID: PlayerID
    public let clientID: ClientID
    public let sessionID: SessionID
    
    // Action 或 Event 的參數（payload）
    public let actionPayload: Any?        // Action 的 payload（如果是 Action handler）
    public let eventPayload: Any?         // Event 的 payload（如果是 Event handler）
    
    // 目前的 State（只讀）
    public let currentState: any StateNodeProtocol
    
    // 可用的服務（database, cache 等）
    public let services: LandServices
}
```

**使用範例**：

```swift
public struct ProductInfoResolver: ContextResolver {
    public typealias Output = ProductInfo
    
    public static func resolve(
        ctx: ResolverContext
    ) async throws -> ProductInfo {
        // 從 Action payload 取得 productID
        let action = ctx.actionPayload as? UpdateCartAction
        guard let productID = action?.productID else {
            throw ResolverError.missingParameter("productID")
        }
        
        // 可以根據 currentState 決定載入策略（例如檢查快取）
        let state = ctx.currentState as? GameState
        if let cachedProduct = state?.productCache[productID] {
            return cachedProduct
        }
        
        // 從外部系統載入資料
        let data = try await ctx.services.database.fetchProduct(by: productID)
        return ProductInfo(
            id: data.id,
            name: data.name,
            price: data.price,
            stock: data.stock,
            description: data.description
        )
    }
}
```

---

## 與 ContextResolver 的對應

`@Resolvers(ResolverType)` 要求 Resolver 實作下列介面：

```swift
public protocol ContextResolver {
    associatedtype Output: ResolverOutput

    // ✅ 允許 async：資料載入操作
    static func resolve(
        ctx: ResolverContext
    ) async throws -> Output
}
```

**注意**：`Output` 必須符合 `ResolverOutput` protocol，確保類型安全與語意清晰。

**ResolverContext 提供的資訊**：

- **actionPayload / eventPayload**：Resolver 可以從 Action 或 Event 的 payload 中取得參數，例如 `productID`、`userID` 等
- **currentState**：Resolver 可以讀取當前的 State，用於：
  - 檢查快取（例如 `state.productCache[productID]`）
  - 根據 State 決定載入策略
  - 避免不必要的資料載入
- **services**：提供資料庫、快取等外部服務的存取
- **playerID / clientID / sessionID**：提供請求相關的識別資訊

**自動推導機制**：

- Resolver 與 Output 型別的對應關係可從 protocol 定義自動推導
- 例如：`UserProfileResolver.Output` → `UserProfileInfo`
- Runtime 會根據 `@Resolvers` 宣告自動建立對應關係

**安全機制**：

- **只有放在 `@Resolvers` 上面的 Resolver 才會執行 resolve**
- 即使程式碼中使用了 `ctx.xxx`，如果沒有在 `@Resolvers` 中宣告對應的 Resolver，該 resolve 不會執行
- 這提供了編譯時或 runtime 的類型檢查與安全保證

**LandContext 自動生成機制**：

Runtime 會根據 `@Resolvers` 宣告自動生成 `LandContext`：

1. **解析 `@Resolvers` 宣告**：
   - Runtime 讀取 `@Resolvers(ProductInfoResolver, UserProfileResolver)` 宣告
   - **重要**：`LandContext` **只會包含在 `@Resolvers` 中宣告的 resolver 的 output**，不是所有可能的 resolver
   - 根據每個 Resolver 的 `Output` associatedtype 自動推導欄位名稱
   - 例如：`ProductInfoResolver.Output = ProductInfo` → `ctx.productInfo`
   - 例如：`UserProfileResolver.Output = UserProfileInfo` → `ctx.userProfile`

2. **建立 ResolverContext**：
   - Runtime 為每個宣告的 resolver 建立 `ResolverContext`，包含：
     - `actionPayload`：當前 Action 的 payload
     - `eventPayload`：當前 Event 的 payload（如果是 Event handler）
     - `currentState`：當前的 State（只讀）
     - `services`：可用的服務
     - `playerID`、`clientID`、`sessionID` 等請求資訊

3. **並行執行 resolve**：
   - **只有宣告的 resolver** 並行執行 `resolve(ctx: ResolverContext)`
   - 每個 resolver 返回對應的 `Output`

4. **自動填充 LandContext**：
   - Runtime 將 resolver 的輸出自動放入 `LandContext` 的對應欄位
   - 例如：`ProductInfoResolver.resolve()` 的結果 → `ctx.productInfo`
   - 例如：`UserProfileResolver.resolve()` 的結果 → `ctx.userProfile`
   - **未宣告的 resolver 的 output 不會出現在 `LandContext` 中**

5. **提供給 Action/Event handler**：
   - Action/Event handler 接收的 `ctx` 參數就是這個自動生成的 `LandContext`
   - 可以直接使用 `ctx.productInfo`、`ctx.userProfile` 等欄位（同步存取）
   - 如果嘗試存取未宣告的 resolver output（例如 `ctx.otherInfo`），會產生編譯錯誤或 runtime 錯誤

Runtime 會依據這些設定運作：

- 建立 `LandContext` 時，為每個在 `@Resolvers` 中宣告的 resolver 準備 slot
- Action 執行時，所有在 `@Resolvers` 中宣告的 resolver 都已 resolve 完成，可直接使用對應的 Output（例如 `ctx.userProfile`）
- Resolver 的 `resolve()` 是 async，但 Action 執行本身是 sync

---

## 完整數據流：Resolver → Action → StateTree → Client

下列圖示展示 Resolver、Action、State 與 Client 的完整互動流程：

```
Client → Action(payload)
           |
           v
   [Resolver Binding]
           |
   建立 ctx（所有宣告的 resolver 並行 resolve）
           |
           v
   [Action Execution]
       • 讀取 state
       • 讀取 payload
       • 讀取 ctx.xxx（例如 ctx.userProfile、ctx.productInfo）
       • 決定要不要更新 StateTree
           |
           v
       [StateTree Updated → diff]
           |
           v
        [Sync Engine]
           |
           v
       相關 Client 自動收到更新
```

### 流程說明

1. **Client → Action(payload)**
   - Client 發送 Action 請求，包含 payload 資料

2. **Resolver Binding**
   - Runtime 根據 `@Resolvers` 宣告，識別需要執行的 resolver
   - 只有宣告的 resolver 才會執行（安全機制）

3. **自動建立 LandContext（所有宣告的 resolver 並行 resolve）**
   - Runtime **自動建立 `LandContext`**，包含：
     - 基本資訊：`landID`、`playerID`、`clientID`、`sessionID` 等
     - Resolver 輸出欄位：根據 `@Resolvers` 宣告自動生成（例如 `productInfo`、`userProfile`）
   - 為每個宣告的 resolver 建立 `ResolverContext`（包含 `actionPayload`、`eventPayload`、`currentState` 等）
   - 所有在 `@Resolvers` 中宣告的 resolver 並行執行 `resolve(ctx: ResolverContext)`（async 操作）
   - Runtime **自動將 resolver 的輸出填入 `LandContext` 的對應欄位**
     - 例如：`ProductInfoResolver.resolve()` 的結果 → `ctx.productInfo`
     - 例如：`UserProfileResolver.resolve()` 的結果 → `ctx.userProfile`
   - **關鍵**：所有 resolve 操作都在 Action 執行前完成，確保 Action 是 sync 的

4. **Action Execution（同步執行）**
   - 讀取 `state`：當前的 StateTree 狀態
   - 讀取 `payload`：Action 攜帶的資料
   - 讀取 `ctx.xxx`：已預先載入的 ResolverOutput 資料（同步存取，例如 `ctx.userProfile`）
   - 執行業務邏輯，決定如何變更 StateTree
   - 直接變更 `state` parameter（`inout`）

5. **StateTree Updated → diff**
   - Action 完成後，StateTree 包含最新狀態
   - 這是「單一信源」(source of truth)
   - 計算與舊狀態的 diff

6. **Sync Engine**
   - 處理 diff，決定哪些 Client 需要收到更新
   - 根據同步策略（broadcast/private）推送更新

7. **相關 Client 自動收到更新**
   - 接收 diff 推送，更新本地狀態
   - 重新渲染 reactive UI

### 關鍵設計特點

- **類型安全**：所有 ResolverOutput 必須符合 `ResolverOutput` protocol，與 `StateNodeProtocol` 對稱，提供編譯時類型檢查。
- **Resolver 與 Action 分離**：Action 不直接查資料，透過 Resolver 機制取得；所有宣告的 resolver 都會在 Action 執行前並行 resolve。
- **同步性分離**：Resolver（資料載入）可以是 async，但 Action（狀態變更）必須是 sync，確保狀態變更的可預測性。
- **安全機制**：只有放在 `@Resolvers` 上面的 Resolver 才會執行 resolve。
- **自動推導**：Resolver 與 Output 型別的對應關係可從 `ContextResolver` protocol 自動推導（透過 `Output` associatedtype）。
- **Inout Mutation**：Action 直接修改 State，簡潔且高效。
- **Diff 推播**：只把變化傳給 client，節省頻寬。
- **並行化**：所有宣告的 resolver 可並行執行，提升吞吐；但 Action 執行本身是同步且順序的。

---

---

## 三個關鍵點一次收斂

下列為可直接摘錄到設計文件或 README 的精簡說明。

1. **Resolver**

   - **定義**：Resolver 是負責 `resolve()` 出某個 Output 的型別，負責從外部系統載入資料並提供給 Action 使用。
   - **宣告方式**：透過 `@Resolvers(ResolverType1, ResolverType2, ...)` 在 Action 或 Event handler 上宣告需要的 resolvers。
   - **核心特性**：ResolverOutput 不會進入 StateTree，不會 sync，僅供 Action 參考使用。
   - **安全機制**：只有放在 `@Resolvers` 上面的 Resolver 才會執行 resolve。

2. **Resolver 執行模式**

   - **語意**：所有在 `@Resolvers` 中宣告的 resolver 都會在 Action/Event 執行前並行 resolve。所有 resolve 操作都在 Action/Event 執行前完成，確保 Action/Event 是 sync 的。
   - **範例**：
     ```swift
     @Resolvers(ProductInfoResolver, UserProfileResolver)
     HandleAction(UpdateCart.self) { state, action, ctx in
         // 所有宣告的 resolver 在 Action 執行前已並行 resolve
         let productInfo = ctx.productInfo  // 同步存取，型別為 ProductInfo
         let profile = ctx.userProfile      // 同步存取，型別為 UserProfileInfo
     }
     ```

---

### 精要（可直接引用）

- **ResolverOutput Protocol**：所有 Resolver 輸出的資料型別必須符合 `ResolverOutput` protocol（繼承 `Codable & Sendable`），提供類型標記、編譯時檢查與未來擴展性，與 `StateNodeProtocol` 對稱。
- **Resolver**：每個有業務語意的 Output 型別可以綁定一個 Resolver，負責從外部系統載入資料並提供給 Action 使用。ResolverOutput 不會進入 StateTree，不會 sync。只有放在 `@Resolvers` 上面的 Resolver 才會執行 resolve。
- **Resolver 執行**：所有在 `@Resolvers` 中宣告的 resolver 都會在 Action/Event 執行前並行 resolve。所有 resolve 操作都在 Action/Event 執行前完成，確保 Action/Event 是 sync 的。
- **自動推導**：Resolver 與 Output 型別的對應關係可從 `ContextResolver` protocol 自動推導（透過 `Output` associatedtype），`Output` 必須符合 `ResolverOutput` protocol。

# Resolver 機制使用指南

## 錯誤處理

當 resolver 執行時遇到錯誤（例如找不到物品、資料載入失敗等），應該拋出 `ResolverError` 或自定義錯誤。錯誤會被自動包裝在 `ResolverExecutionError` 中，包含失敗的 resolver 名稱，方便除錯。

### 範例：處理找不到物品的情況

```swift
struct ProductInfoResolver: ContextResolver {
    typealias Output = ProductInfo
    
    static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
        // 從 Action payload 取得 productID
        let action = ctx.actionPayload as? UpdateCartAction
        guard let productID = action?.productID else {
            throw ResolverError.missingParameter("productID")
        }
        
        // 檢查快取
        let state = ctx.currentState as? GameState
        if let cachedProduct = state?.productCache[productID] {
            return cachedProduct
        }
        
        // 從資料庫載入
        do {
            let data = try await ctx.services.database.fetchProduct(by: productID)
            return ProductInfo(
                id: data.id,
                name: data.name,
                price: data.price,
                stock: data.stock
            )
        } catch DatabaseError.notFound {
            // 物品不存在
            throw ResolverError.dataLoadFailed("Product not found: \(productID)")
        } catch {
            // 其他資料庫錯誤
            throw ResolverError.dataLoadFailed("Failed to load product: \(error.localizedDescription)")
        }
    }
}
```

### 錯誤處理流程

1. **Resolver 拋出錯誤**：當 resolver 遇到問題時（如找不到物品），拋出 `ResolverError` 或自定義錯誤
2. **自動包裝**：錯誤會被自動包裝在 `ResolverExecutionError.resolverFailed` 中，包含：
   - `name`: 失敗的 resolver 名稱（如 "ProductInfoResolver"）
   - `underlyingError`: 原始的錯誤
3. **並行執行處理**：如果多個 resolver 並行執行，當其中一個失敗時：
   - 所有剩餘的 resolver 會被自動取消
   - 錯誤會立即傳播，導致整個 action 處理失敗
4. **Action Handler 接收錯誤**：Action handler 不會執行，錯誤會傳播到調用者

### 錯誤類型

#### ResolverError

預定義的 resolver 錯誤類型：

```swift
public enum ResolverError: Error, Sendable {
    case missingParameter(String)      // 缺少必要參數
    case dataLoadFailed(String)        // 資料載入失敗
    case cancelled                     // 執行被取消
    case custom(String)                // 自定義錯誤
}
```

#### ResolverExecutionError

執行器層級的錯誤，包含 resolver 名稱：

```swift
public enum ResolverExecutionError: Error, Sendable {
    case resolverFailed(name: String, underlyingError: Error)
}
```

### 在 Action Handler 中處理錯誤

Action handler 不需要特別處理 resolver 錯誤，因為如果 resolver 失敗，handler 根本不會執行。錯誤會自動傳送到客戶端：

```swift
// ✅ 正確：如果 ProductInfoResolver 失敗，這個 handler 不會執行
// 錯誤會自動發送 ErrorPayload 到客戶端
HandleAction(UpdateCart.self, resolvers: ProductInfoResolver.self) { state, action, ctx in
    // 只有在所有 resolvers 成功後才會執行到這裡
    let productInfo = ctx.productInfo  // 保證有值
    // ...
}
```

**Action 錯誤處理流程**：
1. Resolver 失敗 → 錯誤被包裝在 `ResolverExecutionError` 中
2. Action handler 不會執行
3. TransportAdapter 捕獲錯誤並發送 `ErrorPayload` 到客戶端
4. 客戶端收到錯誤訊息，包含錯誤碼和詳細資訊

### 在 Event Handler 中處理錯誤

Event handler 也可以拋出錯誤（例如 resolver 失敗），錯誤會自動傳送到客戶端：

```swift
// ✅ 正確：Event handler 可以 throws
HandleEvent(ChatEvent.self) { state, event, ctx in
    // 如果處理失敗，可以拋出錯誤
    guard let message = event.message, !message.isEmpty else {
        throw ResolverError.missingParameter("message")
    }
    state.messages.append(message)
}
```

**Event 錯誤處理流程**：
1. Event handler 或 resolver 失敗 → 拋出錯誤
2. TransportAdapter 捕獲錯誤並發送 `ErrorPayload` 到客戶端
3. 客戶端收到錯誤訊息，包含錯誤碼和詳細資訊
4. Event 不會執行（狀態不會被修改）

### 錯誤處理最佳實踐

1. **提供清晰的錯誤訊息**：使用描述性的錯誤訊息，方便除錯
   ```swift
   throw ResolverError.dataLoadFailed("Product not found: \(productID)")
   ```

2. **利用快取避免不必要的錯誤**：在 resolver 中先檢查快取
   ```swift
   if let cached = state?.cache[key] {
       return cached
   }
   ```

3. **區分不同類型的錯誤**：使用不同的 `ResolverError` case 來區分錯誤類型
   ```swift
   guard let productID = action?.productID else {
       throw ResolverError.missingParameter("productID")
   }
   ```

4. **記錄錯誤詳情**：錯誤訊息會自動包含 resolver 名稱，方便追蹤問題

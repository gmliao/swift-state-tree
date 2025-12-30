# Linux 容器開發環境

這個目錄包含 VS Code Dev Container 配置，用於在 Linux 環境中測試 SwiftStateTree 的編譯。

## 使用方法

### 方法 1：使用 VS Code Dev Containers（推薦）

1. 安裝 [Dev Containers 擴展](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. 在 VS Code 中按 `F1` 或 `Cmd+Shift+P`
3. 選擇 **"Dev Containers: Reopen in Container"**
4. VS Code 會自動構建並啟動 Linux 容器
5. 在容器中運行：
   ```bash
   swift build
   swift test
   ```

### 方法 2：使用 Docker 命令

```bash
# 構建並測試
./Tools/linux-build-test.sh

# 或手動構建
docker build -f Dockerfile.linux -t swiftstatetree-linux-test .

# 運行容器
docker run -it swiftstatetree-linux-test /bin/bash

# 在容器中測試
docker run swiftstatetree-linux-test swift test
```

## 注意事項

⚠️ **重要**：目前 `Package.swift` 中指定了 `platforms: [.macOS(.v14)]`。

**Swift Package Manager 不支援 `.linux` 平台聲明**，要測試 Linux 編譯，可以：

1. **臨時註釋掉 `platforms` 聲明**（見下方「關於 Linux 編譯測試」）
2. **或保持原樣**，使用條件編譯處理平台差異
3. **檢查代碼**：確保沒有 macOS 特定的 API，所有依賴都支援 Linux

## 關於 Linux 編譯測試

⚠️ **重要說明**：根據 Swift Package Manager 官方文檔，**不支援直接聲明 `.linux` 平台**。

### 正確的做法

Swift Package Manager 不支援 `.linux` 作為 `SupportedPlatform`。要支援 Linux，有兩種方式：

#### 方法 1：移除 `platforms` 限制（推薦用於 Linux 測試）

在 Linux 容器中測試時，可以**臨時移除或註釋掉 `platforms` 聲明**：

```swift
let package = Package(
    name: "SwiftStateTree",
    // 註釋掉 platforms 以支援所有平台（包括 Linux）
    // platforms: [
    //     .macOS(.v14)
    // ],
    products: [
        // ...
    ]
)
```

**注意**：移除 `platforms` 可能會導致版本衝突，因為依賴可能要求特定平台版本。如果遇到錯誤，需要調整依賴的版本要求。

#### 方法 2：保留 `platforms` 但使用條件編譯

保持 `platforms: [.macOS(.v14)]` 不變，在代碼中使用條件編譯處理平台差異：

```swift
#if os(Linux)
// Linux 特定的代碼
#elseif os(macOS)
// macOS 特定的代碼
#endif
```

### 測試步驟

1. **進入容器**（使用 VS Code Dev Containers 或 Docker）
2. **臨時修改 `Package.swift`**（可選）：
   - 註釋掉 `platforms` 聲明以測試 Linux 編譯
   - 或保持原樣，使用條件編譯處理平台差異
3. **編譯測試**：
   ```bash
   swift build
   swift test
   ```
4. **如果遇到錯誤**：
   - 檢查是否有 macOS 特定的 API
   - 檢查依賴是否支援 Linux（Hummingbird 等應該都支援）
   - 使用條件編譯處理平台差異

### 參考資料

- [Swift Package Manager 官方文檔](https://www.swift.org/package-manager/)
- Swift Package Manager 不支援 `.linux` 平台聲明
- 要支援 Linux，建議移除 `platforms` 限制或使用條件編譯

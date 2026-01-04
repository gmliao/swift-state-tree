[English](land-dsl.md) | [中文版](land-dsl.zh-TW.md)

# Land DSL

Land 是伺服器邏輯的最小可運行單位，負責定義加入規則、行為規則與生命周期。
`Land(...)` 會收集 DSL 節點並產生 `LandDefinition<State>`，交由 Runtime 執行。

## 設計說明

- Land DSL 只描述行為，不暴露 Transport 細節
- handlers 以同步方式定義，必要的 async 可透過 `ctx.spawn` 補上
- 事件型別註冊（Client/ServerEvents）用於 schema 與驗證

## 基本結構

```swift
Land("demo", using: GameState.self) {
    AccessControl { ... }
    ClientEvents { ... }
    ServerEvents { ... }
    Rules { ... }
    Lifetime { ... }
}
```

## AccessControl

控制房間可見性與人數上限：

- `AllowPublic(true|false)`
- `MaxPlayers(Int)`

## ClientEvents / ServerEvents

註冊事件型別（schema/驗證/工具會用到）：

```swift
ClientEvents {
    Register(ClickCookieEvent.self)
}

ServerEvents {
    Register(PongEvent.self)
}
```

## Rules

規則區塊定義 Join/Leave 與 Action/Event 行為：

- `CanJoin`：加入前驗證，回傳 `JoinDecision`
- `OnJoin` / `OnLeave`：加入或離開後處理
- `HandleAction`：處理 Action（有回應）
- `HandleEvent`：處理 Client Event（無回應）

```swift
Rules {
    CanJoin { state, session, ctx in
        .allow(playerID: PlayerID(session.playerID))
    }

    OnJoin { state, ctx in
        // mutate state
    }

    HandleAction(JoinAction.self) { state, action, ctx in
        return JoinResponse(status: "ok")
    }

    HandleEvent(ClickCookieEvent.self) { state, event, ctx in
        // mutate state
    }
}
```

## LandContext

Handler 會取得 `LandContext`，包含：

- `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`
- `metadata`（來自 join/JWT/guest）
- `services`（注入外部服務）
- `sendEvent(...)`, `syncNow()`, `spawn { ... }`

LandContext 是 request-scoped，請避免保存引用。

## Resolver

`HandleAction`、`OnJoin`、`OnInitialize` 等可宣告 resolver。
Resolver 先並行執行，成功後再同步進入 handler。

## Lifetime

- `Tick(every:)`：固定頻率 tick
- `DestroyWhenEmpty(after:)`：空房間自動關閉
- `PersistSnapshot(every:)`：快照週期
- `OnInitialize` / `OnFinalize` / `AfterFinalize` / `OnShutdown`

```swift
Lifetime {
    Tick(every: .seconds(1)) { state, ctx in
        // periodic logic
    }
}
```

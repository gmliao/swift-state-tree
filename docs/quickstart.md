# 快速開始

## 前置需求

- Swift 6
- macOS 14+

## 方案 A：直接跑 Demo

```bash
cd Examples/HummingbirdDemo
swift run HummingbirdDemo
```

## 方案 B：最小單房間伺服器

### 1) 定義 State 與 Payload

```swift
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
}

@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
}

@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
}

@Payload
struct JoinResponse: ResponsePayload {
    let status: String
}

@Payload
struct PingEvent: ClientEventPayload {
    let sentAt: Int
}

@Payload
struct PongEvent: ServerEventPayload {
    let sentAt: Int
}
```

### 2) 定義 Land

```swift
let land = Land("demo", using: GameState.self) {
    AccessControl {
        MaxPlayers(4)
    }

    ClientEvents {
        Register(PingEvent.self)
    }

    ServerEvents {
        Register(PongEvent.self)
    }

    Lifetime {
        Tick(every: .milliseconds(100)) { state, ctx in
            // Game logic here
        }
        DestroyWhenEmpty(after: .seconds(30))
    }

    Rules {
        HandleAction(JoinAction.self) { state, action, ctx in
            state.players[action.playerID] = PlayerState(name: action.name)
            return JoinResponse(status: "ok")
        }

        HandleEvent(PingEvent.self) { state, event, ctx in
            ctx.spawn {
                await ctx.sendEvent(PongEvent(sentAt: event.sentAt), to: .player(ctx.playerID))
            }
        }
    }
}
```

### 3) 使用 Hummingbird Hosting

```swift
import SwiftStateTreeHummingbird

@main
struct DemoServer {
    static func main() async throws {
        let server = try await LandServer.makeServer(
            configuration: .init(),
            land: land,
            initialState: GameState()
        )
        try await server.run()
    }
}
```

import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeHummingbird

// MARK: - Demo State

@StateNodeBuilder
struct DemoGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var messageCount: Int = 0
    
    @Sync(.broadcast)
    var ticks: Int = 0
}

// MARK: - Demo Actions

struct JoinAction: ActionPayload {
    typealias Response = JoinResult
    let name: String
}

struct JoinResult: Codable, Sendable {
    let playerID: String
    let message: String
}

// MARK: - Demo Events

enum DemoClientEvents: ClientEventPayload, Hashable {
    case chat(String)
    case ping
}

enum DemoServerEvents: ServerEventPayload {
    case welcome(String)
    case chatMessage(String, from: String)
    case pong
}

// MARK: - Land Definition

let demoLand = Land(
    "demo-game",
    using: DemoGameState.self,
    clientEvents: DemoClientEvents.self,
    serverEvents: DemoServerEvents.self
) {
    AccessControl {
        AllowPublic(true)
        MaxPlayers(10)
    }
    
    Rules {
        OnJoin { (state: inout DemoGameState, ctx: LandContext) in
            let playerName = state.players[ctx.playerID] ?? "Guest"
            await ctx.sendEvent(DemoServerEvents.welcome("Welcome, \(playerName)!"), to: .session(ctx.sessionID))
        }
        
        OnLeave { (state: inout DemoGameState, ctx: LandContext) in
            print("Player \(ctx.playerID) left")
        }
        
        Action(JoinAction.self) { (state: inout DemoGameState, action: JoinAction, ctx: LandContext) in
            state.players[ctx.playerID] = action.name
            await ctx.syncNow()
            return JoinResult(playerID: ctx.playerID.rawValue, message: "Joined as \(action.name)")
        }
        
        On(DemoClientEvents.self) { (state: inout DemoGameState, event: DemoClientEvents, ctx: LandContext) in
            switch event {
            case .chat(let message):
                state.messageCount += 1
                let playerName = state.players[ctx.playerID] ?? "Unknown"
                await ctx.sendEvent(
                    DemoServerEvents.chatMessage(message, from: playerName),
                    to: .all
                )
            case .ping:
                await ctx.sendEvent(DemoServerEvents.pong, to: .session(ctx.sessionID))
            }
        }
    }
    
    Lifetime { (config: inout LifetimeConfig<DemoGameState>) in
        config.tickInterval = .seconds(1)
        config.tickHandler = { (state: inout DemoGameState, _: LandContext) in
            state.ticks += 1
        }
    }
}

// MARK: - Application Setup

@main
struct HummingbirdDemo {
    static func main() async throws {
        // 1. Setup Transport Layer
        let transport = WebSocketTransport()
        
        // 2. Create a holder for TransportAdapter to break circular dependency
        actor TransportAdapterHolder {
            var adapter: TransportAdapter<DemoGameState, DemoClientEvents, DemoServerEvents>?
            
            func set(_ adapter: TransportAdapter<DemoGameState, DemoClientEvents, DemoServerEvents>) {
                self.adapter = adapter
            }
        }
        
        let adapterHolder = TransportAdapterHolder()
        
        // 3. Setup LandKeeper with callbacks that use the adapter holder
        let keeper = LandKeeper<DemoGameState, DemoClientEvents, DemoServerEvents>(
            definition: demoLand,
            initialState: DemoGameState(),
            sendEvent: { event, target in
                await adapterHolder.adapter?.sendEvent(event, to: target)
            },
            syncNow: {
                await adapterHolder.adapter?.syncNow()
            }
        )
        
        // 4. Setup TransportAdapter (connects LandKeeper and Transport)
        let transportAdapter = TransportAdapter<DemoGameState, DemoClientEvents, DemoServerEvents>(
            keeper: keeper,
            transport: transport,
            landID: demoLand.id
        )
        await adapterHolder.set(transportAdapter)
        await transport.setDelegate(transportAdapter)
        
        // 3. Setup Hummingbird Adapter
        let hbAdapter = HummingbirdStateTreeAdapter(transport: transport)
        
        // 4. Setup Hummingbird Router
        let router = Router(context: BasicWebSocketRequestContext.self)
        
        // WebSocket endpoint
        router.ws("/game") { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        // Health check endpoint
        router.get("/health") { _, _ in
            return "OK"
        }
        
        // 5. Build and run Application
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("localhost", port: 8080)
            )
        )
        
        print("🚀 Hummingbird Demo Server started at http://localhost:8080")
        print("📡 WebSocket endpoint: ws://localhost:8080/game")
        print("❤️  Health check: http://localhost:8080/health")
        
        try await app.runService()
    }
}


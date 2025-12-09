import Foundation
import SwiftStateTree

/// Factory functions for creating lobby land definitions.
///
/// Provides example implementations for lobby lands that integrate with
/// MatchmakingService and support room list tracking.
///
/// Users can use these as templates or create their own custom lobby definitions.
public enum LobbyLandFactory {
    
    /// Create a basic lobby land definition.
    ///
    /// This factory function provides a complete lobby implementation with:
    /// - RequestMatchmakingAction handler (automatic matching)
    /// - CreateRoomAction handler (client can freely create rooms)
    /// - JoinRoomAction handler (manual room selection)
    /// - Room list tracking via Tick handler
    ///
    /// - Parameters:
    ///   - lobbyID: The unique identifier for this lobby (e.g., "lobby-asia").
    ///   - matchmakingService: The matchmaking service (injected via LandServices).
    ///   - landManagerRegistry: The land manager registry (injected via LandServices).
    ///   - landTypeRegistry: The land type registry (injected via LandServices).
    /// - Returns: A LandDefinition configured for lobby functionality.
    ///
    /// Example usage:
    /// ```swift
    /// let lobbyDefinition = LobbyLandFactory.makeLobbyLandDefinition(
    ///     lobbyID: "lobby-asia",
    ///     matchmakingService: matchmakingService,
    ///     landManagerRegistry: registry,
    ///     landTypeRegistry: landTypeRegistry
    /// )
    /// ```
    public static func makeLobbyLandDefinition<State: StateNodeProtocol, Registry: LandManagerRegistry>(
        lobbyID: String,
        matchmakingService: MatchmakingService<State, Registry>,
        landManagerRegistry: Registry,
        landTypeRegistry: LandTypeRegistry<State>
    ) -> LandDefinition<State> where Registry.State == State {
        return Land(lobbyID, using: State.self) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(1000) // Lobbies can have many players
            }
            
            ClientEvents {
                // Register any client events if needed
            }
            
            ServerEvents {
                Register(MatchmakingEvent.self)
                Register(RoomListEvent.self)
            }
            
            Lifetime {
                // Tick handler for room list updates (similar to Colyseus LobbyRoom)
                Tick(every: .seconds(5)) { (state: inout State, ctx: LandContext) in
                    // Update room list periodically
                    // This should call LobbyContainer.updateAndNotifyRoomList()
                    // For now, this is a placeholder
                }
            }
            
            Rules {
                // Handle matchmaking request
                HandleAction(RequestMatchmakingAction.self) { (state: inout State, action: RequestMatchmakingAction, ctx: LandContext) in
                    // Get services from context
                    // Note: In a real implementation, services would be injected via LandServices
                    // For now, we'll need to pass them through a different mechanism
                    // This is a simplified example - users should adapt based on their service injection strategy
                    
                    // The actual matchmaking logic should be handled by LobbyContainer
                    // This handler is a placeholder - users should integrate with their LobbyContainer
                    return MatchmakingResponse(result: .failed(reason: "MatchmakingService not available in handler"))
                }
                
                // Handle room creation
                HandleAction(CreateRoomAction.self) { (state: inout State, action: CreateRoomAction, ctx: LandContext) in
                    // Similar to matchmaking, this should delegate to LobbyContainer
                    // This is a placeholder - users should integrate with their LobbyContainer
                    return CreateRoomResponse(
                        landID: LandID("placeholder"),
                        success: false,
                        message: "Room creation not available in handler"
                    )
                }
                
                // Handle manual room join
                HandleAction(JoinRoomAction.self) { (state: inout State, action: JoinRoomAction, ctx: LandContext) in
                    // Similar to above, this should delegate to LobbyContainer
                    // This is a placeholder - users should integrate with their LobbyContainer
                    return JoinRoomResponse(
                        success: false,
                        message: "Room join not available in handler"
                    )
                }
            }
        }
    }
    
    /// Create a minimal lobby land definition (for users who want to implement their own handlers).
    ///
    /// This provides a basic structure that users can extend with their own Action handlers.
    ///
    /// - Parameter lobbyID: The unique identifier for this lobby.
    /// - Returns: A minimal LandDefinition with lobby state structure.
    public static func makeMinimalLobbyLandDefinition<State: StateNodeProtocol>(
        lobbyID: String
    ) -> LandDefinition<State> {
        return Land(lobbyID, using: State.self) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(1000)
            }
            
            ServerEvents {
                Register(MatchmakingEvent.self)
                Register(RoomListEvent.self)
            }
            
            Rules {
                // Users implement their own handlers here
            }
        }
    }
}


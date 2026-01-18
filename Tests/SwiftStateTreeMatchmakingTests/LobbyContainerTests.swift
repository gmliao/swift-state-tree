import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMatchmaking

@StateNodeBuilder
struct LobbyTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.perPlayerSlice())
    var matchmakingStatus: [PlayerID: MatchmakingStatus] = [:]
    
    @Sync(.broadcast)
    var availableRooms: [LandID: AvailableRoom] = [:]
}

// MARK: - Tests

@Test("LobbyContainer can be initialized")
func testLobbyContainerInitialization() async throws {
    // Arrange
    let landID = LandID("lobby-test")
    let definition = Land("lobby-test", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(100)
        }
    }
    let initialState = LobbyTestState()
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<LobbyTestState>(
        definition: definition,
        initialState: initialState
    )
    let transportAdapter = TransportAdapter<LobbyTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    await keeper.setTransport(transportAdapter)
    await transport.setDelegate(transportAdapter)
    
    let container = LandContainer<LobbyTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: transportAdapter
    )
    
    let landManager = LandManager<LobbyTestState>(
        landFactory: { _ in definition },
        initialStateFactory: { _ in initialState }
    )
    let registry = SingleLandManagerRegistry(landManager: landManager)
    
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 4, minPlayersToStart: 1)
    let landTypeRegistry = LandTypeRegistry<LobbyTestState>(
        landFactory: { landType, _ in
            Land(landType, using: LobbyTestState.self) {
                AccessControl {
                    AllowPublic(true)
                    MaxPlayers(4)
                }
            }
        },
        initialStateFactory: { _, _ in LobbyTestState() }
    )
    
    let matchmakingService = MatchmakingService(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    // Act
    let lobby = LobbyContainer(
        container: container,
        matchmakingService: matchmakingService,
        landManagerRegistry: registry,
        landTypeRegistry: landTypeRegistry
    )
    
    // Assert
    #expect(lobby.container.landID == landID)
}

@Test("LobbyContainer can request matchmaking")
func testLobbyContainerRequestMatchmaking() async throws {
    // Arrange
    let landID = LandID("lobby-test")
    let definition = Land("lobby-test", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(100)
        }
    }
    let initialState = LobbyTestState()
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<LobbyTestState>(
        definition: definition,
        initialState: initialState
    )
    let transportAdapter = TransportAdapter<LobbyTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    await keeper.setTransport(transportAdapter)
    await transport.setDelegate(transportAdapter)
    
    let container = LandContainer<LobbyTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: transportAdapter
    )
    
    let gameLandDefinition = Land("battle-royale", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(4)
        }
    }
    
    let landManager = LandManager<LobbyTestState>(
        landFactory: { _ in gameLandDefinition },
        initialStateFactory: { _ in initialState }
    )
    let registry = SingleLandManagerRegistry(landManager: landManager)
    
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 4, minPlayersToStart: 1)
    let landTypeRegistry = LandTypeRegistry<LobbyTestState>(
        landFactory: { landType, _ in
            Land(landType, using: LobbyTestState.self) {
                AccessControl {
                    AllowPublic(true)
                    MaxPlayers(4)
                }
            }
        },
        initialStateFactory: { _, _ in initialState }
    )
    
    let matchmakingService = MatchmakingService(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    let lobby = LobbyContainer(
        container: container,
        matchmakingService: matchmakingService,
        landManagerRegistry: registry,
        landTypeRegistry: landTypeRegistry
    )
    
    let playerID = PlayerID("player1")
    let preferences = MatchmakingPreferences(landType: "battle-royale")
    
    // Act
    let result = try await lobby.requestMatchmaking(
        playerID: playerID,
        preferences: preferences
    )
    
    // Assert
    // Since no existing land exists and minPlayersToStart is 1, should create new land
    switch result {
    case .matched(let matchedLandID):
        #expect(matchedLandID.stringValue.hasPrefix("battle-royale"))
    case .queued(let position):
        // Could also be queued if strategy requires more players
        #expect(position >= 1)
    case .failed(let reason):
        Issue.record("Matchmaking failed: \(reason)")
    }
}

@Test("LobbyContainer can create room")
func testLobbyContainerCreateRoom() async throws {
    // Arrange
    let landID = LandID("lobby-test")
    let definition = Land("lobby-test", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(100)
        }
    }
    let initialState = LobbyTestState()
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<LobbyTestState>(
        definition: definition,
        initialState: initialState
    )
    let transportAdapter = TransportAdapter<LobbyTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    await keeper.setTransport(transportAdapter)
    await transport.setDelegate(transportAdapter)
    
    let container = LandContainer<LobbyTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: transportAdapter
    )
    
    let gameLandDefinition = Land("battle-royale", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(4)
        }
    }
    
    let landManager = LandManager<LobbyTestState>(
        landFactory: { _ in gameLandDefinition },
        initialStateFactory: { _ in initialState }
    )
    let registry = SingleLandManagerRegistry(landManager: landManager)
    
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 4, minPlayersToStart: 1)
    let landTypeRegistry = LandTypeRegistry<LobbyTestState>(
        landFactory: { landType, _ in
            Land(landType, using: LobbyTestState.self) {
                AccessControl {
                    AllowPublic(true)
                    MaxPlayers(4)
                }
            }
        },
        initialStateFactory: { _, _ in initialState }
    )
    
    let matchmakingService = MatchmakingService(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    let lobby = LobbyContainer(
        container: container,
        matchmakingService: matchmakingService,
        landManagerRegistry: registry,
        landTypeRegistry: landTypeRegistry
    )
    
    let playerID = PlayerID("player1")
    
    // Act
    let createdLandID = try await lobby.createRoom(
        playerID: playerID,
        landType: "battle-royale",
        roomName: "Test Room",
        maxPlayers: 4
    )
    
    // Assert
    #expect(createdLandID.stringValue.hasPrefix("battle-royale"))
    
    // Verify room was created
    let createdRoom = await registry.getLand(landID: createdLandID)
    #expect(createdRoom != nil)
}

@Test("LobbyContainer can join room")
func testLobbyContainerJoinRoom() async throws {
    // Arrange
    let landID = LandID("lobby-test")
    let definition = Land("lobby-test", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(100)
        }
    }
    let initialState = LobbyTestState()
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<LobbyTestState>(
        definition: definition,
        initialState: initialState
    )
    let transportAdapter = TransportAdapter<LobbyTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    await keeper.setTransport(transportAdapter)
    await transport.setDelegate(transportAdapter)
    
    let container = LandContainer<LobbyTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: transportAdapter
    )
    
    let gameLandDefinition = Land("battle-royale", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(4)
        }
    }
    
    let landManager = LandManager<LobbyTestState>(
        landFactory: { _ in gameLandDefinition },
        initialStateFactory: { _ in initialState }
    )
    let registry = SingleLandManagerRegistry(landManager: landManager)
    
    // Create a room first
    let gameLandID = LandID("battle-royale-123")
    _ = await landManager.getOrCreateLand(
        landID: gameLandID,
        definition: gameLandDefinition,
        initialState: initialState,
        metadata: [:]
    )
    
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 4, minPlayersToStart: 1)
    let landTypeRegistry = LandTypeRegistry<LobbyTestState>(
        landFactory: { landType, _ in
            Land(landType, using: LobbyTestState.self) {
                AccessControl {
                    AllowPublic(true)
                    MaxPlayers(4)
                }
            }
        },
        initialStateFactory: { _, _ in initialState }
    )
    
    let matchmakingService = MatchmakingService(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    let lobby = LobbyContainer(
        container: container,
        matchmakingService: matchmakingService,
        landManagerRegistry: registry,
        landTypeRegistry: landTypeRegistry
    )
    
    let playerID = PlayerID("player1")
    
    // Act
    let success = await lobby.joinRoom(playerID: playerID, landID: gameLandID)
    
    // Assert
    #expect(success == true)
}

@Test("LobbyContainer joinRoom returns false for non-existent room")
func testLobbyContainerJoinNonExistentRoom() async throws {
    // Arrange
    let landID = LandID("lobby-test")
    let definition = Land("lobby-test", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(100)
        }
    }
    let initialState = LobbyTestState()
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<LobbyTestState>(
        definition: definition,
        initialState: initialState
    )
    let transportAdapter = TransportAdapter<LobbyTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    await keeper.setTransport(transportAdapter)
    await transport.setDelegate(transportAdapter)
    
    let container = LandContainer<LobbyTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: transportAdapter
    )
    
    let gameLandDefinition = Land("battle-royale", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(4)
        }
    }
    
    let landManager = LandManager<LobbyTestState>(
        landFactory: { _ in gameLandDefinition },
        initialStateFactory: { _ in initialState }
    )
    let registry = SingleLandManagerRegistry(landManager: landManager)
    
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 4, minPlayersToStart: 1)
    let landTypeRegistry = LandTypeRegistry<LobbyTestState>(
        landFactory: { landType, _ in
            Land(landType, using: LobbyTestState.self) {
                AccessControl {
                    AllowPublic(true)
                    MaxPlayers(4)
                }
            }
        },
        initialStateFactory: { _, _ in initialState }
    )
    
    let matchmakingService = MatchmakingService(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    let lobby = LobbyContainer(
        container: container,
        matchmakingService: matchmakingService,
        landManagerRegistry: registry,
        landTypeRegistry: landTypeRegistry
    )
    
    let playerID = PlayerID("player1")
    let nonExistentLandID = LandID("non-existent-room")
    
    // Act
    let success = await lobby.joinRoom(playerID: playerID, landID: nonExistentLandID)
    
    // Assert
    #expect(success == false)
}

@Test("LobbyContainer can update room list")
func testLobbyContainerUpdateRoomList() async throws {
    // Arrange
    let landID = LandID("lobby-test")
    let definition = Land("lobby-test", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(100)
        }
    }
    let initialState = LobbyTestState()
    
    let transport = WebSocketTransport()
    let keeper = LandKeeper<LobbyTestState>(
        definition: definition,
        initialState: initialState
    )
    let transportAdapter = TransportAdapter<LobbyTestState>(
        keeper: keeper,
        transport: transport,
        landID: landID.stringValue,
        enableLegacyJoin: true
    )
    await keeper.setTransport(transportAdapter)
    await transport.setDelegate(transportAdapter)
    
    let container = LandContainer<LobbyTestState>(
        landID: landID,
        keeper: keeper,
        transport: transport,
        transportAdapter: transportAdapter
    )
    
    let gameLandDefinition = Land("battle-royale", using: LobbyTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(4)
        }
    }
    
    let landManager = LandManager<LobbyTestState>(
        landFactory: { _ in gameLandDefinition },
        initialStateFactory: { _ in initialState }
    )
    let registry = SingleLandManagerRegistry(landManager: landManager)
    
    // Create some rooms
    let room1ID = LandID("battle-royale-1")
    let room2ID = LandID("battle-royale-2")
    _ = await landManager.getOrCreateLand(
        landID: room1ID,
        definition: gameLandDefinition,
        initialState: initialState,
        metadata: [:]
    )
    _ = await landManager.getOrCreateLand(
        landID: room2ID,
        definition: gameLandDefinition,
        initialState: initialState,
        metadata: [:]
    )
    
    let strategy = DefaultMatchmakingStrategy(maxPlayersPerLand: 4, minPlayersToStart: 1)
    let landTypeRegistry = LandTypeRegistry<LobbyTestState>(
        landFactory: { landType, _ in
            Land(landType, using: LobbyTestState.self) {
                AccessControl {
                    AllowPublic(true)
                    MaxPlayers(4)
                }
            }
        },
        initialStateFactory: { _, _ in initialState }
    )
    
    let matchmakingService = MatchmakingService(
        registry: registry,
        landTypeRegistry: landTypeRegistry,
        strategyFactory: { _ in strategy }
    )
    
    let lobby = LobbyContainer(
        container: container,
        matchmakingService: matchmakingService,
        landManagerRegistry: registry,
        landTypeRegistry: landTypeRegistry
    )
    
    // Act
    let rooms = await lobby.updateRoomList()
    
    // Assert
    // Should return rooms but exclude lobbies
    #expect(rooms.count >= 2)
    let roomIDs = Set(rooms.map { $0.landID })
    #expect(roomIDs.contains(room1ID))
    #expect(roomIDs.contains(room2ID))
    // Should not include lobby
    #expect(!roomIDs.contains(landID))
}


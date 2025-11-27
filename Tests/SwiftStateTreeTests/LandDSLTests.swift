import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateNode Definitions

/// Test StateNode for Land DSL tests
@StateNodeBuilder
struct TestLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]

    @Sync(.broadcast)
    var round: Int = 0
}

// MARK: - Test Action and Event Types

enum TestActionResponse: Codable, Sendable {
    case empty
}

/// Test Action enum for Land DSL tests
enum TestAction: ActionPayload {
    typealias Response = TestActionResponse
    case join(playerID: PlayerID, name: String)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
    case getPlayerHand(PlayerID)
}

/// Test ClientEvent enum
enum TestClientEvent: ClientEventPayload {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
}

/// Test ServerEvent enum
enum TestServerEvent: ServerEventPayload {
    case stateUpdate(StateSnapshot)
    case gameEvent(String)
    case systemMessage(String)
}

// MARK: - Types Tests

// MARK: - Identity Types Tests

@Test("ClientID can be created and compared")
func testClientID_CreationAndComparison() {
    // Arrange
    let clientID1 = ClientID("device-001")
    let clientID2 = ClientID("device-001")
    let clientID3 = ClientID("device-002")

    // Assert
    #expect(clientID1 == clientID2, "Same rawValue should be equal")
    #expect(clientID1 != clientID3, "Different rawValue should not be equal")
    #expect(clientID1.description == "device-001", "Description should match rawValue")
}

@Test("SessionID can be created and compared")
func testSessionID_CreationAndComparison() {
    // Arrange
    let sessionID1 = SessionID("session-001")
    let sessionID2 = SessionID("session-001")
    let sessionID3 = SessionID("session-002")

    // Assert
    #expect(sessionID1 == sessionID2, "Same rawValue should be equal")
    #expect(sessionID1 != sessionID3, "Different rawValue should not be equal")
    #expect(sessionID1.description == "session-001", "Description should match rawValue")
}

@Test("ClientID and SessionID are Codable")
func testIdentityTypes_AreCodable() throws {
    // Arrange
    let clientID = ClientID("device-001")
    let sessionID = SessionID("session-001")

    // Act
    let clientData = try JSONEncoder().encode(clientID)
    let sessionData = try JSONEncoder().encode(sessionID)

    let decodedClientID = try JSONDecoder().decode(ClientID.self, from: clientData)
    let decodedSessionID = try JSONDecoder().decode(SessionID.self, from: sessionData)

    // Assert
    #expect(decodedClientID == clientID, "ClientID should decode correctly")
    #expect(decodedSessionID == sessionID, "SessionID should decode correctly")
}

// MARK: - EventTarget Tests

@Test("EventTarget enum cases work correctly")
func testEventTarget_EnumCases() {
    // Arrange
    let playerID = PlayerID("alice")
    let clientID = ClientID("device-001")
    let sessionID = SessionID("session-001")

    // Act & Assert
    let allTarget = EventTarget.all
    #expect(String(describing: allTarget) == "all", "all case should work")

    let playerTarget = EventTarget.player(playerID)
    #expect(String(describing: playerTarget).contains("alice"), "player case should work")

    let clientTarget = EventTarget.client(clientID)
    #expect(String(describing: clientTarget).contains("device-001"), "client case should work")

    let sessionTarget = EventTarget.session(sessionID)
    #expect(String(describing: sessionTarget).contains("session-001"), "session case should work")

    let playersTarget = EventTarget.players([playerID])
    #expect(String(describing: playersTarget).contains("alice"), "players case should work")
}

// MARK: - LandConfig Tests

@Test("LandConfig can be created with default values")
func testLandConfig_DefaultValues() {
    // Arrange & Act
    let config = LandConfig()

    // Assert
    #expect(config.maxPlayers == nil, "maxPlayers should be nil by default")
    #expect(config.tickInterval == nil, "tickInterval should be nil by default")
    #expect(config.idleTimeout == nil, "idleTimeout should be nil by default")
}

@Test("LandConfig can be created with all values")
func testLandConfig_AllValues() {
    // Arrange & Act
    let config = LandConfig(
        maxPlayers: 4,
        tickInterval: .milliseconds(100),
        idleTimeout: .seconds(60)
    )

    // Assert
    #expect(config.maxPlayers == 4, "maxPlayers should be set")
    #expect(config.tickInterval == .milliseconds(100), "tickInterval should be set")
    #expect(config.idleTimeout == .seconds(60), "idleTimeout should be set")
}

@Test("LandConfig mutating methods work correctly")
func testLandConfig_MutatingMethods() {
    // Arrange
    var config = LandConfig()

    // Act
    config.setMaxPlayers(8)
    config.setTickInterval(.milliseconds(50))
    config.setIdleTimeout(.seconds(120))

    // Assert
    #expect(config.maxPlayers == 8, "setMaxPlayers should work")
    #expect(config.tickInterval == .milliseconds(50), "setTickInterval should work")
    #expect(config.idleTimeout == .seconds(120), "setIdleTimeout should work")
}

// MARK: - Config DSL Tests

@Test("Config DSL can build configuration")
func testConfigDSL_BuildsConfiguration() {
    // Arrange & Act
    let config = Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
        IdleTimeout(.seconds(60))
    }

    // Assert
    #expect(config.maxPlayers == 4, "Config DSL should set maxPlayers")
    #expect(config.tickInterval == .milliseconds(100), "Config DSL should set tickInterval")
    #expect(config.idleTimeout == .seconds(60), "Config DSL should set idleTimeout")
}

@Test("Config DSL can build partial configuration")
func testConfigDSL_PartialConfiguration() {
    // Arrange & Act
    let config = Config {
        MaxPlayers(8)
    }

    // Assert
    #expect(config.maxPlayers == 8, "Config DSL should set maxPlayers")
    #expect(config.tickInterval == nil, "tickInterval should remain nil")
    #expect(config.idleTimeout == nil, "idleTimeout should remain nil")
}

// MARK: - LandContext Tests

@Test("LandContext can be created with required parameters")
func testLandContext_Creation() {
    // Arrange
    let landID = "test-land"
    let playerID = PlayerID("alice")
    let clientID = ClientID("device-001")
    let sessionID = SessionID("session-001")
    let services = LandServices()

    let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void = { _, _ in
        // Handler for testing
    }

    let syncHandler: @Sendable () async -> Void = {
        // Handler for testing
    }

    // Act
    let context = LandContext(
        landID: landID,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID,
        services: services,
        sendEventHandler: sendEventHandler,
        syncHandler: syncHandler
    )

    // Assert
    #expect(context.landID == landID, "landID should be set")
    #expect(context.playerID == playerID, "playerID should be set")
    #expect(context.clientID == clientID, "clientID should be set")
    #expect(context.sessionID == sessionID, "sessionID should be set")
}

@Test("LandContext sendEvent calls handler")
func testLandContext_SendEvent() async {
    // Arrange
    actor TestState {
        var eventSent: (any ServerEventPayload)?
        var targetUsed: EventTarget?

        func setEvent(_ event: any ServerEventPayload, target: EventTarget) {
            self.eventSent = event
            self.targetUsed = target
        }
    }

    let testState = TestState()

    let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void = { event, target in
        await testState.setEvent(event, target: target)
    }

    let syncHandler: @Sendable () async -> Void = {}

    let context = LandContext(
        landID: "test-land",
        playerID: PlayerID("alice"),
        clientID: ClientID("device-001"),
        sessionID: SessionID("session-001"),
        services: LandServices(),
        sendEventHandler: sendEventHandler,
        syncHandler: syncHandler
    )

    // Act
    let testEvent = TestServerEvent.systemMessage("test")
    await context.sendEvent(testEvent, to: .all)

    // Assert
    let eventSent = await testState.eventSent
    let targetUsed = await testState.targetUsed
    #expect(eventSent != nil, "sendEvent should call handler")
    if case .all = targetUsed {
        #expect(Bool(true), "target should be .all")
    } else {
        Issue.record("target should be .all")
    }
}

@Test("LandContext syncNow calls handler")
func testLandContext_SyncNow() async {
    // Arrange
    actor TestState {
        var syncCalled = false

        func setSyncCalled() {
            self.syncCalled = true
        }
    }

    let testState = TestState()

    let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void = { _, _ in }
    let syncHandler: @Sendable () async -> Void = {
        await testState.setSyncCalled()
    }

    let context = LandContext(
        landID: "test-land",
        playerID: PlayerID("alice"),
        clientID: ClientID("device-001"),
        sessionID: SessionID("session-001"),
        services: LandServices(),
        sendEventHandler: sendEventHandler,
        syncHandler: syncHandler
    )

    // Act
    await context.syncNow()

    // Assert
    let syncCalled = await testState.syncCalled
    #expect(syncCalled == true, "syncNow should call handler")
}

// MARK: - LandDSL Tests

@Test("LandDefinition can be created")
func testLandDefinition_Creation() {
    // Arrange & Act
    let landDef = Land(
        "test-land",
        using: TestLandState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self,
        actions: TestAction.self
    ) {
        Config {
            MaxPlayers(4)
        }
    }

    // Assert
    #expect(landDef.id == "test-land", "landDef id should be set")
    #expect(landDef.config.maxPlayers == 4, "config should be extracted from nodes")
}

@Test("Land DSL can combine multiple nodes")
func testLandDSL_CombinesNodes() {
    // Arrange & Act
    let landDef = Land(
        "test-land",
        using: TestLandState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self,
        actions: TestAction.self
    ) {
        Config {
            MaxPlayers(4)
            Tick(every: .milliseconds(100))
        }

        Action(TestAction.self) { (state: inout TestLandState, action: TestAction, ctx: LandContext) in
            return .empty
        }

        On(TestClientEvent.self) { (state: inout TestLandState, event: TestClientEvent, ctx: LandContext) in
            // Handler logic
        }
    }

    // Assert
    #expect(landDef.id == "test-land", "landDef id should be set")
    #expect(landDef.nodes.count >= 2, "landDef should contain multiple nodes")
    #expect(landDef.config.maxPlayers == 4, "config should be extracted")
}

@Test("Land DSL ConfigNode works correctly")
func testLandDSL_ConfigNode() {
    // Arrange
    let config = LandConfig(maxPlayers: 4, tickInterval: .milliseconds(100))

    // Act
    let configNode = ConfigNode(config)

    // Assert
    #expect(configNode.config.maxPlayers == 4, "ConfigNode should store config")
    #expect(configNode.config.tickInterval == .milliseconds(100), "ConfigNode should store tickInterval")
}

@Test("Land DSL ActionHandlerNode can be created")
func testLandDSL_ActionHandlerNode() {
    // Arrange & Act
    let actionNode = Action(TestAction.self) { (state: inout TestLandState, action: TestAction, ctx: LandContext) in
        switch action {
        case .join(let playerID, let name):
            state.players[playerID] = name
            return .empty
        case .attack:
            return .empty
        case .getPlayerHand:
            return .empty
        }
    }

    // Assert
    #expect(String(describing: actionNode).contains("ActionHandlerNode"), "Should create ActionHandlerNode")
}

@Test("Land DSL OnEventNode can be created")
func testLandDSL_OnEventNode() {
    // Arrange & Act
    let eventNode = On(TestClientEvent.self) { (state: inout TestLandState, event: TestClientEvent, ctx: LandContext) in
        // Handle event
    }

    // Assert
    #expect(String(describing: eventNode).contains("OnEventNode"), "Should create OnEventNode")
}

@Test("Land DSL OnTickNode can be created")
func testLandDSL_OnTickNode() {
    // Arrange & Act
    let tickNode = OnTick { (state: inout TestLandState, ctx: LandContext) in
        // Handle tick
    }

    // Assert
    #expect(String(describing: tickNode).contains("OnTickNode"), "Should create OnTickNode")
}

@Test("Land DSL AllowedClientEvents can be created")
func testLandDSL_AllowedClientEvents() {
    // Arrange & Act
    let allowedEvents = AllowedClientEvents {
        TestClientEvent.self
    }

    // Assert
    #expect(allowedEvents.allowedEventTypes.count >= 1, "Should contain event types")
}

// MARK: - Integration Tests

@Test("Land DSL can create complete land definition")
func testLandDSL_CompleteDefinition() {
    // Arrange & Act
    let landDef = Land(
        "complete-land",
        using: TestLandState.self,
        clientEvents: TestClientEvent.self,
        serverEvents: TestServerEvent.self,
        actions: TestAction.self
    ) {
        Config {
            MaxPlayers(4)
            Tick(every: .milliseconds(100))
            IdleTimeout(.seconds(60))
        }

        AllowedClientEvents {
            TestClientEvent.self
        }

        Action(TestAction.self) { (state: inout TestLandState, action: TestAction, ctx: LandContext) in
            return .empty
        }

        On(TestClientEvent.self) { (state: inout TestLandState, event: TestClientEvent, ctx: LandContext) in
            // Handle event
        }

        OnTick { (state: inout TestLandState, ctx: LandContext) in
            // Handle tick
        }
    }

    // Assert
    #expect(landDef.id == "complete-land", "landDef id should be correct")
    #expect(landDef.config.maxPlayers == 4, "config should be correct")
    #expect(landDef.config.tickInterval == .milliseconds(100), "tickInterval should be correct")
    #expect(landDef.config.idleTimeout == .seconds(60), "idleTimeout should be correct")
    #expect(landDef.nodes.count >= 4, "should contain multiple nodes")
}

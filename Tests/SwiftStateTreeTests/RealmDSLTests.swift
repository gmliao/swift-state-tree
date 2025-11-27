// Tests/SwiftStateTreeTests/RealmDSLTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test StateNode Definitions

/// Test StateNode for Realm DSL tests
@StateNodeBuilder
struct TestRealmState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var round: Int = 0
}

// MARK: - Test Action and Event Types

/// Test Action enum for Realm DSL tests
enum TestAction: Codable, Sendable {
    case join(playerID: PlayerID, name: String)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
    case getPlayerHand(PlayerID)
}

/// Test ClientEvent enum
enum TestClientEvent: ClientEvent {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
}

/// Test ServerEvent enum
enum TestServerEvent: ServerEvent {
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

// MARK: - ActionResult Tests

@Test("ActionResult success and failure cases work")
func testActionResult_Cases() {
    // Arrange
    let successResult = ActionResult.success(.empty)
    let failureResult = ActionResult.failure("Error message")
    
    // Assert
    if case .success = successResult {
        #expect(Bool(true), "Success case should work")
    } else {
        Issue.record("Success case failed")
    }
    
    if case .failure(let message) = failureResult {
        #expect(message == "Error message", "Failure case should contain error message")
    } else {
        Issue.record("Failure case failed")
    }
}

@Test("ActionResultData cases work correctly")
func testActionResultData_Cases() throws {
    // Arrange
    let joinResponse = JoinResponse(realmID: "realm-1", state: nil)
    let emptyData = ActionResultData.empty
    let joinResult = ActionResultData.joinResult(joinResponse)
    let realmInfo = ActionResultData.realmInfo(RealmInfo(realmID: "realm-1", playerCount: 4))
    
    // Assert
    #expect(String(describing: emptyData) == "empty", "empty case should work")
    
    if case .joinResult(let response) = joinResult {
        #expect(response.realmID == "realm-1", "joinResult should contain JoinResponse")
    } else {
        Issue.record("joinResult case failed")
    }
    
    if case .realmInfo(let info) = realmInfo {
        #expect(info.realmID == "realm-1", "realmInfo should contain RealmInfo")
        #expect(info.playerCount == 4, "realmInfo should contain player count")
    } else {
        Issue.record("realmInfo case failed")
    }
}

// MARK: - RealmConfig Tests

@Test("RealmConfig can be created with default values")
func testRealmConfig_DefaultValues() {
    // Arrange & Act
    let config = RealmConfig()
    
    // Assert
    #expect(config.maxPlayers == nil, "maxPlayers should be nil by default")
    #expect(config.tickInterval == nil, "tickInterval should be nil by default")
    #expect(config.idleTimeout == nil, "idleTimeout should be nil by default")
}

@Test("RealmConfig can be created with all values")
func testRealmConfig_AllValues() {
    // Arrange & Act
    let config = RealmConfig(
        maxPlayers: 4,
        tickInterval: .milliseconds(100),
        idleTimeout: .seconds(60)
    )
    
    // Assert
    #expect(config.maxPlayers == 4, "maxPlayers should be set")
    #expect(config.tickInterval == .milliseconds(100), "tickInterval should be set")
    #expect(config.idleTimeout == .seconds(60), "idleTimeout should be set")
}

@Test("RealmConfig mutating methods work correctly")
func testRealmConfig_MutatingMethods() {
    // Arrange
    var config = RealmConfig()
    
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

// MARK: - RealmContext Tests

@Test("RealmContext can be created with required parameters")
func testRealmContext_Creation() {
    // Arrange
    let realmID = "test-realm"
    let playerID = PlayerID("alice")
    let clientID = ClientID("device-001")
    let sessionID = SessionID("session-001")
    let services = RealmServices()
    
    let sendEventHandler: @Sendable (GameEvent, EventTarget) async -> Void = { _, _ in
        // Handler for testing
    }
    
    let syncHandler: @Sendable () async -> Void = {
        // Handler for testing
    }
    
    // Act
    let context = RealmContext(
        realmID: realmID,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID,
        services: services,
        sendEventHandler: sendEventHandler,
        syncHandler: syncHandler
    )
    
    // Assert
    #expect(context.realmID == realmID, "realmID should be set")
    #expect(context.playerID == playerID, "playerID should be set")
    #expect(context.clientID == clientID, "clientID should be set")
    #expect(context.sessionID == sessionID, "sessionID should be set")
}

@Test("RealmContext sendEvent calls handler")
func testRealmContext_SendEvent() async {
    // Arrange
    actor TestState {
        var eventSent: GameEvent?
        var targetUsed: EventTarget?
        
        func setEvent(_ event: GameEvent, target: EventTarget) {
            self.eventSent = event
            self.targetUsed = target
        }
    }
    
    let testState = TestState()
    
    let sendEventHandler: @Sendable (GameEvent, EventTarget) async -> Void = { event, target in
        await testState.setEvent(event, target: target)
    }
    
    let syncHandler: @Sendable () async -> Void = {}
    
    let context = RealmContext(
        realmID: "test-realm",
        playerID: PlayerID("alice"),
        clientID: ClientID("device-001"),
        sessionID: SessionID("session-001"),
        services: RealmServices(),
        sendEventHandler: sendEventHandler,
        syncHandler: syncHandler
    )
    
    // Act
    let testEvent = GameEvent.fromServer(TestServerEvent.systemMessage("test"))
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

@Test("RealmContext syncNow calls handler")
func testRealmContext_SyncNow() async {
    // Arrange
    actor TestState {
        var syncCalled = false
        
        func setSyncCalled() {
            self.syncCalled = true
        }
    }
    
    let testState = TestState()
    
    let sendEventHandler: @Sendable (GameEvent, EventTarget) async -> Void = { _, _ in }
    let syncHandler: @Sendable () async -> Void = {
        await testState.setSyncCalled()
    }
    
    let context = RealmContext(
        realmID: "test-realm",
        playerID: PlayerID("alice"),
        clientID: ClientID("device-001"),
        sessionID: SessionID("session-001"),
        services: RealmServices(),
        sendEventHandler: sendEventHandler,
        syncHandler: syncHandler
    )
    
    // Act
    await context.syncNow()
    
    // Assert
    let syncCalled = await testState.syncCalled
    #expect(syncCalled == true, "syncNow should call handler")
}

// MARK: - RealmDSL Tests

@Test("RealmDefinition can be created")
func testRealmDefinition_Creation() {
    // Arrange & Act
    let realmDef = Realm("test-realm", using: TestRealmState.self) {
        Config {
            MaxPlayers(4)
        }
    }
    
    // Assert
    #expect(realmDef.id == "test-realm", "realmDef id should be set")
    #expect(realmDef.config.maxPlayers == 4, "config should be extracted from nodes")
}

@Test("Realm DSL can combine multiple nodes")
func testRealmDSL_CombinesNodes() {
    // Arrange & Act - Type must be explicitly specified in closures
    let realmDef = Realm("test-realm", using: TestRealmState.self) {
        Config {
            MaxPlayers(4)
            Tick(every: .milliseconds(100))
        }
        
        Action(TestAction.self) { (state: inout TestRealmState, action: TestAction, ctx: RealmContext) -> ActionResult in
            return .success(.empty)
        }
        
        On(TestClientEvent.self) { (state: inout TestRealmState, event: TestClientEvent, ctx: RealmContext) in
            // Handler logic
        }
    }
    
    // Assert
    #expect(realmDef.id == "test-realm", "realmDef id should be set")
    #expect(realmDef.nodes.count >= 2, "realmDef should contain multiple nodes")
    #expect(realmDef.config.maxPlayers == 4, "config should be extracted")
}

@Test("Realm DSL ConfigNode works correctly")
func testRealmDSL_ConfigNode() {
    // Arrange
    let config = RealmConfig(maxPlayers: 4, tickInterval: .milliseconds(100))
    
    // Act
    let configNode = ConfigNode(config)
    
    // Assert
    #expect(configNode.config.maxPlayers == 4, "ConfigNode should store config")
    #expect(configNode.config.tickInterval == .milliseconds(100), "ConfigNode should store tickInterval")
}

@Test("Realm DSL ActionHandlerNode can be created")
func testRealmDSL_ActionHandlerNode() {
    // Arrange & Act - Explicitly specify State type
    let actionNode = Action(TestAction.self) { (state: inout TestRealmState, action: TestAction, ctx: RealmContext) -> ActionResult in
        switch action {
        case .join(let playerID, let name):
            state.players[playerID] = name
            return .success(.empty)
        case .attack:
            return .success(.empty)
        case .getPlayerHand:
            return .success(.empty)
        }
    }
    
    // Assert
    #expect(String(describing: actionNode).contains("ActionHandlerNode"), "Should create ActionHandlerNode")
}

@Test("Realm DSL OnEventNode can be created")
func testRealmDSL_OnEventNode() {
    // Arrange & Act - Explicitly specify types
    let eventNode = On(TestClientEvent.self) { (state: inout TestRealmState, event: TestClientEvent, ctx: RealmContext) in
        // Handle event
    }
    
    // Assert
    #expect(String(describing: eventNode).contains("OnEventNode"), "Should create OnEventNode")
}

@Test("Realm DSL OnTickNode can be created")
func testRealmDSL_OnTickNode() {
    // Arrange & Act - Explicitly specify types
    let tickNode = OnTick { (state: inout TestRealmState, ctx: RealmContext) in
        // Handle tick
    }
    
    // Assert
    #expect(String(describing: tickNode).contains("OnTickNode"), "Should create OnTickNode")
}

@Test("Realm DSL AllowedClientEvents can be created")
func testRealmDSL_AllowedClientEvents() {
    // Arrange & Act
    let allowedEvents = AllowedClientEvents {
        TestClientEvent.self
    }
    
    // Assert
    #expect(allowedEvents.allowedEventTypes.count >= 1, "Should contain event types")
}

@Test("App alias works correctly")
func testRealmDSL_AppAlias() {
    // Arrange & Act
    let appDef = App("my-app", using: TestRealmState.self) {
        Config {
            MaxPlayers(4)
        }
    }
    
    // Assert
    #expect(appDef.id == "my-app", "App alias should work")
    #expect(appDef.config.maxPlayers == 4, "App should support config")
}

@Test("Feature alias works correctly")
func testRealmDSL_FeatureAlias() {
    // Arrange & Act
    let featureDef = Feature("my-feature", using: TestRealmState.self) {
        Config {
            MaxPlayers(8)
        }
    }
    
    // Assert
    #expect(featureDef.id == "my-feature", "Feature alias should work")
    #expect(featureDef.config.maxPlayers == 8, "Feature should support config")
}

// MARK: - Integration Tests

@Test("Realm DSL can create complete realm definition")
func testRealmDSL_CompleteDefinition() {
    // Arrange & Act - Type must be explicitly specified in closures
    let realmDef = Realm("complete-realm", using: TestRealmState.self) {
        Config {
            MaxPlayers(4)
            Tick(every: .milliseconds(100))
            IdleTimeout(.seconds(60))
        }
        
        AllowedClientEvents {
            TestClientEvent.self
        }
        
        Action(TestAction.self) { (state: inout TestRealmState, action: TestAction, ctx: RealmContext) -> ActionResult in
            return .success(.empty)
        }
        
        On(TestClientEvent.self) { (state: inout TestRealmState, event: TestClientEvent, ctx: RealmContext) in
            // Handle event
        }
        
        OnTick { (state: inout TestRealmState, ctx: RealmContext) in
            // Handle tick
        }
    }
    
    // Assert
    #expect(realmDef.id == "complete-realm", "realmDef id should be correct")
    #expect(realmDef.config.maxPlayers == 4, "config should be correct")
    #expect(realmDef.config.tickInterval == .milliseconds(100), "tickInterval should be correct")
    #expect(realmDef.config.idleTimeout == .seconds(60), "idleTimeout should be correct")
    #expect(realmDef.nodes.count >= 4, "should contain multiple nodes")
}


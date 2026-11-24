// Tests for #796: a node a land declares once (`AccessControl`, `CanJoin`, `OnJoin`, `OnLeave`,
// and each `Lifetime` setting) declared twice, typically by two rules helpers, is refused at
// registration and by a directly built keeper, with both sites named. Unions stay unions: two
// `Lifetime` blocks that set different things, `AllowedClientEvents` lists and `ServerEvents`
// registrations compose.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct OnceNodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    public init() {}
}

typealias OnceDSL = LandDSL<OnceNodeState, NoServices>
typealias OnceRules = LandRules<OnceNodeState, NoServices>

@Payload
struct OnceFirstServerEvent: ServerEventPayload {
    let value: Int
}

@Payload
struct OnceSecondServerEvent: ServerEventPayload {
    let value: Int
}

// Two helpers per node, A before B: the first declaration kept is A's.
@OnceDSL func accessControlA() -> OnceRules { AccessControl { MaxPlayers(4) } }
@OnceDSL func accessControlB() -> OnceRules { AccessControl { MaxPlayers(8) } }
@OnceDSL func canJoinA() -> OnceRules { CanJoin { _, session, _ in .allow(playerID: PlayerID(session.playerID)) } }
@OnceDSL func canJoinB() -> OnceRules { CanJoin { _, session, _ in .allow(playerID: PlayerID(session.playerID)) } }
@OnceDSL func onJoinA() -> OnceRules { OnJoin { state, _ in state.count += 1 } }
@OnceDSL func onJoinB() -> OnceRules { OnJoin { state, _ in state.count += 2 } }
@OnceDSL func onLeaveA() -> OnceRules { OnLeave { state, _ in state.count -= 1 } }
@OnceDSL func onLeaveB() -> OnceRules { OnLeave { state, _ in state.count -= 2 } }
@OnceDSL func tickA() -> OnceRules { Lifetime { Tick(every: .seconds(3600)) { state, _ in state.count += 1 } } }
@OnceDSL func tickB() -> OnceRules { Lifetime { Tick(every: .seconds(1800)) } }
@OnceDSL func stateSyncA() -> OnceRules { Lifetime { StateSync(every: .seconds(1)) { _, _ in } } }
@OnceDSL func stateSyncB() -> OnceRules { Lifetime { StateSync(every: .seconds(2)) { _, _ in } } }
@OnceDSL func destroyWhenEmptyA() -> OnceRules { Lifetime { DestroyWhenEmpty(after: .seconds(60)) } }
@OnceDSL func destroyWhenEmptyB() -> OnceRules { Lifetime { DestroyWhenEmpty(after: .seconds(30)) { state, _ in state.count = 0 } } }
@OnceDSL func persistSnapshotA() -> OnceRules { Lifetime { PersistSnapshot(every: .seconds(60)) } }
@OnceDSL func persistSnapshotB() -> OnceRules { Lifetime { PersistSnapshot(every: .seconds(30)) } }
@OnceDSL func onInitializeA() -> OnceRules { Lifetime { OnInitialize { state, _ in state.count = 1 } } }
@OnceDSL func onInitializeB() -> OnceRules { Lifetime { OnInitialize { state, _ in state.count = 2 } } }
@OnceDSL func onFinalizeA() -> OnceRules { Lifetime { OnFinalize { state, _ in state.count = 0 } } }
@OnceDSL func onFinalizeB() -> OnceRules { Lifetime { OnFinalize { state, _ in state.count = -1 } } }
@OnceDSL func afterFinalizeA() -> OnceRules { Lifetime { AfterFinalize { _, _ in } } }
@OnceDSL func afterFinalizeB() -> OnceRules { Lifetime { AfterFinalize { _, _ in } } }

/// A land that splices two helpers declaring the same node.
struct OnceNodeCase: Sendable, CustomTestStringConvertible {
    let node: String
    let land: @Sendable () -> LandDefinition<OnceNodeState>

    var testDescription: String { node }

    init(_ node: String, _ first: @escaping @Sendable () -> OnceRules, _ second: @escaping @Sendable () -> OnceRules) {
        self.node = node
        self.land = {
            Land("once-\(node)", using: OnceNodeState.self) {
                first()
                Rules { second() }
            }
        }
    }
}

let onceNodeCases: [OnceNodeCase] = [
    OnceNodeCase("AccessControl", accessControlA, accessControlB),
    OnceNodeCase("CanJoin", canJoinA, canJoinB),
    OnceNodeCase("OnJoin", onJoinA, onJoinB),
    OnceNodeCase("OnLeave", onLeaveA, onLeaveB),
    OnceNodeCase("Tick", tickA, tickB),
    OnceNodeCase("StateSync", stateSyncA, stateSyncB),
    OnceNodeCase("DestroyWhenEmpty", destroyWhenEmptyA, destroyWhenEmptyB),
    OnceNodeCase("PersistSnapshot", persistSnapshotA, persistSnapshotB),
    OnceNodeCase("OnInitialize", onInitializeA, onInitializeB),
    OnceNodeCase("OnFinalize", onFinalizeA, onFinalizeB),
    OnceNodeCase("AfterFinalize", afterFinalizeA, afterFinalizeB),
]

/// Counts a closure's runs.
final class OnceRunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

private func registrationError(_ definition: LandDefinition<OnceNodeState>) throws -> LandRegistrationError {
    try #require(throws: LandRegistrationError.self) {
        try definition.validateForRegistration(context: .encodingIndependent)
    }
}

/// The registration error a directly built keeper holds as its initialization failure. A leave
/// throws it (a join is only denied: the failed land is shutting down).
private func keeperFailure(_ definition: LandDefinition<OnceNodeState>) async throws -> LandRegistrationError {
    let keeper = LandKeeper<OnceNodeState>(definition: definition, initialState: OnceNodeState(), autoStartLoops: false)
    let failure = try await #require(throws: LandInitializationError.self) {
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
    }
    return try #require(failure.underlying as? LandRegistrationError)
}

/// The line of a `fileID:line` site in this file, nil for a site elsewhere.
private func lineInThisFile(_ site: String?) -> Int? {
    let prefix = "SwiftStateTreeTests/SingleValuedNodeTests.swift:"
    guard let site, site.hasPrefix(prefix) else { return nil }
    return Int(site.dropFirst(prefix.count))
}

/// The one duplicate `error` holds, checked to name `node` at two sites in this file, the kept
/// one first.
private func expectOneDuplicate(_ error: LandRegistrationError, of node: String) throws {
    let duplicate = try #require(error.duplicateHandlers.count == 1 ? error.duplicateHandlers.first : nil, "\(error)")
    #expect(duplicate.kind == "node")
    #expect(duplicate.typeName == node)
    let first = try #require(lineInThisFile(duplicate.firstSite), "\(duplicate)")
    let second = try #require(lineInThisFile(duplicate.duplicateSite), "\(duplicate)")
    #expect(first < second, "the kept declaration is the first: \(duplicate)")
    #expect(error.description.contains(
        "\(node) is declared twice (at \(duplicate.firstSite ?? "") and \(duplicate.duplicateSite ?? "")); a land declares it once"
    ), "\(error)")
}

@Suite("A node a land declares once is refused when declared twice (#796)")
struct SingleValuedNodeTests {
    @Test("Declared by two rules helpers, it is refused at registration and by a directly built keeper, with both sites", arguments: onceNodeCases)
    func refusedAcrossHelpers(_ c: OnceNodeCase) async throws {
        try expectOneDuplicate(try registrationError(c.land()), of: c.node)
        try expectOneDuplicate(try await keeperFailure(c.land()), of: c.node)
    }

    @Test("A Lifetime setting made twice in one block is refused")
    func refusedWithinOneLifetimeBlock() throws {
        let land = Land("once-tick-one-block", using: OnceNodeState.self) {
            Lifetime {
                Tick(every: .seconds(3600)) { state, _ in state.count += 1 }
                Tick(every: .seconds(1800))
            }
        }
        try expectOneDuplicate(try registrationError(land), of: "Tick")
    }

    @Test("A setting the closure form of Lifetime makes in two blocks is refused, at the blocks' sites")
    func refusedInClosureForm() throws {
        let land = Land("once-tick-closure-form", using: OnceNodeState.self) {
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in config.tickInterval = .seconds(3600) }
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in config.tickInterval = .seconds(1800) }
        }
        try expectOneDuplicate(try registrationError(land), of: "Tick")
    }

    @Test("A Lifetime block runs twice when the land is built: once to find its settings, once to apply them")
    func lifetimeBlockRunsTwice() {
        let runs = OnceRunCounter()
        let land = Land("once-runs", using: OnceNodeState.self) {
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in
                runs.increment()
                config.tickInterval = .seconds(3600)
            }
        }
        #expect(runs.value == 2)
        #expect(land.config.tickInterval == .seconds(3600))
    }

    @Test("Lifetime blocks that set different things compose; allowed client events and server event registrations are unions")
    func unionsCompose() throws {
        let land = Land("once-composed", using: OnceNodeState.self) {
            tickA()
            destroyWhenEmptyA()
            Lifetime { PersistSnapshot(every: .seconds(60)) }
            AllowedClientEvents { "first" }
            AllowedClientEvents { "second" }
            ServerEvents { Register(OnceFirstServerEvent.self) }
            ServerEvents { Register(OnceSecondServerEvent.self) }
            onJoinA()
        }
        #expect(throws: Never.self) { try land.validateForRegistration(context: .encodingIndependent) }
        #expect(land.duplicateHandlers.isEmpty)
        #expect(land.config.tickInterval == .seconds(3600))
        #expect(land.config.destroyWhenEmptyAfter == .seconds(60))
        #expect(land.config.persistInterval == .seconds(60))
        #expect(land.config.allowedClientEvents == [AllowedEventIdentifier("first"), AllowedEventIdentifier("second")])
        #expect(land.serverEventRegistry.registered.count == 2)
    }
}

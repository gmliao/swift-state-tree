// Tests for #796: a node a land declares once (`AccessControl`, `CanJoin`, `OnJoin`, `OnLeave`,
// and each `Lifetime` setting) declared twice, typically by two rules helpers, is refused at
// registration and by a directly built keeper, with both sites named, and the first declaration
// is the one the definition keeps. Unions stay unions: two `Lifetime` blocks that set different
// things, `AllowedClientEvents` lists and `ServerEvents` registrations compose.

import Foundation
import Logging
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

/// Names written by closures under test, read back to tell which one ran.
final class OnceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

let onceAfterFinalizeLog = OnceLog()

// Two helpers per node, A before B, with values that tell them apart: the kept one is A's.
@OnceDSL func accessControlA() -> OnceRules { AccessControl { MaxPlayers(4) } }
@OnceDSL func accessControlB() -> OnceRules { AccessControl { MaxPlayers(8) } }
@OnceDSL func canJoinA() -> OnceRules { CanJoin { _, session, _ in .allow(playerID: PlayerID(session.playerID)) } }
@OnceDSL func canJoinB() -> OnceRules { CanJoin { _, _, _ in .deny(reason: "B") } }
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
@OnceDSL func onFinalizeA() -> OnceRules { Lifetime { OnFinalize { state, _ in state.count = 10 } } }
@OnceDSL func onFinalizeB() -> OnceRules { Lifetime { OnFinalize { state, _ in state.count = 20 } } }
@OnceDSL func afterFinalizeA() -> OnceRules { Lifetime { AfterFinalize { _, _ in onceAfterFinalizeLog.record("A") } } }
@OnceDSL func afterFinalizeB() -> OnceRules { Lifetime { AfterFinalize { _, _ in onceAfterFinalizeLog.record("B") } } }

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

private func onceContext() -> LandContext {
    LandContext(
        landID: "once",
        playerID: p1,
        clientID: c1,
        sessionID: s1,
        services: LandServices(),
        logger: Logger(label: "test"),
        deviceID: nil,
        metadata: [:],
        emitEventHandler: { _, _ in },
        requestSyncNowHandler: { },
        requestSyncBroadcastOnlyHandler: { }
    )
}

/// The count after running `handler` on a state whose count is `start`.
private func countAfter(_ handler: (@Sendable (inout OnceNodeState, LandContext) -> Void)?, from start: Int = 0) -> Int? {
    guard let handler else { return nil }
    var state = OnceNodeState()
    state.count = start
    handler(&state, onceContext())
    return state.count
}

/// A land that splices two helpers declaring the same node, and a check that the definition
/// kept the first one.
struct OnceNodeCase: Sendable, CustomTestStringConvertible {
    let node: String
    let land: @Sendable () -> LandDefinition<OnceNodeState>
    let keptFirst: @Sendable (LandDefinition<OnceNodeState>) async throws -> Bool

    var testDescription: String { node }

    init(
        _ node: String,
        _ first: @escaping @Sendable () -> OnceRules,
        _ second: @escaping @Sendable () -> OnceRules,
        keptFirst: @escaping @Sendable (LandDefinition<OnceNodeState>) async throws -> Bool
    ) {
        self.node = node
        self.land = {
            Land("once-\(node)", using: OnceNodeState.self) {
                first()
                Rules { second() }
            }
        }
        self.keptFirst = keptFirst
    }
}

let onceNodeCases: [OnceNodeCase] = [
    OnceNodeCase("AccessControl", accessControlA, accessControlB) { $0.config.maxPlayers == 4 },
    OnceNodeCase("CanJoin", canJoinA, canJoinB) { land in
        let decision = try land.lifetimeHandlers.canJoin?(OnceNodeState(), PlayerSession(playerID: "p1"), onceContext())
        if case .allow? = decision { return true }
        return false
    },
    OnceNodeCase("OnJoin", onJoinA, onJoinB) { countAfter($0.lifetimeHandlers.onJoin) == 1 },
    OnceNodeCase("OnLeave", onLeaveA, onLeaveB) { countAfter($0.lifetimeHandlers.onLeave) == -1 },
    OnceNodeCase("Tick", tickA, tickB) {
        $0.config.tickInterval == .seconds(3600) && countAfter($0.lifetimeHandlers.tickHandler) == 1
    },
    OnceNodeCase("StateSync", stateSyncA, stateSyncB) { $0.lifetimeHandlers.syncInterval == .seconds(1) },
    OnceNodeCase("DestroyWhenEmpty", destroyWhenEmptyA, destroyWhenEmptyB) {
        $0.config.destroyWhenEmptyAfter == .seconds(60) && $0.lifetimeHandlers.onDestroyWhenEmpty == nil
    },
    OnceNodeCase("PersistSnapshot", persistSnapshotA, persistSnapshotB) { $0.config.persistInterval == .seconds(60) },
    OnceNodeCase("OnInitialize", onInitializeA, onInitializeB) { land in
        guard let initialize = land.lifetimeHandlers.onInitialize else { return false }
        var state = OnceNodeState()
        try initialize.invoke(&state, onceContext())
        return state.count == 1
    },
    OnceNodeCase("OnFinalize", onFinalizeA, onFinalizeB) { countAfter($0.lifetimeHandlers.onFinalize) == 10 },
    OnceNodeCase("AfterFinalize", afterFinalizeA, afterFinalizeB) { land in
        guard let afterFinalize = land.lifetimeHandlers.afterFinalize else { return false }
        let before = onceAfterFinalizeLog.all.count
        await afterFinalize(OnceNodeState(), onceContext())
        return Array(onceAfterFinalizeLog.all.dropFirst(before)) == ["A"]
    },
]

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

/// A land that declares `OnJoin` in one branch of an `if` or the other.
private func branchedLand(_ useA: Bool) -> LandDefinition<OnceNodeState> {
    Land("once-branched", using: OnceNodeState.self) {
        if useA {
            onJoinA()
        } else {
            onJoinB()
        }
    }
}

/// A resolver executor the tests only store and count; never run.
struct OnceIdleExecutor: AnyResolverExecutor {
    struct NeverRun: Error {}
    func execute(ctx: ResolverContext) async throws -> (String, any ResolverOutput) { throw NeverRun() }
}

/// A closure-form `Lifetime` write to one of a setting's secondary fields alone, the setting it
/// belongs to, and whether the land kept it.
struct OnceSecondaryCase: Sendable, CustomTestStringConvertible {
    let field: String
    let setting: String
    let write: @Sendable (inout LifetimeConfig<OnceNodeState>) -> Void
    let kept: @Sendable (LandDefinition<OnceNodeState>) -> Bool
    /// A DSL entry that makes the same setting, for the split case.
    let entry: @Sendable () -> OnceRules

    var testDescription: String { field }
}

/// A lifecycle entry's resolvers, as the DSL stores them (#769): one idle executor.
func onceIdleDeclaration() -> ResolverDeclaration<OnceNodeState> {
    ResolverDeclaration(names: ["OnceIdle"], servicesType: NoServices.self, site: "test") { _, _ in [OnceIdleExecutor()] }
}

let onceSecondaryCases: [OnceSecondaryCase] = [
    OnceSecondaryCase(
        field: "onInitializeResolverFailure", setting: "OnInitialize",
        write: { $0.onInitializeResolverFailure = .continue },
        kept: { $0.lifetimeHandlers.onInitializeResolverFailure == .continue },
        entry: onInitializeA
    ),
    OnceSecondaryCase(
        field: "onInitializeResolvers", setting: "OnInitialize",
        write: { $0.onInitializeResolvers = onceIdleDeclaration() },
        kept: { $0.lifetimeHandlers.onInitializeResolvers?.names == ["OnceIdle"] },
        entry: onInitializeA
    ),
    OnceSecondaryCase(
        field: "onFinalizeResolvers", setting: "OnFinalize",
        write: { $0.onFinalizeResolvers = onceIdleDeclaration() },
        kept: { $0.lifetimeHandlers.onFinalizeResolvers?.names == ["OnceIdle"] },
        entry: onFinalizeA
    ),
    OnceSecondaryCase(
        field: "onDestroyWhenEmptyResolverExecutors", setting: "DestroyWhenEmpty",
        write: { $0.onDestroyWhenEmptyResolverExecutors = [OnceIdleExecutor()] },
        kept: { $0.lifetimeHandlers.onDestroyWhenEmptyResolverExecutors.count == 1 },
        entry: destroyWhenEmptyA
    ),
]

@Suite("A node a land declares once is refused when declared twice (#796)")
struct SingleValuedNodeTests {
    @Test("Declared by two rules helpers, it is refused at registration and by a directly built keeper, with both sites", arguments: onceNodeCases)
    func refusedAcrossHelpers(_ c: OnceNodeCase) async throws {
        try expectOneDuplicate(try registrationError(c.land()), of: c.node)
        try expectOneDuplicate(try await keeperFailure(c.land()), of: c.node)
    }

    @Test("The definition keeps the first declaration, seen where nothing validates it: a land built directly", arguments: onceNodeCases)
    func firstIsKept(_ c: OnceNodeCase) async throws {
        #expect(try await c.keptFirst(c.land()))
    }

    @Test("A Lifetime setting made twice in one block is refused, and the first is kept")
    func refusedWithinOneLifetimeBlock() throws {
        let land = Land("once-tick-one-block", using: OnceNodeState.self) {
            Lifetime {
                Tick(every: .seconds(3600)) { state, _ in state.count += 1 }
                Tick(every: .seconds(1800))
            }
        }
        try expectOneDuplicate(try registrationError(land), of: "Tick")
        #expect(land.config.tickInterval == .seconds(3600))
        #expect(countAfter(land.lifetimeHandlers.tickHandler) == 1)
    }

    @Test("A setting the closure form of Lifetime makes in two blocks is refused at the blocks' sites, and the first is kept")
    func refusedInClosureForm() throws {
        let land = Land("once-tick-closure-form", using: OnceNodeState.self) {
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in config.tickInterval = .seconds(3600) }
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in config.tickInterval = .seconds(1800) }
        }
        try expectOneDuplicate(try registrationError(land), of: "Tick")
        #expect(land.config.tickInterval == .seconds(3600))
    }

    @Test("A Lifetime block runs once when the land is built")
    func lifetimeBlockRunsOnce() {
        let runs = OnceLog()
        let land = Land("once-runs", using: OnceNodeState.self) {
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in
                runs.record("run")
                config.tickInterval = .seconds(3600)
            }
        }
        #expect(runs.all.count == 1)
        #expect(land.config.tickInterval == .seconds(3600))
    }

    @Test("Each branch of an if declares the node once: not refused, and the taken branch's is kept")
    func branchesAreNotDuplicates() throws {
        for useA in [true, false] {
            let land = branchedLand(useA)
            #expect(throws: Never.self) { try land.validateForRegistration(context: .encodingIndependent) }
            #expect(countAfter(land.lifetimeHandlers.onJoin) == (useA ? 1 : 2))
        }
    }

    @Test("A closure-form write to a setting's secondary field alone is kept", arguments: onceSecondaryCases)
    func secondaryFieldAloneIsKept(_ c: OnceSecondaryCase) throws {
        let write = c.write
        let land = Land("once-secondary-\(c.field)", using: OnceNodeState.self) {
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in write(&config) }
        }
        #expect(land.duplicateHandlers.isEmpty)
        #expect(c.kept(land))
    }

    @Test("A setting split across two blocks, its entry in one and a secondary field in the other, is refused", arguments: onceSecondaryCases)
    func secondaryFieldSplitIsRefused(_ c: OnceSecondaryCase) throws {
        let write = c.write, entry = c.entry
        let land = Land("once-secondary-split-\(c.field)", using: OnceNodeState.self) {
            entry()
            Lifetime { (config: inout LifetimeConfig<OnceNodeState>) in write(&config) }
        }
        try expectOneDuplicate(try registrationError(land), of: c.setting)
        #expect(!c.kept(land), "the first declaration, the entry's, is kept")
    }

    @Test("Every LifetimeConfig field belongs to one Lifetime setting, so the builder copies it")
    func lifetimeConfigFieldsAreCovered() {
        // `LifetimeConfig.take(_:from:)` copies a setting's fields. A field added to the config
        // without a setting would be dropped by the builder: add it to a setting and to `take`.
        let covered: Set<String> = [
            "tickInterval", "tickHandler",
            "syncInterval", "syncHandler",
            "destroyWhenEmptyAfter", "onDestroyWhenEmpty", "onDestroyWhenEmptyResolverExecutors",
            "persistInterval",
            "onInitialize", "onInitializeResolvers", "onInitializeResolverFailure",
            "onFinalize", "onFinalizeResolvers",
            "afterFinalize",
            // Bookkeeping, not a setting.
            "settingSites", "repeatedSettings",
        ]
        let fields = Set(Mirror(reflecting: LifetimeConfig<OnceNodeState>()).children.compactMap(\.label))
        #expect(fields == covered)
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

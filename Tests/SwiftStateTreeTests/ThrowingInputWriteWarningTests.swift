// Tests/SwiftStateTreeTests/ThrowingInputWriteWarningTests.swift
//
// #87: a handler that throws keeps what it wrote before the throw. Debug builds warn, once per
// input type and keeper, when a throwing handler changed the synced state; a handler that
// throws before its first write doesn't warn.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree

// MARK: - Land

@StateNodeBuilder
struct ThrowWriteState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var joined: Int = 0
    @Sync(.broadcast) var finalized: Int = 0
    init() {}
}

@Payload
struct ThrowWriteAddAction: ActionPayload {
    typealias Response = ThrowWriteAck
    let amount: Int
    /// Throws after writing `amount` (or before any write when `validateFirst`).
    let fail: Bool
    let validateFirst: Bool
}

@Payload
struct ThrowWriteOtherAction: ActionPayload {
    typealias Response = ThrowWriteAck
    let amount: Int
}

@Payload
struct ThrowWriteAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct ThrowWriteBumpEvent: ClientEventPayload {
    let amount: Int
}

struct ThrowWriteError: Error {}

private func makeThrowWriteLand(failingJoin: Bool = false, finalize: Bool = false, afterFinalize: Bool = false) -> LandDefinition<ThrowWriteState> {
    Land("throw-write-test", using: ThrowWriteState.self) {
        ClientEvents { Register(ThrowWriteBumpEvent.self) }
        Lifetime { (config: inout LifetimeConfig<ThrowWriteState>) in
            if finalize {
                config.onFinalize = { (state: inout ThrowWriteState, _: LandContext) in
                    state.finalized = 1
                    throw ThrowWriteError()
                }
            }
            if afterFinalize {
                config.afterFinalize = { (_: ThrowWriteState, _: LandContext) async in }
            }
        }
        Rules {
            OnJoin { (state: inout ThrowWriteState, _: LandContext) in
                state.joined += 1
                if failingJoin { throw ThrowWriteError() }
            }
            HandleAction(ThrowWriteAddAction.self) { (state: inout ThrowWriteState, action: ThrowWriteAddAction, _: LandContext) in
                if action.validateFirst, action.fail { throw ThrowWriteError() }
                state.score += action.amount
                if action.fail { throw ThrowWriteError() }
                return ThrowWriteAck(ok: true)
            }
            HandleAction(ThrowWriteOtherAction.self) { (state: inout ThrowWriteState, action: ThrowWriteOtherAction, _: LandContext) throws -> ThrowWriteAck in
                state.score += action.amount
                throw ThrowWriteError()
            }
            // Two handlers for one event: the first writes, the second throws.
            HandleEvent(ThrowWriteBumpEvent.self) { (state: inout ThrowWriteState, event: ThrowWriteBumpEvent, _: LandContext) in
                state.score += event.amount
            }
            HandleEvent(ThrowWriteBumpEvent.self) { (_: inout ThrowWriteState, _: ThrowWriteBumpEvent, _: LandContext) in
                throw ThrowWriteError()
            }
        }
    }
}

// MARK: - Helpers

/// Log records, in order.
private final class ThrowWriteLogRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: Logger.Level, message: String, input: String?)] = []

    func append(_ level: Logger.Level, _ message: String, _ input: String?) {
        lock.withLock { records.append((level, message, input)) }
    }

    /// The `input` of every throwing-input write warning, in order.
    var warnedInputs: [String] {
        lock.withLock {
            records.filter { $0.level == .warning && $0.message.contains("threw after writing state") }
                .map { $0.input ?? "?" }
        }
    }
}

private struct ThrowWriteLogHandler: LogHandler {
    let records: ThrowWriteLogRecords
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var input: String?
        if case .string(let value)? = metadata?["input"] { input = value }
        records.append(level, message.description, input)
    }
}

private struct ThrowWriteFixture {
    let keeper: LandKeeper<ThrowWriteState>
    let records: ThrowWriteLogRecords
    let player = PlayerID("tw-player")
    let client = ClientID("tw-client")
    let session = SessionID("tw-session")

    static func make(failingJoin: Bool = false, finalize: Bool = false, afterFinalize: Bool = false, join: Bool = true) async throws -> ThrowWriteFixture {
        let records = ThrowWriteLogRecords()
        let keeper = LandKeeper<ThrowWriteState>(
            definition: makeThrowWriteLand(failingJoin: failingJoin, finalize: finalize, afterFinalize: afterFinalize),
            initialState: ThrowWriteState(),
            autoStartLoops: false,
            logger: Logger(label: "throw-write-test") { _ in ThrowWriteLogHandler(records: records) }
        )
        let fixture = ThrowWriteFixture(keeper: keeper, records: records)
        if join {
            try await keeper.join(playerID: fixture.player, clientID: fixture.client, sessionID: fixture.session)
        }
        return fixture
    }

    func add(_ amount: Int, fail: Bool, validateFirst: Bool = false) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: ThrowWriteAddAction.self),
                payload: AnyCodable(ThrowWriteAddAction(amount: amount, fail: fail, validateFirst: validateFirst))
            ),
            playerID: player, clientID: client, sessionID: session
        )
    }

    func other(_ amount: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: ThrowWriteOtherAction.self),
                payload: AnyCodable(ThrowWriteOtherAction(amount: amount))
            ),
            playerID: player, clientID: client, sessionID: session
        )
    }
}

private let addKey = "action \(String(describing: ThrowWriteAddAction.self))"
private let otherKey = "action \(String(describing: ThrowWriteOtherAction.self))"

// MARK: - Tests

@Suite("A throwing handler's writes are kept; debug builds warn once per input type (#87)")
struct ThrowingInputWriteWarningTests {
    @Test("a handler that writes and then throws keeps its write and warns once per input type")
    func writeThenThrowWarnsOncePerType() async throws {
        let f = try await ThrowWriteFixture.make()
        await #expect(throws: ThrowWriteError.self) { try await f.add(5, fail: true) }
        #expect(await f.keeper.currentState().score == 5, "the write before the throw is kept")
        #expect(f.records.warnedInputs == [addKey])

        // The same type again: no second warning.
        await #expect(throws: ThrowWriteError.self) { try await f.add(2, fail: true) }
        #expect(await f.keeper.currentState().score == 7)
        #expect(f.records.warnedInputs == [addKey])

        // Another type warns on its own.
        await #expect(throws: ThrowWriteError.self) { try await f.other(1) }
        #expect(f.records.warnedInputs == [addKey, otherKey])
    }

    @Test("a handler that throws before its first write doesn't warn")
    func throwBeforeWriteDoesNotWarn() async throws {
        let f = try await ThrowWriteFixture.make()
        try await f.add(3, fail: false)
        await #expect(throws: ThrowWriteError.self) { try await f.add(5, fail: true, validateFirst: true) }
        #expect(await f.keeper.currentState().score == 3, "the state is unchanged by the failed input")
        #expect(f.records.warnedInputs.isEmpty, "warned: \(f.records.warnedInputs)")
    }

    @Test("an event whose second handler throws after the first wrote warns; so does a join whose OnJoin wrote")
    func eventAndJoinWritesBeforeAThrowWarn() async throws {
        let f = try await ThrowWriteFixture.make()
        // No transport, so the event is applied from a task of its own (the legacy path): its
        // caller doesn't get the handler's error. Wait for that task, not for time.
        try await f.keeper.handleClientEvent(
            AnyClientEvent(ThrowWriteBumpEvent(amount: 4)),
            playerID: f.player, clientID: f.client, sessionID: f.session
        )
        await f.keeper.waitForInFlightWorkForTesting()
        #expect(await f.keeper.currentState().score == 4)
        let eventType = AnyClientEvent(ThrowWriteBumpEvent(amount: 0)).type
        #expect(f.records.warnedInputs == ["event \(eventType)"], "warned: \(f.records.warnedInputs)")

        // A discarded join's writes stay and reach the other players.
        let j = try await ThrowWriteFixture.make(failingJoin: true, join: false)
        // The join is discarded; how its caller learns that isn't what this test is about.
        _ = try? await j.keeper.join(playerID: j.player, clientID: j.client, sessionID: j.session)
        #expect(await j.keeper.currentState().joined == 1, "the failed OnJoin's write is kept")
        #expect(j.records.warnedInputs == ["OnJoin"])
    }

    @Test("with the check turned off, a write and then a throw doesn't warn")
    func switchOffDoesNotWarn() async throws {
        let f = try await ThrowWriteFixture.make()
        await f.keeper.setWarnsThrowingInputWritesForTesting(false)
        await #expect(throws: ThrowWriteError.self) { try await f.add(5, fail: true) }
        #expect(await f.keeper.currentState().score == 5)
        #expect(f.records.warnedInputs.isEmpty, "warned: \(f.records.warnedInputs)")
        #expect(!ThrowingInputWriteCheck.isEnabled(environment: [EnvKeys.Debug.warnThrowingInputWrites: "false"]))
        #expect(ThrowingInputWriteCheck.isEnabled(environment: [:]))
    }

    @Test(
        "a throwing OnFinalize warns only when a later destroy-phase handler reads the state",
        arguments: [false, true]
    )
    func finalizeWarnsOnlyWhenStateIsReadAfterwards(afterFinalize: Bool) async throws {
        let f = try await ThrowWriteFixture.make(finalize: true, afterFinalize: afterFinalize)
        await f.keeper.forceShutdown()
        #expect(f.records.warnedInputs == (afterFinalize ? ["OnFinalize"] : []), "warned: \(f.records.warnedInputs)")
    }
}

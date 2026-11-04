// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncPhaseTests.swift
//
// The sync phase as plan + commit: a plan is synchronous and stages its cache updates instead of
// writing them; its commit writes the staged caches, removes the consumed events, applies the
// metric updates and enqueues the frames. A plan that fails (any throw, including an encode
// failure) commits nothing, so the caches still hold what every client was last sent. Its
// `beginSync` already cleared the dirty flags, so the next plan is a recovery cycle: `.all`
// extraction against the cached baseline (deletions included), every recipient's update typed
// `.firstSync` so the encoders and the client reset the scope's dynamic key table.
//
// Failures are injected deterministically: a fault hook that throws at the end of a plan (after
// its diffs were staged and every frame was encoded), or an encoder that fails on demand.
//
// The client model decodes all three encodings the way the TypeScript SDK does: opcode 107
// frames use the broadcast key map, plain state frames the per-player key map, a firstSync clears
// the map it is decoded with, a slot used before its definition is an error, and every update
// (firstSync included) is applied onto the existing view.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test state and action

@StateNodeBuilder
struct SyncPhaseTestState: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.broadcast) var b: Int = 0
    @Sync(.broadcast) var items: [String: Int] = [:]
    @Sync(.broadcast) var ratios: [String: Double] = [:]
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var bonuses: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var bags: [PlayerID: [String: Int]] = [:]
    @Sync(.perPlayerSlice()) var speeds: [PlayerID: Double] = [:]
    init() {}
}

@Payload
struct SyncPhaseSetAction: ActionPayload {
    typealias Response = SyncPhaseSetResponse
    /// "a", "b", "score", "bonus" (the calling player's `scores` / `bonuses` entry), "unscore"
    /// (remove it), "item:<key>" / "unitem:<key>" (broadcast `items`), "bag:<key>" /
    /// "unbag:<key>" (the calling player's `bags` entry), "ratio:<key>" / "nanratio:<key>"
    /// (broadcast `ratios`: the value, or NaN, which JSON cannot encode), "speed" / "infspeed"
    /// (the calling player's `speeds` entry: the value, or infinity, which JSON cannot encode).
    let field: String
    let value: Int
}

@Payload
struct SyncPhaseSetResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct SyncPhaseEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

/// - Parameter periodicSync: Periodic sync configured but far apart (no follow-up cycles, no
///   timer cycles). Without it the land has no periodic sync, so a failed plan schedules a
///   delayed follow-up.
private func makeSyncPhaseLand(periodicSync: Bool = true) -> LandDefinition<SyncPhaseTestState> {
    if periodicSync {
        return Land("sync-phase-test", using: SyncPhaseTestState.self) {
            ServerEvents { Register(SyncPhaseEvent.self) }
            Lifetime {
                StateSync(every: .seconds(3600)) { (_: SyncPhaseTestState, _: LandContext) in }
            }
            syncPhaseRules()
        }
    }
    return Land("sync-phase-test", using: SyncPhaseTestState.self) {
        ServerEvents { Register(SyncPhaseEvent.self) }
        syncPhaseRules()
    }
}

private func syncPhaseRules() -> RulesNode {
        Rules {
            OnJoin { (state: inout SyncPhaseTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
                state.bonuses[ctx.playerID] = 0
            }
            HandleAction(SyncPhaseSetAction.self) { (state: inout SyncPhaseTestState, action: SyncPhaseSetAction, ctx: LandContext) in
                let parts = action.field.split(separator: ":", maxSplits: 1).map(String.init)
                let key = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "a": state.a = action.value
                case "b": state.b = action.value
                case "bonus": state.bonuses[ctx.playerID] = action.value
                case "unscore": state.scores.removeValue(forKey: ctx.playerID)
                case "item": state.items[key] = action.value
                case "unitem": state.items.removeValue(forKey: key)
                case "bag": state.bags[ctx.playerID, default: [:]][key] = action.value
                case "unbag": state.bags[ctx.playerID]?.removeValue(forKey: key)
                case "ratio": state.ratios[key] = Double(action.value)
                case "nanratio": state.ratios[key] = .nan
                case "speed": state.speeds[ctx.playerID] = Double(action.value)
                case "infspeed": state.speeds[ctx.playerID] = .infinity
                default: state.scores[ctx.playerID] = action.value
                }
                return SyncPhaseSetResponse(ok: true)
            }
        }
}

// MARK: - Encodings and path hashes

enum SyncPhaseEncoding: String, CaseIterable, Sendable, CustomStringConvertible {
    case json
    case opcodeJsonArray
    case messagepack

    var description: String { rawValue }
}

private let syncPhasePathPatterns = [
    "a", "b", "items", "items.*", "ratios", "ratios.*", "scores", "scores.*", "bonuses", "bonuses.*", "bags", "bags.*", "bags.*.*", "speeds", "speeds.*"
]

private let syncPhasePathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: syncPhasePathPatterns.map { ($0, DeterministicHash.fnv1a32($0)) }
)

// MARK: - Transport, encoder, fault

/// Records every frame per session.
private actor SyncPhaseTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            sent.append((target, data))
        }
    }

    func messages(for sessionID: SessionID) -> [Data] {
        sent.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
}

private struct SyncPhaseFault: Error {}

/// A player whose per-player-scope updates all fail to encode while set (any update type).
private final class SyncPhaseFailingPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var player: PlayerID?
    var current: PlayerID? { lock.lock(); defer { lock.unlock() }; return player }
    func set(_ value: PlayerID?) { lock.lock(); player = value; lock.unlock() }
}

/// A switch the tests flip from outside the adapter.
private final class SyncPhaseSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
}

/// Wraps a real encoder; while `failDiffs` is on, every per-player-scope `.diff` update fails
/// (firstSync, `.noChange` and the broadcast-scope opcode 107 state still encode).
private struct FailingDiffEncoder: StateUpdateEncoderWithScope {
    let inner: any StateUpdateEncoder
    let failDiffs: SyncPhaseSwitch
    let failingPlayer: SyncPhaseFailingPlayer

    var encoding: StateUpdateEncoding { inner.encoding }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: nil, scope: .perPlayer)
    }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: .perPlayer)
    }

    func encode(
        update: StateUpdate,
        landID: String,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data {
        if case .diff = update, case .perPlayer = scope, failDiffs.isOn {
            throw SyncPhaseFault()
        }
        if case .perPlayer = scope, failingPlayer.current == playerID {
            throw SyncPhaseFault()
        }
        if let scoped = inner as? StateUpdateEncoderWithScope {
            return try scoped.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: scope)
        }
        return try inner.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot)
    }
}

// MARK: - Client-side model

/// A decoded wire value (JSON or MessagePack).
private indirect enum SyncPhaseWire {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SyncPhaseWire])
    case map([String: SyncPhaseWire])

    init(json: Any) {
        if let s = json as? String {
            self = .string(s)
        } else if let a = json as? [Any] {
            self = .array(a.map(SyncPhaseWire.init(json:)))
        } else if let m = json as? [String: Any] {
            self = .map(m.mapValues(SyncPhaseWire.init(json:)))
        } else if let n = json as? NSNumber {
            // The test state has no Bool or fractional values.
            self = n.doubleValue == Double(n.intValue) ? .int(n.intValue) : .double(n.doubleValue)
        } else {
            self = .null
        }
    }

    init(msgpack: MessagePackValue) {
        switch msgpack {
        case .bool(let v): self = .bool(v)
        case .int(let v): self = .int(Int(v))
        case .uint(let v): self = .int(Int(v))
        case .float(let v): self = .double(Double(v))
        case .double(let v): self = .double(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(SyncPhaseWire.init(msgpack:)))
        case .map(let v):
            var map: [String: SyncPhaseWire] = [:]
            for (key, value) in v {
                if case .string(let k) = key { map[k] = SyncPhaseWire(msgpack: value) }
            }
            self = .map(map)
        default: self = .null
        }
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var snapshotValue: SnapshotValue {
        switch self {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .string(let v): return .string(v)
        case .array(let v): return .array(v.map(\.snapshotValue))
        case .map(let v): return .object(v.mapValues(\.snapshotValue))
        }
    }
}

private struct SyncPhaseDecodeError: Error, CustomStringConvertible {
    let description: String
}

/// One session's client, decoding like the TypeScript SDK (see the file header).
private struct SyncPhaseClient {
    let encoding: SyncPhaseEncoding
    var view: [String: SnapshotValue] = [:]
    /// State update opcodes in arrival order: 0 noChange, 1 firstSync, 2 diff.
    var updateTypes: [Int] = []
    var decodeErrors: [String] = []
    private var broadcastKeys: [Int: String] = [:]
    private var perPlayerKeys: [Int: String] = [:]
    private let hashToPattern = Dictionary(uniqueKeysWithValues: syncPhasePathHashes.map { (Int($1), $0) })

    init(encoding: SyncPhaseEncoding) {
        self.encoding = encoding
    }

    mutating func receive(_ frames: [Data]) {
        for frame in frames {
            do {
                try receive(frame)
            } catch {
                decodeErrors.append("\(error)")
            }
        }
    }

    private mutating func receive(_ frame: Data) throws {
        switch encoding {
        case .json:
            // Join responses and events are not state updates.
            guard let decoded = try? JSONStateUpdateDecoder().decode(data: frame) else { return }
            switch decoded.update {
            case .noChange:
                updateTypes.append(0)
            case .firstSync(let patches):
                updateTypes.append(1)
                apply(patches)
            case .diff(let patches):
                updateTypes.append(2)
                apply(patches)
            }
        case .opcodeJsonArray:
            guard let json = try? JSONSerialization.jsonObject(with: frame),
                  let array = json as? [Any],
                  let opcode = (array.first as? NSNumber)?.intValue,
                  (0...2).contains(opcode) else { return }
            try applyStateArray(array.map(SyncPhaseWire.init(json:)), broadcastScope: false)
        case .messagepack:
            guard let value = try? unpack(frame),
                  case .array(let array) = value,
                  let opcode = array.first.flatMap({ SyncPhaseWire(msgpack: $0).intValue }) else { return }
            let wire = array.map(SyncPhaseWire.init(msgpack:))
            if opcode == 107 {
                guard wire.count >= 2, case .array(let state) = wire[1] else {
                    throw SyncPhaseDecodeError(description: "invalid opcode 107 frame")
                }
                try applyStateArray(state, broadcastScope: true)
            } else if (0...2).contains(opcode) {
                try applyStateArray(wire, broadcastScope: false)
            }
        }
    }

    private mutating func applyStateArray(_ array: [SyncPhaseWire], broadcastScope: Bool) throws {
        var keys = broadcastScope ? broadcastKeys : perPlayerKeys
        defer {
            if broadcastScope { broadcastKeys = keys } else { perPlayerKeys = keys }
        }
        guard let opcode = array.first?.intValue else {
            throw SyncPhaseDecodeError(description: "state update without opcode")
        }
        if opcode == 1 {
            keys.removeAll()
        }
        updateTypes.append(opcode)
        var patches: [StatePatch] = []
        for entry in array.dropFirst() {
            guard case .array(let parts) = entry, parts.count >= 2 else {
                throw SyncPhaseDecodeError(description: "invalid patch entry")
            }
            let path: String
            let op: Int?
            let value: SyncPhaseWire?
            if case .string(let legacyPath) = parts[0] {
                path = legacyPath
                op = parts[1].intValue
                value = parts.count > 2 ? parts[2] : nil
            } else {
                guard let hash = parts[0].intValue, let pattern = hashToPattern[hash] else {
                    throw SyncPhaseDecodeError(description: "unknown path hash \(parts[0])")
                }
                let dynamicKeys = try resolveDynamicKeys(parts[1], keys: &keys)
                path = reconstructPath(pattern, dynamicKeys)
                op = parts.count > 2 ? parts[2].intValue : nil
                value = parts.count > 3 ? parts[3] : nil
            }
            switch op {
            case StatePatchOpcode.set.rawValue:
                patches.append(StatePatch(path: path, operation: .set(value?.snapshotValue ?? .null)))
            case StatePatchOpcode.remove.rawValue:
                patches.append(StatePatch(path: path, operation: .delete))
            case StatePatchOpcode.add.rawValue:
                patches.append(StatePatch(path: path, operation: .add(value?.snapshotValue ?? .null)))
            default:
                throw SyncPhaseDecodeError(description: "unknown patch opcode \(String(describing: op))")
            }
        }
        apply(patches)
    }

    private func resolveOneKey(_ raw: SyncPhaseWire, keys: inout [Int: String]) throws -> String? {
        switch raw {
        case .null:
            return nil
        case .string(let key):
            return key
        case .int(let slot):
            guard let key = keys[slot] else {
                throw SyncPhaseDecodeError(description: "Dynamic key slot \(slot) used before definition")
            }
            return key
        case .array(let pair):
            guard pair.count == 2, let slot = pair[0].intValue, case .string(let key) = pair[1] else {
                throw SyncPhaseDecodeError(description: "invalid dynamic key definition")
            }
            keys[slot] = key
            return key
        default:
            throw SyncPhaseDecodeError(description: "invalid dynamic key")
        }
    }

    private func resolveDynamicKeys(_ raw: SyncPhaseWire, keys: inout [Int: String]) throws -> [String] {
        if case .array(let items) = raw {
            let isSingleDefinition = items.count == 2 && items[0].intValue != nil && { if case .string = items[1] { return true }; return false }()
            if !isSingleDefinition {
                return try items.compactMap { try resolveOneKey($0, keys: &keys) }
            }
        }
        return try resolveOneKey(raw, keys: &keys).map { [$0] } ?? []
    }

    private func reconstructPath(_ pattern: String, _ dynamicKeys: [String]) -> String {
        var remaining = dynamicKeys[...]
        let components = pattern.split(separator: ".").map { component -> String in
            if component == "*", let key = remaining.popFirst() { return key }
            return String(component)
        }
        return "/" + components.joined(separator: "/")
    }

    private mutating func apply(_ patches: [StatePatch]) {
        for patch in patches {
            let parts = patch.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            switch patch.operation {
            case .set(let value), .add(let value): view = Self.setting(view, parts[...], value)
            case .delete: view = Self.deleting(view, parts[...])
            }
        }
    }

    private static func setting(_ obj: [String: SnapshotValue], _ parts: ArraySlice<String>, _ value: SnapshotValue) -> [String: SnapshotValue] {
        var obj = obj
        let key = parts[parts.startIndex]
        if parts.count == 1 { obj[key] = value; return obj }
        let child = obj[key]?.objectValue ?? [:]
        obj[key] = .object(setting(child, parts.dropFirst(), value))
        return obj
    }

    private static func deleting(_ obj: [String: SnapshotValue], _ parts: ArraySlice<String>) -> [String: SnapshotValue] {
        var obj = obj
        let key = parts[parts.startIndex]
        if parts.count == 1 { obj[key] = nil; return obj }
        guard let child = obj[key]?.objectValue else { return obj }
        obj[key] = .object(deleting(child, parts.dropFirst()))
        return obj
    }

    /// The value at a JSON Pointer path, `nil` when absent.
    func value(at path: String) -> SnapshotValue? {
        var current: SnapshotValue? = .object(view)
        for part in path.split(separator: "/").map(String.init) {
            current = current?.objectValue?[part]
        }
        return current
    }
}

// MARK: - Fixture

private func makeSyncPhaseEnvConfig(useSnapshotForSync: Bool) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: useSnapshotForSync,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil
    )
}

private struct SyncPhaseFixture {
    let encoding: SyncPhaseEncoding
    let keeper: LandKeeper<SyncPhaseTestState>
    let adapter: TransportAdapter<SyncPhaseTestState>
    let transport: SyncPhaseTransport
    /// While on, the encoder fails every per-player `.diff` update (see `FailingDiffEncoder`).
    let diffEncodingFails: SyncPhaseSwitch
    /// While set, every per-player update of that player fails to encode (deterministic).
    let failingPlayer: SyncPhaseFailingPlayer
    let session = SessionID("sp-session")
    let client = ClientID("sp-client")
    let player = PlayerID("sp-player")
    let session2 = SessionID("sp-session-2")
    let client2 = ClientID("sp-client-2")
    let player2 = PlayerID("sp-player-2")

    /// - Parameters:
    ///   - encoding: State update encoding; opcode encodings use the test path hashes.
    ///   - realMessagePack: messagepack only: the production configuration (MessagePack
    ///     messages, so events are queued for the next cycle) instead of the failing-on-demand
    ///     wrapper around the MessagePack state encoder.
    ///   - periodicSync: see `makeSyncPhaseLand(periodicSync:)`.
    ///   - join: run the join (and its firstSync) before returning.
    static func make(
        encoding: SyncPhaseEncoding = .json,
        useSnapshotForSync: Bool = true,
        realMessagePack: Bool = false,
        periodicSync: Bool = true,
        join: Bool = true
    ) async throws -> SyncPhaseFixture {
        let transport = SyncPhaseTransport()
        let keeper = LandKeeper<SyncPhaseTestState>(
            definition: makeSyncPhaseLand(periodicSync: periodicSync),
            initialState: SyncPhaseTestState()
        )
        let failDiffs = SyncPhaseSwitch()
        let failingPlayer = SyncPhaseFailingPlayer()
        let hasher = PathHasher(pathHashes: syncPhasePathHashes)
        let envConfig = makeSyncPhaseEnvConfig(useSnapshotForSync: useSnapshotForSync)
        let adapter: TransportAdapter<SyncPhaseTestState>
        if encoding == .messagepack && realMessagePack {
            adapter = TransportAdapter<SyncPhaseTestState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-phase-test",
                transportEnvConfig: envConfig,
                encodingConfig: .messagepack,
                pathHashes: syncPhasePathHashes
            )
        } else {
            let inner: any StateUpdateEncoder
            switch encoding {
            case .json: inner = JSONStateUpdateEncoder()
            case .opcodeJsonArray: inner = OpcodeJSONStateUpdateEncoder(pathHasher: hasher)
            case .messagepack: inner = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher)
            }
            adapter = TransportAdapter<SyncPhaseTestState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-phase-test",
                transportEnvConfig: envConfig,
                stateUpdateEncoder: FailingDiffEncoder(inner: inner, failDiffs: failDiffs, failingPlayer: failingPlayer),
                pathHashes: encoding == .json ? nil : syncPhasePathHashes
            )
        }
        await transport.setDelegate(adapter)
        let fixture = SyncPhaseFixture(
            encoding: encoding,
            keeper: keeper,
            adapter: adapter,
            transport: transport,
            diffEncodingFails: failDiffs,
            failingPlayer: failingPlayer
        )
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        if join {
            try await fixture.join()
        }
        return fixture
    }

    func join() async throws {
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: session,
            clientID: client,
            playerID: player
        )
    }

    /// Connects and joins the second session (`session2` / `player2`).
    func joinSecond() async throws {
        await adapter.onConnect(sessionID: session2, clientID: client2)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: session2,
            clientID: client2,
            playerID: player2
        )
    }

    /// Runs the action as `player`, or as `player2` when `second` is set.
    func set(_ field: String, _ value: Int = 0, second: Bool = false) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: SyncPhaseSetAction.self),
            payload: AnyCodable(SyncPhaseSetAction(field: field, value: value))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: second ? player2 : player,
            clientID: second ? client2 : client,
            sessionID: second ? session2 : session
        )
    }

    func sync() async {
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    /// Makes the next plan (any kind) throw at its end; later plans run normally.
    func failNextPlan() async {
        let fired = SyncPhaseSwitch()
        await adapter.setSyncPlanFaultForTesting {
            guard !fired.isOn else { return }
            fired.set(true)
            throw SyncPhaseFault()
        }
    }

    func frameCount() async -> Int {
        await transport.messages(for: session).count
    }

    /// The client of `session` (or `session2`), fed every frame the session received.
    func clientState(second: Bool = false) async -> SyncPhaseClient {
        var client = SyncPhaseClient(encoding: encoding)
        client.receive(await transport.messages(for: second ? session2 : session))
        return client
    }

    /// The authoritative view of `player` (or `player2`).
    func serverView(second: Bool = false) async throws -> [String: SnapshotValue] {
        try SyncEngine().snapshot(for: second ? player2 : player, from: await keeper.currentState()).values
    }

    func queueEvent(_ message: String, to target: SwiftStateTree.EventTarget) async {
        await adapter.sendEvent(AnyServerEvent(SyncPhaseEvent(message: message)), to: target)
    }

    /// The client (of `session2` when `second` is set) must have decoded every frame and must
    /// equal the server view.
    func expectConverged(
        _ label: String,
        second: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> SyncPhaseClient {
        let client = await clientState(second: second)
        let server = try await serverView(second: second)
        #expect(client.decodeErrors.isEmpty, "\(label): decode errors \(client.decodeErrors)", sourceLocation: sourceLocation)
        #expect(client.view == server, "\(label): client \(client.view) must equal server \(server)", sourceLocation: sourceLocation)
        return client
    }
}

private func count(_ message: String, in frames: [Data]) -> Int {
    let marker = Data(message.utf8)
    return frames.filter { $0.range(of: marker) != nil }.count
}

// MARK: - Tests

@Suite("TransportAdapter sync phase: plan + commit", .timeLimit(.minutes(1)))
struct TransportAdapterSyncPhaseTests {

    @Test(
        "a plan that throws after the dirty flags were cleared: the next cycle delivers the change",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func throwingPlanAfterClearIsRecoveredNextCycle(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, useSnapshotForSync: useSnapshotForSync)
        await f.sync()

        try await f.set("a", 1)
        try await f.set("score", 5)
        let framesBefore = await f.frameCount()
        await f.failNextPlan()
        await f.sync()
        #expect(await f.frameCount() == framesBefore, "a failed plan enqueues nothing")
        #expect(await f.keeper.currentState().isDirty() == false, "precondition: beginSync cleared the dirty flags")
        #expect(await f.adapter.isSyncRecoveryPending(), "a failed plan requests a recovery cycle")

        // Another field of each category is dirty, so without recovery the next cycle would be a
        // dirty-tracking cycle that misses a and score.
        try await f.set("b", 2)
        try await f.set("bonus", 3)
        let updatesBefore = await f.clientState().updateTypes.count
        await f.sync()

        let client = try await f.expectConverged("after recovery")
        #expect(client.value(at: "/a") == .int(1), "broadcast change of the failed cycle must arrive")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(5), "per-player change of the failed cycle must arrive")
        let recoveryTypes = Array(client.updateTypes.dropFirst(updatesBefore))
        #expect(!recoveryTypes.isEmpty && recoveryTypes.allSatisfy { $0 == 1 }, "recovery updates are typed firstSync: \(recoveryTypes)")
        #expect(await f.adapter.isSyncRecoveryPending() == false, "the recovery cycle's commit ends the recovery")
        #expect(await f.adapter.syncRecoveryCycles == 1)
    }

    @Test(
        "a failed plan leaves every cache and firstSync mark untouched",
        arguments: SyncPhaseEncoding.allCases
    )
    func failedPlanLeavesCachesUntouched(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        try await f.set("a", 1)
        try await f.set("score", 5)
        try await f.set("item:x", 1)
        try await f.set("bag:sword", 1)
        let before = await f.adapter.syncEngineForTesting()
        await f.failNextPlan()
        await f.sync()
        let after = await f.adapter.syncEngineForTesting()

        #expect(before.cachedBroadcastSnapshotForTesting != nil, "precondition: the broadcast cache is populated")
        #expect(after.cachedBroadcastSnapshotForTesting == before.cachedBroadcastSnapshotForTesting)
        #expect(after.cachedPerPlayerSnapshotForTesting(f.player) == before.cachedPerPlayerSnapshotForTesting(f.player))
        #expect(after.hasReceivedFirstSyncForTesting(f.player))
    }

    @Test("a failed firstSync plan leaves the joiner's caches and mark untouched", arguments: SyncPhaseEncoding.allCases)
    func failedFirstSyncPlanLeavesCachesUntouched(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, join: false)
        await f.failNextPlan()
        try await f.join()
        let engine = await f.adapter.syncEngineForTesting()
        #expect(engine.cachedBroadcastSnapshotForTesting == nil)
        #expect(engine.cachedPerPlayerSnapshotForTesting(f.player) == nil)
        #expect(engine.hasReceivedFirstSyncForTesting(f.player) == false)
    }

    @Test(
        "keys removed in a failed cycle (top-level and nested, broadcast and per-player) are removed by the recovery",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func removalsOfAFailedCycleAreRecovered(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, useSnapshotForSync: useSnapshotForSync)
        try await f.set("item:x", 1)
        try await f.set("item:y", 2)
        try await f.set("bag:sword", 1)
        try await f.set("bag:shield", 2)
        try await f.set("score", 5)
        await f.sync()
        let seeded = try await f.expectConverged("seeded")
        let me = f.player.rawValue
        #expect(seeded.value(at: "/items/x") == .int(1), "precondition")
        #expect(seeded.value(at: "/bags/\(me)/sword") == .int(1), "precondition")
        #expect(seeded.value(at: "/scores/\(me)") == .int(5), "precondition")

        try await f.set("unitem:x")       // broadcast, nested key
        try await f.set("unbag:sword")    // per-player, nested key
        try await f.set("unscore")        // per-player, the slice's top-level entry
        await f.failNextPlan()
        await f.sync()

        try await f.set("b", 1)
        await f.sync()

        let client = try await f.expectConverged("after recovery")
        #expect(client.value(at: "/items/x") == nil, "broadcast nested key must be removed")
        #expect(client.value(at: "/items/y") == .int(2))
        #expect(client.value(at: "/bags/\(me)/sword") == nil, "per-player nested key must be removed")
        #expect(client.value(at: "/bags/\(me)/shield") == .int(2))
        #expect(client.value(at: "/scores/\(me)") == nil, "per-player top-level entry must be removed")
    }

    @Test(
        "a dynamic-key slot allocated by a failed encode is redefined by the recovery",
        arguments: [SyncPhaseEncoding.opcodeJsonArray, .messagepack]
    )
    func slotAllocatedByFailedEncodeIsRedefined(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        // First use of "k1": the failed plan's encode allocates its slot; the frame never leaves.
        try await f.set("item:k1", 1)
        await f.failNextPlan()
        await f.sync()

        try await f.set("b", 1)
        await f.sync()
        // A plain diff now refers to "k1" by slot only; the client must know the slot.
        try await f.set("item:k1", 3)
        await f.sync()

        let client = try await f.expectConverged("after recovery and a later diff")
        #expect(client.value(at: "/items/k1") == .int(3))
    }

    @Test("a failed broadcast-only plan is recovered by the next cycle", arguments: SyncPhaseEncoding.allCases)
    func throwingBroadcastOnlyPlanIsRecovered(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        try await f.set("a", 4)
        try await f.set("item:z", 1)
        await f.failNextPlan()
        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        #expect(await f.adapter.isSyncRecoveryPending())

        try await f.set("b", 1)
        await f.sync()

        let client = try await f.expectConverged("after recovery")
        #expect(client.value(at: "/a") == .int(4))
        #expect(client.value(at: "/items/z") == .int(1))
        #expect(await f.adapter.isSyncRecoveryPending() == false)
    }

    @Test("a broadcast-only cycle during a recovery runs the recovery", arguments: SyncPhaseEncoding.allCases)
    func broadcastOnlyCycleRunsPendingRecovery(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        try await f.set("score", 9)
        await f.failNextPlan()
        await f.sync()
        #expect(await f.adapter.isSyncRecoveryPending())

        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")

        let client = try await f.expectConverged("after the broadcast-only cycle")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(9), "a per-player change must arrive too")
        #expect(await f.adapter.isSyncRecoveryPending() == false)
    }

    @Test("an encode failure fails the plan; the next cycle delivers the change", arguments: SyncPhaseEncoding.allCases)
    func encodeFailureIsRecovered(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, useSnapshotForSync: false)
        await f.sync()

        try await f.set("score", 7)
        try await f.set("a", 2)
        let framesBefore = await f.frameCount()
        f.diffEncodingFails.set(true)
        await f.sync()
        f.diffEncodingFails.set(false)
        #expect(await f.frameCount() == framesBefore, "a failed plan enqueues nothing")
        #expect(await f.adapter.isSyncRecoveryPending(), "an encode failure requests a recovery cycle")

        try await f.set("bonus", 1)
        await f.sync()

        let client = try await f.expectConverged("after recovery")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(7))
        #expect(client.value(at: "/a") == .int(2))
        #expect(await f.adapter.isSyncRecoveryPending() == false)
    }

    @Test("a failed firstSync plan: the next cycle gives the joiner its full view", arguments: SyncPhaseEncoding.allCases)
    func throwingFirstSyncPlanIsRecovered(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, join: false)
        await f.failNextPlan()
        try await f.join()
        let stateFrames = await f.clientState().updateTypes
        #expect(stateFrames.isEmpty, "the failed firstSync sends no state update: \(stateFrames)")

        try await f.set("a", 2)
        await f.sync()

        let client = try await f.expectConverged("after the next cycle")
        // In opcode 107 the merged broadcast frame comes first; the per-player frame is the
        // joiner's full view.
        #expect(client.updateTypes.contains(1), "the joiner gets a firstSync: \(client.updateTypes)")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(0))
    }

    @Test(
        "a per-player value that does not encode (infinity, JSON) drops only that patch; the cycle commits",
        arguments: [SyncPhaseEncoding.json, .opcodeJsonArray]
    )
    func unencodablePerPlayerPatchIsDropped(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        try await f.joinSecond()
        try await f.set("bag:k1", 1, second: true)
        await f.sync()

        try await f.set("infspeed", second: true)
        try await f.set("a", 1)
        try await f.set("score", 5)
        try await f.set("score", 6, second: true)
        try await f.set("unbag:k1", second: true)
        await f.sync()
        #expect(await f.adapter.isSyncRecoveryPending() == false, "the plan commits")
        #expect(await f.adapter.syncDroppedUpdates == 1, "only the infinity patch is dropped")
        _ = try await f.expectConverged("the other player")
        let second = await f.clientState(second: true)
        #expect(second.decodeErrors.isEmpty, "decode errors \(second.decodeErrors)")
        #expect(second.value(at: "/a") == .int(1))
        #expect(second.value(at: "/scores/\(f.player2.rawValue)") == .int(6))
        #expect(second.value(at: "/bags/\(f.player2.rawValue)/k1") == nil, "a deletion in the same update")
        #expect(second.value(at: "/speeds/\(f.player2.rawValue)") == nil, "the unencodable value is dropped")

        // The cache holds the value (as before plan + commit): later changes flow, nothing more
        // is dropped, and the field recovers on its next change.
        try await f.set("score", 7, second: true)
        try await f.set("bonus", 3, second: true)
        await f.sync()
        #expect(await f.adapter.syncDroppedUpdates == 1)
        let later = await f.clientState(second: true)
        #expect(later.decodeErrors.isEmpty, "decode errors \(later.decodeErrors)")
        #expect(later.value(at: "/scores/\(f.player2.rawValue)") == .int(7))
        #expect(later.value(at: "/bonuses/\(f.player2.rawValue)") == .int(3))
        try await f.set("speed", 2, second: true)
        await f.sync()
        let fixed = await f.clientState(second: true)
        #expect(fixed.decodeErrors.isEmpty, "decode errors \(fixed.decodeErrors)")
        #expect(fixed.value(at: "/speeds/\(f.player2.rawValue)") != nil)
    }

    @Test(
        "a player whose per-player update never encodes loses only that update; the room and its events go on",
        arguments: SyncPhaseEncoding.allCases
    )
    func failingPlayerUpdateIsDroppedNotRoomWide(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        try await f.joinSecond()
        await f.sync()

        f.failingPlayer.set(f.player2)
        try await f.set("a", 1)
        try await f.set("score", 5)
        try await f.set("score", 6, second: true)
        await f.queueEvent("tg-failing", to: .player(f.player2))
        await f.sync()
        #expect(await f.adapter.isSyncRecoveryPending() == false, "the plan commits")
        #expect(await f.adapter.syncDroppedUpdates > 0, "the drop is counted")
        let first = try await f.expectConverged("the other player")
        #expect(first.value(at: "/a") == .int(1))

        // The failing player keeps its events and, with opcode 107, the broadcast frames (with
        // json / opcodeJsonArray its per-player frame carries the broadcast: lost, as before).
        try await f.set("b", 2)
        await f.sync()
        let failing = await f.clientState(second: true)
        #expect(failing.decodeErrors.isEmpty, "decode errors \(failing.decodeErrors)")
        #expect(count("tg-failing", in: await f.transport.messages(for: f.session2)) == 1, "its targeted event")
        if encoding == .messagepack {
            #expect(failing.value(at: "/b") == .int(2), "broadcast changes still reach it")
        }
        _ = try await f.expectConverged("the other player, later")

        // Once it encodes again, its next changes reach it and decode.
        f.failingPlayer.set(nil)
        try await f.set("a", 3)
        try await f.set("score", 8, second: true)
        await f.sync()
        let fixed = await f.clientState(second: true)
        #expect(fixed.decodeErrors.isEmpty, "decode errors \(fixed.decodeErrors)")
        #expect(fixed.value(at: "/a") == .int(3))
        #expect(fixed.value(at: "/scores/\(f.player2.rawValue)") == .int(8))
        if encoding == .messagepack {
            _ = try await f.expectConverged("the failing player, after", second: true)
        }
    }

    @Test("a value no encoding of it can carry (NaN in a broadcast field, json) degrades to a stale field")
    func roomWideEncodeFailureIsBounded() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .json)
        try await f.joinSecond()
        await f.sync()

        try await f.set("nanratio:k", 0)
        try await f.set("a", 1)
        // The failure hits every recipient: room-wide. One failed plan and
        // `syncRoomWideFailureBound` failed recovery plans, then plans drop what does not encode.
        let bound = TransportAdapter<SyncPhaseTestState>.syncRoomWideFailureBound
        for _ in 0...bound {
            await f.sync()
        }
        #expect(await f.adapter.isSyncRecoveryPending(), "precondition: recovery still failing")
        #expect(await f.adapter.syncDroppedUpdates == 0)
        await f.sync()
        #expect(await f.adapter.isSyncRecoveryPending() == false, "the lossy plan commits")
        #expect(await f.adapter.syncDroppedUpdates > 0, "the drop is counted")

        // Other fields keep converging; only the NaN field is stale.
        try await f.set("b", 2)
        try await f.set("score", 3)
        await f.sync()
        for second in [false, true] {
            let client = await f.clientState(second: second)
            #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
            #expect(client.value(at: "/a") == .int(1))
            #expect(client.value(at: "/b") == .int(2))
            #expect(client.value(at: "/ratios/k") == nil, "the unencodable value is dropped")
        }
        #expect(await f.clientState().value(at: "/scores/\(f.player.rawValue)") == .int(3))

        // Once the value encodes again, plans stop dropping and the field reaches the clients.
        try await f.set("ratio:k", 2)
        await f.sync()
        let droppedBefore = await f.adapter.syncDroppedUpdates
        try await f.set("a", 4)
        await f.sync()
        #expect(await f.adapter.syncDroppedUpdates == droppedBefore, "nothing dropped once it encodes")
        for second in [false, true] {
            let client = await f.clientState(second: second)
            #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
            #expect(client.value(at: "/ratios/k") != nil, "the field is no longer stale")
            #expect(client.value(at: "/a") == .int(4))
        }
    }

    @Test(
        "a 1-player room whose per-player frames never encode degrades instead of freezing",
        arguments: SyncPhaseEncoding.allCases
    )
    func onePlayerRoomFailureIsBounded(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        f.failingPlayer.set(f.player)
        try await f.set("a", 1)
        try await f.set("score", 5)
        let bound = TransportAdapter<SyncPhaseTestState>.syncRoomWideFailureBound
        for _ in 0...bound {
            await f.sync()
        }
        #expect(await f.adapter.isSyncRecoveryPending(), "precondition: recovery still failing")
        await f.sync()
        #expect(await f.adapter.isSyncRecoveryPending() == false, "the lossy plan commits")
        let dropped = await f.adapter.syncDroppedUpdates
        #expect(dropped > 0)

        // Every cycle commits while the failure lasts (the caches advance as before this change).
        try await f.set("b", 2)
        await f.sync()
        #expect(await f.adapter.isSyncRecoveryPending() == false)
        #expect(await f.adapter.syncDroppedUpdates > dropped)
        let degraded = await f.clientState()
        #expect(degraded.decodeErrors.isEmpty, "decode errors \(degraded.decodeErrors)")
        if encoding == .messagepack {
            #expect(degraded.value(at: "/b") == .int(2), "opcode 107: the broadcast frame still flows")
        }

        // Once it encodes again, the next plan (typed firstSync: key scopes reset) delivers the
        // changes. With opcode 107 only per-player frames were dropped and the client converges;
        // with json / opcodeJsonArray the dropped frames carried the broadcast too, and as before
        // this change those values stay stale until they change again.
        f.failingPlayer.set(nil)
        try await f.set("a", 3)
        try await f.set("score", 7)
        await f.sync()
        let client = await f.clientState()
        #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
        #expect(client.value(at: "/a") == .int(3))
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(7))
        if encoding == .messagepack {
            _ = try await f.expectConverged("after the failure ends")
        }
    }

    @Test("a lossy plan drains the event queue (opcode 107, 1-player room)")
    func lossyPlanDrainsEvents() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true)
        await f.sync()

        let player = f.player
        await f.adapter.setSyncEncodeFaultForTesting { $0 == player }
        try await f.set("a", 1)
        let bound = TransportAdapter<SyncPhaseTestState>.syncRoomWideFailureBound
        for _ in 0...bound {
            await f.sync()
        }
        await f.queueEvent("bc-lossy", to: .all)
        await f.queueEvent("tg-lossy", to: .player(f.player))
        let kept = await f.adapter.pendingEventCounts()
        #expect(kept.targeted >= 1 && kept.broadcast >= 1, "precondition: events kept while plans fail")
        await f.sync()
        let drained = await f.adapter.pendingEventCounts()
        #expect(drained.targeted == 0 && drained.broadcast == 0, "the lossy plan consumes the queue")
        let frames = await f.transport.messages(for: f.session)
        #expect(count("bc-lossy", in: frames) == 1)
        #expect(count("tg-lossy", in: frames) == 1)
    }

    @Test("without periodic sync, a failed firstSync plan is retried by a delayed follow-up", arguments: SyncPhaseEncoding.allCases)
    func failedFirstSyncSchedulesFollowUpWithoutPeriodicSync(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, periodicSync: false, join: false)
        await f.failNextPlan()
        try await f.join()
        #expect(await f.adapter.isSyncRecoveryPending(), "precondition: the firstSync plan failed")

        // No sync request after the join: the delayed follow-up gives the joiner its view.
        var synced = false
        for _ in 0..<100 {
            if await f.adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(f.player) {
                synced = true
                break
            }
            try await safeTaskSleep(for: .milliseconds(20))
        }
        #expect(synced, "the follow-up synced the joiner without another sync request")
        #expect(await f.adapter.waitForOutboundDrain())
        let client = try await f.expectConverged("after the follow-up")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(0))
    }

    @Test("without periodic sync, a failed plan schedules a delayed follow-up that recovers", arguments: SyncPhaseEncoding.allCases)
    func failedPlanSchedulesFollowUpWithoutPeriodicSync(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, periodicSync: false)
        await f.sync()

        try await f.set("a", 1)
        await f.failNextPlan()
        await f.adapter.syncNow()
        #expect(await f.adapter.isSyncRecoveryPending(), "precondition: the plan failed")

        // No further sync request: the delayed follow-up runs the recovery.
        var recovered = false
        for _ in 0..<100 {
            if await f.adapter.isSyncRecoveryPending() == false {
                recovered = true
                break
            }
            try await safeTaskSleep(for: .milliseconds(20))
        }
        #expect(recovered, "the follow-up recovered without another sync request")
        #expect(await f.adapter.waitForOutboundDrain())
        let client = try await f.expectConverged("after the follow-up")
        #expect(client.value(at: "/a") == .int(1))
    }

    @Test("a failed plan keeps queued events; the next cycle delivers each once (opcode 107)")
    func throwingPlanKeepsQueuedEvents() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true)
        await f.sync()

        try await f.set("a", 1)
        await f.queueEvent("bc-kept", to: .all)
        await f.queueEvent("tg-kept", to: .player(f.player))
        let before = await f.adapter.pendingEventCounts()
        #expect(before.targeted == 1 && before.broadcast == 1, "precondition: both events queued")
        await f.failNextPlan()
        await f.sync()
        let after = await f.adapter.pendingEventCounts()
        #expect(after.targeted == 1 && after.broadcast == 1, "a failed plan removes no event")

        await f.sync()
        let frames = await f.transport.messages(for: f.session)
        #expect(count("bc-kept", in: frames) == 1, "broadcast event exactly once")
        #expect(count("tg-kept", in: frames) == 1, "targeted event exactly once")
        let drained = await f.adapter.pendingEventCounts()
        #expect(drained.targeted == 0 && drained.broadcast == 0)
        _ = try await f.expectConverged("after recovery")
    }

    @Test("per session: merged frame, then targeted event frames, then the per-player frame (opcode 107)")
    func frameOrderWithinACycle() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true)
        await f.sync()
        let start = await f.frameCount()

        try await f.set("a", 1)
        try await f.set("score", 2)
        await f.queueEvent("tg-order", to: .player(f.player))
        await f.sync()

        let frames = Array(await f.transport.messages(for: f.session).dropFirst(start))
        let kinds: [Int64] = frames.compactMap { frame in
            guard let unpacked = try? unpack(frame),
                  case .array(let array) = unpacked,
                  case .int(let opcode) = array.first else { return nil }
            return opcode
        }
        // 107 merged broadcast, 103 targeted event, 0...2 per-player state update.
        #expect(kinds.count == 3, "frames: \(kinds)")
        #expect(kinds.first == 107, "frames: \(kinds)")
        #expect(kinds.dropFirst().first == 103, "frames: \(kinds)")
        #expect(kinds.last.map { (0...2).contains($0) } == true, "frames: \(kinds)")
    }
}

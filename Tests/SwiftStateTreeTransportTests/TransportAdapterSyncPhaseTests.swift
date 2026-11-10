// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncPhaseTests.swift
//
// The sync phase as plan + commit: a plan is synchronous and stages its cache updates instead of
// writing them; its commit writes the staged caches, removes the consumed events, applies the
// metric updates and enqueues the frames. A plan that fails (any throw, including an encode
// failure) commits nothing, so the caches still hold what every client was last sent. An encode
// failure drops the patches that do not encode and commits; a field whose snapshot conversion
// throws is left out and the rest commits. A plan that still throws (only the test fault hook)
// commits nothing: its dirty fields (cleared by its `beginSync`) are merged into the next plan's,
// and the next committed plan types every recipient's update `.firstSync` so the encoders and the
// client reset the scope's dynamic key table.
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
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Test state and action

/// A value whose snapshot conversion throws while `broken` is set (a deterministic extraction
/// failure, not an encode failure).
struct SyncPhaseFragile: Codable, Sendable, Equatable, SnapshotValueConvertible {
    var broken = false
    var value = 0
    func toSnapshotValue() throws -> SnapshotValue {
        if broken { throw SyncPhaseFault() }
        return .int(value)
    }
}

@StateNodeBuilder
struct SyncPhaseTestState: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.broadcast) var b: Int = 0
    @Sync(.broadcast) var items: [String: Int] = [:]
    @Sync(.broadcast) var ratios: [String: Double] = [:]
    @Sync(.broadcast) var fragile: SyncPhaseFragile = SyncPhaseFragile()
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var bonuses: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var bags: [PlayerID: [String: Int]] = [:]
    @Sync(.perPlayerSlice()) var speeds: [PlayerID: Double] = [:]
    @Sync(.perPlayerSlice()) var pfragiles: [PlayerID: SyncPhaseFragile] = [:]
    init() {}
}

@Payload
struct SyncPhaseSetAction: ActionPayload {
    typealias Response = SyncPhaseSetResponse
    /// "a", "b", "score", "bonus" (the calling player's `scores` / `bonuses` entry), "unscore"
    /// (remove it), "item:<key>" / "unitem:<key>" (broadcast `items`), "bag:<key>" /
    /// "unbag:<key>" (the calling player's `bags` entry), "ratio:<key>" / "nanratio:<key>"
    /// (broadcast `ratios`: the value, or NaN, which JSON cannot encode), "speed" / "infspeed"
    /// (the calling player's `speeds` entry: the value, or infinity, which JSON cannot encode),
    /// "fragile" / "fragileval" (broadcast `fragile`: broken or not, its value), "pfragile" /
    /// "pbreak" / "unpfragile" (the calling player's `pfragiles` entry: its value, broken or
    /// not, remove it).
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
                case "fragile": state.fragile.broken = action.value != 0
                case "fragileval": state.fragile.value = action.value
                case "pfragile": state.pfragiles[ctx.playerID, default: SyncPhaseFragile()].value = action.value
                case "pbreak": state.pfragiles[ctx.playerID]?.broken = action.value != 0
                case "unpfragile": state.pfragiles.removeValue(forKey: ctx.playerID)
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
    "a", "b", "items", "items.*", "ratios", "ratios.*", "fragile", "scores", "scores.*", "bonuses", "bonuses.*", "bags", "bags.*", "bags.*.*", "speeds", "speeds.*", "pfragiles", "pfragiles.*"
]

private let syncPhasePathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: syncPhasePathPatterns.map { ($0, DeterministicHash.fnv1a32($0)) }
)

/// The land's path table from its generated schema, for path indices. The path-index test checks
/// that the hand-written table above has the same patterns.
private func syncPhaseSchemaPathHashes(periodicSync: Bool) throws -> [String: UInt32] {
    let schema = try SchemaGenCLI.generateSchema(
        landDefinitions: [AnyLandDefinition(makeSyncPhaseLand(periodicSync: periodicSync))]
    )
    return try #require(schema.lands["sync-phase-test"]?.pathHashes)
}

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

struct SyncPhaseFault: Error {}

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
    private var client = SnapshotClientView()
    var view: [String: SnapshotValue] { client.fields }
    /// State update opcodes in arrival order: 0 noChange, 1 firstSync, 2 diff.
    var updateTypes: [Int] = []
    var decodeErrors: [String] = []
    private var broadcastKeys: [Int: String] = [:]
    private var perPlayerKeys: [Int: String] = [:]
    /// A patch's numeric path id → its pattern: a 32-bit hash of the hand-written table, or with
    /// `pathIndex` a path index into that hasher's sorted hashes.
    private let pattern: (Int) -> String?

    init(encoding: SyncPhaseEncoding, pathIndex: PathHasher? = nil) {
        self.encoding = encoding
        if let pathIndex {
            let byHash = Dictionary(uniqueKeysWithValues: pathIndex.pathHashes.map { ($1, $0) })
            pattern = { index in pathIndex.hash(atPathIndex: index).flatMap { byHash[$0] } }
        } else {
            let byHash = Dictionary(uniqueKeysWithValues: syncPhasePathHashes.map { (Int($1), $0) })
            pattern = { byHash[$0] }
        }
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
                try client.apply(patches)
            case .diff(let patches):
                updateTypes.append(2)
                try client.apply(patches)
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
                guard let hash = parts[0].intValue, let pattern = pattern(hash) else {
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
        try client.apply(patches)
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

private func makeSyncPhaseEnvConfig(useSnapshotForSync: Bool, fullSnapshot: Bool = false, syncTables: Bool? = nil) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: useSnapshotForSync,
        syncStrategy: fullSnapshot ? .fullSnapshot : .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil
    )
    // nil: the environment's side (`USE_SYNC_TABLES`), so the suite runs on either.
    if let syncTables { config.useSyncTables = syncTables }
    return config
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
    /// The schema's path table when the adapter sends path indices; nil for hashes.
    var pathIndex: PathHasher? = nil
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
        fullSnapshot: Bool = false,
        join: Bool = true,
        pathIndex: Bool = false,
        syncTables: Bool? = nil
    ) async throws -> SyncPhaseFixture {
        // Path indices go through the adapter's own MessagePack encoder, with the schema's table.
        precondition(!pathIndex || (encoding == .messagepack && realMessagePack), "pathIndex needs real MessagePack")
        let indexHasher = pathIndex ? PathHasher(pathHashes: try syncPhaseSchemaPathHashes(periodicSync: periodicSync)) : nil
        let transport = SyncPhaseTransport()
        let keeper = LandKeeper<SyncPhaseTestState>(
            definition: makeSyncPhaseLand(periodicSync: periodicSync),
            initialState: SyncPhaseTestState()
        )
        let failDiffs = SyncPhaseSwitch()
        let failingPlayer = SyncPhaseFailingPlayer()
        let hasher = PathHasher(pathHashes: syncPhasePathHashes)
        let envConfig = makeSyncPhaseEnvConfig(useSnapshotForSync: useSnapshotForSync, fullSnapshot: fullSnapshot, syncTables: syncTables)
        let adapter: TransportAdapter<SyncPhaseTestState>
        if encoding == .messagepack && realMessagePack {
            adapter = TransportAdapter<SyncPhaseTestState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-phase-test",
                transportEnvConfig: envConfig,
                // Path hashes with the hand-written table; with `pathIndex`, indices with the
                // schema's table.
                encodingConfig: TransportEncodingConfig.messagepack.withPathIndex(indexHasher != nil),
                pathHashes: indexHasher?.pathHashes ?? syncPhasePathHashes
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
            failingPlayer: failingPlayer,
            pathIndex: indexHasher
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
    /// Sends the set action as `player` (or `player2`). `from` overrides the sender's client
    /// and session, for a player whose keeper entry is another session of it.
    func set(
        _ field: String,
        _ value: Int = 0,
        second: Bool = false,
        from sender: (client: ClientID, session: SessionID)? = nil
    ) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: SyncPhaseSetAction.self),
            payload: AnyCodable(SyncPhaseSetAction(field: field, value: value))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: second ? player2 : player,
            clientID: sender?.client ?? (second ? client2 : client),
            sessionID: sender?.session ?? (second ? session2 : session)
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
        await clientState(of: second ? session2 : session)
    }

    /// The client of `sessionID`, fed every frame the session received.
    func clientState(of sessionID: SessionID) async -> SyncPhaseClient {
        var client = SyncPhaseClient(encoding: encoding, pathIndex: pathIndex)
        client.receive(await transport.messages(for: sessionID))
        return client
    }

    /// Connects and joins another session of `player`.
    func joinAnotherSessionOfFirstPlayer(_ sessionID: SessionID, clientID: ClientID) async throws {
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: sessionID,
            clientID: clientID,
            playerID: player
        )
    }

    /// The authoritative view of `player` (or `player2`). A broken `fragile` field (or
    /// `pfragiles` entry) reads as its value, which is what clients keep while it is dropped if
    /// they had it.
    func serverView(second: Bool = false) async throws -> [String: SnapshotValue] {
        var state = await keeper.currentState()
        state.fragile.broken = false
        for key in state.pfragiles.keys {
            state.pfragiles[key]?.broken = false
        }
        return try SyncEngine(for: type(of: state)).snapshot(for: second ? player2 : player, from: state).values
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
        "a plan that throws after the dirty flags were cleared: its dirty fields carry over, the next cycle delivers the change typed firstSync",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func throwingPlanAfterClearIsDeliveredNextCycle(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, useSnapshotForSync: useSnapshotForSync)
        await f.sync()

        try await f.set("a", 1)
        try await f.set("score", 5)
        let framesBefore = await f.frameCount()
        await f.failNextPlan()
        await f.sync()
        #expect(await f.frameCount() == framesBefore, "a failed plan enqueues nothing")
        #expect(await f.keeper.currentState().isDirty() == false, "precondition: beginSync cleared the dirty flags")
        #expect(await f.adapter.isKeyScopeResetPending(), "a failed plan requests a key scope reset")
        #expect(await f.adapter.carriedDirtyFieldsForTesting().isSuperset(of: ["a", "scores"]), "its dirty fields carry over")

        // Another field of each category is dirty, so without the carried fields the next cycle
        // would be a dirty-tracking cycle that misses a and score.
        try await f.set("b", 2)
        try await f.set("bonus", 3)
        let updatesBefore = await f.clientState().updateTypes.count
        await f.sync()

        let client = try await f.expectConverged("after the next cycle")
        #expect(client.value(at: "/a") == .int(1), "broadcast change of the failed cycle must arrive")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(5), "per-player change of the failed cycle must arrive")
        let resetTypes = Array(client.updateTypes.dropFirst(updatesBefore))
        #expect(!resetTypes.isEmpty && resetTypes.allSatisfy { $0 == 1 }, "the next updates are typed firstSync: \(resetTypes)")
        #expect(await f.adapter.isKeyScopeResetPending() == false, "the commit ends the pending reset")
        #expect(await f.adapter.carriedDirtyFieldsForTesting().isEmpty, "the commit ends the carry")
        #expect(await f.adapter.syncFailedPlans == 1)
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
        // The broadcast cache, or the typed tables as a snapshot when the diff runs on them.
        let broadcastBefore = await f.adapter.lastSentBroadcastSnapshotForTesting()
        await f.failNextPlan()
        await f.sync()
        let after = await f.adapter.syncEngineForTesting()
        let broadcastAfter = await f.adapter.lastSentBroadcastSnapshotForTesting()

        #expect(broadcastBefore != nil, "precondition: the broadcast cache is populated")
        #expect(broadcastAfter == broadcastBefore)
        #expect(after.cachedPerPlayerSnapshotForTesting(f.player) == before.cachedPerPlayerSnapshotForTesting(f.player))
        #expect(after.hasReceivedFirstSyncForTesting(f.player))
    }

    @Test("a failed firstSync plan leaves the joiner's caches and mark untouched", arguments: SyncPhaseEncoding.allCases)
    func failedFirstSyncPlanLeavesCachesUntouched(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, join: false)
        await f.failNextPlan()
        try await f.join()
        let engine = await f.adapter.syncEngineForTesting()
        #expect(await f.adapter.lastSentBroadcastSnapshotForTesting() == nil)
        #expect(engine.cachedPerPlayerSnapshotForTesting(f.player) == nil)
        #expect(engine.hasReceivedFirstSyncForTesting(f.player) == false)
    }

    @Test(
        "keys removed in a failed cycle (top-level and nested, broadcast and per-player) are removed by the next cycle",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func removalsOfAFailedCycleAreDeliveredNextCycle(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
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

        let client = try await f.expectConverged("after the next cycle")
        #expect(client.value(at: "/items/x") == nil, "broadcast nested key must be removed")
        #expect(client.value(at: "/items/y") == .int(2))
        #expect(client.value(at: "/bags/\(me)/sword") == nil, "per-player nested key must be removed")
        #expect(client.value(at: "/bags/\(me)/shield") == .int(2))
        #expect(client.value(at: "/scores/\(me)") == nil, "per-player top-level entry must be removed")
    }

    @Test(
        "a dynamic-key slot allocated by a plan that failed after encoding is redefined by the next committed plan",
        arguments: [SyncPhaseEncoding.opcodeJsonArray, .messagepack]
    )
    func slotAllocatedByFailedEncodeIsRedefined(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        // First use of "k1": the failed plan's encode allocates its slot; the frame never leaves.
        try await f.set("item:k1", 1)
        await f.failNextPlan()
        await f.sync()
        #expect(await f.adapter.isKeyScopeResetPending(), "precondition: the plan failed after its encodes")

        // A normal, dirty-only cycle (b, plus the carried items): typed firstSync, it resets the
        // key tables and defines k1.
        try await f.set("b", 1)
        await f.sync()
        #expect(await f.adapter.isKeyScopeResetPending() == false)
        // A plain diff now refers to "k1" by slot only; the client must know the slot.
        try await f.set("item:k1", 3)
        await f.sync()

        let client = try await f.expectConverged("after the reset and a later diff")
        #expect(client.value(at: "/items/k1") == .int(3))
    }

    @Test("a failed broadcast-only plan: the next cycle delivers its changes", arguments: SyncPhaseEncoding.allCases)
    func throwingBroadcastOnlyPlanIsDeliveredNextCycle(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        try await f.set("a", 4)
        try await f.set("item:z", 1)
        await f.failNextPlan()
        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        #expect(await f.adapter.isKeyScopeResetPending())

        try await f.set("b", 1)
        await f.sync()

        let client = try await f.expectConverged("after the next cycle")
        #expect(client.value(at: "/a") == .int(4))
        #expect(client.value(at: "/items/z") == .int(1))
        #expect(await f.adapter.isKeyScopeResetPending() == false)
    }

    @Test("a broadcast-only cycle after a failed plan runs a full cycle", arguments: SyncPhaseEncoding.allCases)
    func broadcastOnlyCycleAfterFailedPlanRunsFullCycle(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        try await f.set("score", 9)
        await f.failNextPlan()
        await f.sync()
        #expect(await f.adapter.isKeyScopeResetPending())

        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")

        let client = try await f.expectConverged("after the broadcast-only cycle")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(9), "a per-player change must arrive too")
        #expect(await f.adapter.isKeyScopeResetPending() == false)
        #expect(await f.adapter.carriedDirtyFieldsForTesting().isEmpty)
    }

    @Test("an update that fails to encode is re-encoded typed firstSync in the same cycle", arguments: SyncPhaseEncoding.allCases)
    func encodeFailureIsReEncodedInTheSameCycle(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, useSnapshotForSync: false)
        await f.sync()

        try await f.set("score", 7)
        try await f.set("a", 2)
        f.diffEncodingFails.set(true)
        await f.sync()
        f.diffEncodingFails.set(false)
        // Only `.diff` fails here, so every patch encodes in the firstSync-typed re-encode.
        #expect(await f.adapter.syncFailedPlans == 0, "an encode failure does not fail the plan")
        #expect(await f.adapter.syncDroppedUpdates == 0, "nothing dropped")
        let client = try await f.expectConverged("after the re-encode")
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(7))
        #expect(client.value(at: "/a") == .int(2))

        // Later diffs use the reset key table: they decode.
        try await f.set("bag:k1", 1)
        try await f.set("item:k2", 2)
        await f.sync()
        _ = try await f.expectConverged("later")
    }

    @Test("a failed firstSync plan: the next cycle gives the joiner its full view", arguments: SyncPhaseEncoding.allCases)
    func throwingFirstSyncPlanIsRetried(encoding: SyncPhaseEncoding) async throws {
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
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
        #expect(await f.adapter.syncDroppedUpdates == 1, "only the infinity patch is dropped")
        _ = try await f.expectConverged("the other player")
        let second = await f.clientState(second: true)
        #expect(second.decodeErrors.isEmpty, "decode errors \(second.decodeErrors)")
        #expect(second.value(at: "/a") == .int(1))
        #expect(second.value(at: "/scores/\(f.player2.rawValue)") == .int(6))
        #expect(second.value(at: "/bags/\(f.player2.rawValue)/k1") == nil, "a deletion in the same update")
        #expect(second.value(at: "/speeds/\(f.player2.rawValue)") == nil, "the unencodable value is dropped")

        // The cache holds the value (as before plan + commit): later changes flow, nothing more
        // is dropped, and the field reaches clients again on its next change.
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
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
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

    @Test("a broadcast value that does not encode (NaN, json) is dropped and the cycle commits; other fields flow")
    func unencodableBroadcastPatchIsDropped() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .json)
        try await f.joinSecond()
        await f.sync()

        try await f.set("nanratio:k", 0)
        try await f.set("a", 1)
        try await f.set("score", 3)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0, "an encode failure does not fail the plan")
        #expect(await f.adapter.syncDroppedUpdates > 0, "the drop is counted")
        for second in [false, true] {
            let client = await f.clientState(second: second)
            #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
            #expect(client.value(at: "/a") == .int(1))
            #expect(client.value(at: "/ratios/k") == nil, "the unencodable value is dropped")
        }
        #expect(await f.clientState().value(at: "/scores/\(f.player.rawValue)") == .int(3))

        // NaN differs from itself, so it is in every diff and dropped every cycle; every cycle
        // commits and other changes flow.
        try await f.set("b", 2)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0)
        for second in [false, true] {
            #expect(await f.clientState(second: second).value(at: "/b") == .int(2))
        }

        // Once the value encodes again, nothing is dropped and the field reaches the clients.
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

    @Test("a broadcast-only cycle drops a value that does not encode (NaN, json) and commits")
    func unencodableBroadcastOnlyPatchIsDropped() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .json)
        try await f.joinSecond()
        await f.sync()

        try await f.set("nanratio:k", 0)
        try await f.set("a", 1)
        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.adapter.syncFailedPlans == 0)
        #expect(await f.adapter.syncDroppedUpdates > 0)
        for second in [false, true] {
            let client = await f.clientState(second: second)
            #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
            #expect(client.value(at: "/a") == .int(1))
            #expect(client.value(at: "/ratios/k") == nil)
        }
        try await f.set("b", 2)
        await f.sync()
        for second in [false, true] {
            let client = await f.clientState(second: second)
            #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
            #expect(client.value(at: "/b") == .int(2))
        }
    }

    @Test(
        "a 1-player room whose per-player frames never encode commits every cycle",
        arguments: SyncPhaseEncoding.allCases
    )
    func onePlayerRoomFailureCommits(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        await f.sync()

        f.failingPlayer.set(f.player)
        try await f.set("a", 1)
        try await f.set("score", 5)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0, "an encode failure does not fail the plan")
        let dropped = await f.adapter.syncDroppedUpdates
        #expect(dropped > 0)

        // Every cycle commits while the failure lasts (the caches advance as before this change).
        try await f.set("b", 2)
        try await f.set("score", 6)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0)
        #expect(await f.adapter.syncDroppedUpdates > dropped)
        let degraded = await f.clientState()
        #expect(degraded.decodeErrors.isEmpty, "decode errors \(degraded.decodeErrors)")
        if encoding == .messagepack {
            #expect(degraded.value(at: "/b") == .int(2), "opcode 107: the broadcast frame still flows")
        }

        // Once it encodes again, the next changes reach the client. With opcode 107 only
        // per-player frames were dropped and the client converges; with json / opcodeJsonArray
        // the dropped frames carried the broadcast too, and as before this change those values
        // stay stale until they change again.
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

    @Test("a cycle whose per-player frame does not encode still drains the event queue (opcode 107, 1-player room)")
    func encodeFailureDrainsEvents() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true)
        await f.sync()

        let player = f.player
        await f.adapter.setSyncEncodeFaultForTesting { $0 == player }
        try await f.set("a", 1)
        await f.queueEvent("bc-dropped", to: .all)
        await f.queueEvent("tg-dropped", to: .player(f.player))
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0)
        let drained = await f.adapter.pendingEventCounts()
        #expect(drained.targeted == 0 && drained.broadcast == 0, "the plan consumes the queue")
        let frames = await f.transport.messages(for: f.session)
        #expect(count("bc-dropped", in: frames) == 1)
        #expect(count("tg-dropped", in: frames) == 1)
        #expect(await f.clientState().value(at: "/a") == .int(1), "the broadcast frame still flows")
    }

    @Test(
        "a re-encode after an encode failure goes to every session of the player (one key table)",
        arguments: [SyncPhaseEncoding.opcodeJsonArray, .json]
    )
    func reEncodeReachesEverySessionOfThePlayer(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding)
        let other = SessionID("sp-session-1b")
        let otherClient = ClientID("sp-client-1b")
        // Registered directly (no admission), so both sessions stay members of the player. The
        // keeper's entry is the newer session, so the actions are sent from it.
        try await f.joinAnotherSessionOfFirstPlayer(other, clientID: otherClient)
        let sender = (client: otherClient, session: other)
        try await f.set("bag:k1", 1, from: sender)
        await f.sync()

        // The infinity fails the player's update: its sessions' updates are merged and
        // re-encoded once (typed firstSync: one key table reset), and both get that frame.
        let before = [
            f.session: await f.transport.messages(for: f.session).count,
            other: await f.transport.messages(for: other).count
        ]
        try await f.set("infspeed", from: sender)
        try await f.set("bag:k2", 2, from: sender)
        try await f.set("item:x1", 1, from: sender)
        await f.sync()
        #expect(await f.adapter.syncDroppedUpdates == 1, "only the infinity patch")
        let firstFrames = Array(await f.transport.messages(for: f.session).dropFirst(before[f.session]!))
        let otherFrames = Array(await f.transport.messages(for: other).dropFirst(before[other]!))
        #expect(firstFrames.count == 1 && otherFrames.count == 1, "one state frame each")
        #expect(firstFrames == otherFrames, "the same re-encoded frame for every session of the player")
        var decoded = SyncPhaseClient(encoding: encoding)
        decoded.receive(firstFrames)
        #expect(decoded.updateTypes == [1], "typed firstSync: \(decoded.updateTypes)")
        #expect(decoded.value(at: "/bags/\(f.player.rawValue)/k2") == .int(2))
        #expect(decoded.value(at: "/items/x1") == .int(1))
        #expect(decoded.value(at: "/speeds/\(f.player.rawValue)") == nil)
    }

    @Test(
        "a field whose extraction always throws is dropped; every cycle commits and healthy changes flow",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func throwingFieldIsDroppedAndHealthyChangesFlow(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, useSnapshotForSync: useSnapshotForSync)
        await f.sync()
        #expect(await f.clientState().value(at: "/fragile") == .int(0), "precondition: the client has the field")

        // From here on the fragile field's extraction throws: dirty (dirty-only extraction) in
        // this cycle, extracted with `.all` whenever no broadcast field is dirty.
        try await f.set("fragile", 1)
        try await f.set("a", 5)
        try await f.set("score", 6)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
        #expect(await f.adapter.syncDroppedUpdates > 0, "the dropped field is counted")
        var client = try await f.expectConverged("after the dropping cycle")
        #expect(client.value(at: "/a") == .int(5))
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(6))

        // Healthy changes keep flowing, broadcast and per-player, cycle after cycle.
        for cycle in 1...3 {
            if cycle == 2 {
                try await f.set("score", 10 + cycle)   // only per-player dirty: broadcast `.all`
            } else {
                try await f.set("b", cycle)
                try await f.set("score", 10 + cycle)
            }
            await f.sync()
            client = try await f.expectConverged("cycle \(cycle)")
            #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(10 + cycle))
        }
        #expect(client.value(at: "/b") == .int(3))
        #expect(client.value(at: "/fragile") == .int(0), "the dropped field keeps its last sent value")
        #expect(await f.adapter.syncFailedPlans == 0)
        #expect(await f.adapter.isKeyScopeResetPending() == false)
    }

    @Test(
        "the typed tables on and off: a throwing broadcast field gives the same frames, drop counts and last-sent",
        arguments: [true, false], [true, false]
    )
    func throwingFieldMatchesAcrossTheTablesSwitch(useSnapshotForSync: Bool, pathIndex: Bool) async throws {
        /// A broadcast field that throws while dirty and while clean, a late join right after a
        /// drop, a per-player-only cycle, and the field converting again.
        func run(syncTables: Bool) async throws -> SyncPhaseFixture {
            // The production MessagePack configuration: its frames are in canonical order, so two
            // runs can be compared byte for byte (the fixture's other encoders keep the diff's order).
            let f = try await SyncPhaseFixture.make(
                encoding: .messagepack, useSnapshotForSync: useSnapshotForSync, realMessagePack: true,
                pathIndex: pathIndex, syncTables: syncTables
            )
            await f.sync()
            try await f.set("fragileval", 7)
            try await f.set("a", 1)
            await f.sync()
            try await f.set("fragile", 1)
            try await f.set("fragileval", 8)
            try await f.set("a", 5)
            try await f.set("score", 6)
            await f.sync()
            try await f.joinSecond()
            await f.sync()
            try await f.set("score", 9)
            await f.sync()
            try await f.set("b", 2)
            try await f.set("item:x", 1)
            await f.sync()
            try await f.set("fragile", 0)
            try await f.set("b", 3)
            await f.sync()
            await f.sync()
            return f
        }
        let on = try await run(syncTables: true)
        let off = try await run(syncTables: false)
        for session in [on.session, on.session2] {
            let mine = await on.transport.messages(for: session)
            let theirs = await off.transport.messages(for: session)
            #expect(mine.count > 2, "\(session): frames were sent")
            #expect(mine == theirs, "\(session): the same frames, in order")

        }
        #expect(await on.adapter.syncDroppedUpdates > 0, "the dropped field is counted")
        #expect(await on.adapter.syncDroppedUpdates == off.adapter.syncDroppedUpdates)
        #expect(await on.adapter.syncFailedPlans == off.adapter.syncFailedPlans)
        #expect(await on.adapter.isKeyScopeResetPending() == off.adapter.isKeyScopeResetPending())
        #expect(await on.adapter.lastSentBroadcastSnapshotForTesting() == off.adapter.lastSentBroadcastSnapshotForTesting())
        #expect(await on.adapter.syncEngineForTesting().cachedBroadcastSnapshotForTesting == nil, "the tables hold last-sent")
        _ = try await on.expectConverged("tables on")
        _ = try await off.expectConverged("tables off")
    }

    @Test(
        "the typed tables on and off: a failed plan, a key scope reset and an encode drop give the same frames and last-sent",
        arguments: [true, false], [true, false]
    )
    func failedPlanAndKeyResetMatchAcrossTheTablesSwitch(useSnapshotForSync: Bool, pathIndex: Bool) async throws {
        /// A failed plan whose dirty fields carry over (the next cycle resets the key scopes), a
        /// join after it, a cycle whose updates don't encode, and the cycles that recover.
        func run(syncTables: Bool) async throws -> SyncPhaseFixture {
            let f = try await SyncPhaseFixture.make(
                encoding: .messagepack, useSnapshotForSync: useSnapshotForSync, realMessagePack: true,
                pathIndex: pathIndex, syncTables: syncTables
            )
            await f.sync()
            try await f.set("a", 1)
            try await f.set("item:x", 1)
            await f.sync()
            await f.failNextPlan()
            try await f.set("a", 2)
            try await f.set("item:y", 2)
            try await f.set("score", 3)
            await f.sync()
            await f.sync()
            try await f.joinSecond()
            await f.sync()
            await f.adapter.setSyncEncodeFaultForTesting { _ in true }
            try await f.set("b", 5)
            try await f.set("item:z", 3)
            await f.sync()
            await f.adapter.setSyncEncodeFaultForTesting(nil)
            try await f.set("b", 6)
            try await f.set("item:x", 4)
            await f.sync()
            await f.sync()
            return f
        }
        let on = try await run(syncTables: true)
        let off = try await run(syncTables: false)
        for session in [on.session, on.session2] {
            let mine = await on.transport.messages(for: session)
            let theirs = await off.transport.messages(for: session)
            #expect(mine.count > 2, "\(session): frames were sent")
            #expect(mine == theirs, "\(session): the same frames, in order")
        }
        #expect(await on.adapter.syncFailedPlans > 0, "the plan failed")
        #expect(await on.adapter.syncFailedPlans == off.adapter.syncFailedPlans)
        #expect(await on.adapter.syncDroppedUpdates == off.adapter.syncDroppedUpdates)
        #expect(await on.adapter.isKeyScopeResetPending() == off.adapter.isKeyScopeResetPending())
        #expect(await on.adapter.lastSentBroadcastSnapshotForTesting() == off.adapter.lastSentBroadcastSnapshotForTesting())
        _ = try await on.expectConverged("tables on")
        _ = try await off.expectConverged("tables off")
    }

    @Test(
        "full snapshot: a dropped field sends nothing, so a joiner with a newer value keeps it",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func fullSnapshotDroppedFieldDoesNotRollBackAJoiner(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(
            encoding: encoding,
            useSnapshotForSync: useSnapshotForSync,
            fullSnapshot: true
        )
        await f.sync()
        // The broadcast cache holds fragile = 0. The state moves to 7, and a player joins before
        // the next cycle: its firstSync carries 7, while the cache still holds 0.
        try await f.set("fragileval", 7)
        try await f.joinSecond()
        #expect(await f.clientState(second: true).value(at: "/fragile") == .int(7), "precondition")

        // Now the field's extraction throws; the next cycle (diff from empty) drops it.
        try await f.set("fragile", 1)
        try await f.set("a", 3)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
        #expect(await f.adapter.syncDroppedUpdates > 0, "the drop is counted")
        let joiner = await f.clientState(second: true)
        #expect(joiner.decodeErrors.isEmpty, "decode errors \(joiner.decodeErrors)")
        #expect(joiner.value(at: "/fragile") == .int(7), "no .set of the cached older value")
        #expect(joiner.value(at: "/a") == .int(3), "healthy changes still flow")
        let first = await f.clientState()
        #expect(first.decodeErrors.isEmpty, "decode errors \(first.decodeErrors)")
        #expect(first.value(at: "/a") == .int(3))
    }

    @Test(
        "full snapshot: a per-player field dropped for one player is filtered for that player only",
        arguments: SyncPhaseEncoding.allCases, [true, false]
    )
    func fullSnapshotPerPlayerDropIsPerPlayer(encoding: SyncPhaseEncoding, useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(
            encoding: encoding,
            useSnapshotForSync: useSnapshotForSync,
            fullSnapshot: true
        )
        try await f.joinSecond()
        let a = f.player.rawValue
        let b = f.player2.rawValue
        try await f.set("pfragile", 1)
        try await f.set("pfragile", 2, second: true)
        await f.sync()
        #expect(await f.clientState().value(at: "/pfragiles/\(a)") == .int(1), "precondition")
        #expect(await f.clientState(second: true).value(at: "/pfragiles/\(b)") == .int(2), "precondition")

        // Same cycle: A's entry throws (dropped for A), B's entry is removed.
        try await f.set("pbreak", 1)
        try await f.set("unpfragile", second: true)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
        #expect(await f.adapter.syncDroppedUpdates > 0, "A's drop is counted")
        #expect(await f.clientState().value(at: "/pfragiles/\(a)") == .int(1), "A keeps its last sent value")
        _ = try await f.expectConverged("B received its removal", second: true)

        // While A's copy keeps throwing, B's healthy changes to the same field are not held back.
        try await f.set("pfragile", 5, second: true)
        await f.sync()
        let second = try await f.expectConverged("B's change", second: true)
        #expect(second.value(at: "/pfragiles/\(b)") == .int(5))

        // A recovers.
        try await f.set("pbreak", 0)
        try await f.set("pfragile", 3)
        await f.sync()
        let first = try await f.expectConverged("A after it recovers")
        #expect(first.value(at: "/pfragiles/\(a)") == .int(3))
        _ = try await f.expectConverged("B after A recovers", second: true)
    }

    @Test("a joiner whose extraction throws for one field gets the rest of its view")
    func joinerWithThrowingFieldGetsTheRest() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true, join: false)
        try await f.set("fragile", 1)
        try await f.join()
        #expect(await f.adapter.syncFailedPlans == 0)
        #expect(await f.adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(f.player))
        try await f.set("a", 3)
        await f.sync()
        let client = await f.clientState()
        #expect(client.decodeErrors.isEmpty, "decode errors \(client.decodeErrors)")
        #expect(client.value(at: "/a") == .int(3))
        #expect(client.value(at: "/scores/\(f.player.rawValue)") == .int(0))
        #expect(client.value(at: "/fragile") == nil, "never extracted, never sent")
    }

    @Test("a joiner whose firstSync and retry do not encode even empty stays unmarked until its view goes out")
    func unencodableJoinerIsSkippedAndRetried() async throws {
        let f = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true, join: false)
        let player = f.player
        await f.adapter.setSyncEncodeFaultForTesting { $0 == player }
        try await f.join()
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
        #expect(await f.adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player) == false, "not marked")
        #expect(await f.adapter.syncDroppedUpdates > 0, "the drop is counted")

        // The next full cycle's from-empty retry fails too (even its empty fallback): its staged
        // mark and caches are dropped.
        try await f.set("a", 1)
        await f.sync()
        #expect(await f.adapter.syncFailedPlans == 0, "the plan commits")
        let engine = await f.adapter.syncEngineForTesting()
        #expect(engine.hasReceivedFirstSyncForTesting(player) == false, "still not marked after the failed retry")
        #expect(engine.cachedPerPlayerSnapshotForTesting(player) == nil, "no per-player cache staged for it")
        #expect(await f.adapter.isKeyScopeResetPending(), "the unsent frame's key slots are reset next")

        // Once it encodes, the next cycle gives it its whole view.
        await f.adapter.setSyncEncodeFaultForTesting(nil)
        try await f.set("a", 2)
        await f.sync()
        #expect(await f.adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player))
        let client = try await f.expectConverged("after the retry")
        #expect(client.value(at: "/a") == .int(2))
        #expect(client.value(at: "/scores/\(player.rawValue)") == .int(0), "its per-player view too")
    }

    @Test("without periodic sync, a failed firstSync plan is retried by a delayed follow-up", arguments: SyncPhaseEncoding.allCases)
    func failedFirstSyncSchedulesFollowUpWithoutPeriodicSync(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, periodicSync: false, join: false)
        await f.failNextPlan()
        try await f.join()
        #expect(await f.adapter.syncFailedPlans == 1, "precondition: the firstSync plan failed")

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

    @Test("without periodic sync, a failed plan schedules a delayed follow-up that delivers its changes", arguments: SyncPhaseEncoding.allCases)
    func failedPlanSchedulesFollowUpWithoutPeriodicSync(encoding: SyncPhaseEncoding) async throws {
        let f = try await SyncPhaseFixture.make(encoding: encoding, periodicSync: false)
        await f.sync()

        try await f.set("a", 1)
        await f.failNextPlan()
        await f.adapter.syncNow()
        #expect(await f.adapter.isKeyScopeResetPending(), "precondition: the plan failed")

        // No further sync request: the delayed follow-up commits the carried changes.
        var committed = false
        for _ in 0..<100 {
            if await f.adapter.isKeyScopeResetPending() == false {
                committed = true
                break
            }
            try await safeTaskSleep(for: .milliseconds(20))
        }
        #expect(committed, "the follow-up committed without another sync request")
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
        _ = try await f.expectConverged("after the next cycle")
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

    @Test("path index on (the schema's path table): a member and a second joiner decode every frame, in either sync mode")
    func pathIndexMemberAndJoinerDecodeInEitherMode() async throws {
        // This suite runs with IN_TURN_SYNC on and off; the flipped-joiner case is in the
        // join-flip suite, which runs only with it on.
        let fixture = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true, pathIndex: true)
        try await fixture.set("item:x", 1)
        try await fixture.set("fragileval", 4)
        try await fixture.set("pfragile", 5)
        try await fixture.set("bag:k1", 6)
        try await fixture.set("ratio:r", 7)
        await fixture.sync()

        try await fixture.joinSecond()
        try await fixture.set("item:x", 2)
        try await fixture.set("bag:k2", 10, second: true)
        try await fixture.set("speed", 3, second: true)
        await fixture.sync()

        let member = await fixture.clientState()
        let joiner = await fixture.clientState(second: true)
        #expect(member.decodeErrors.isEmpty, "member: \(member.decodeErrors), types \(member.updateTypes)")
        #expect(joiner.decodeErrors.isEmpty, "joiner: \(joiner.decodeErrors), types \(joiner.updateTypes)")
        #expect(member.view == (try await fixture.serverView()))
        #expect(joiner.view == (try await fixture.serverView(second: true)))
        #expect(member.value(at: "/items/x") == .int(2))
        #expect(joiner.value(at: "/bags/\(fixture.player2.rawValue)/k2") == .int(10))
        #expect(await fixture.adapter.unmappedPathPatches == 0)
        // The hand-written hash table has exactly the schema's patterns; this keeps it so.
        #expect(Set(fixture.pathIndex?.pathHashes.keys ?? [:].keys) == Set(syncPhasePathPatterns))
        // The ids on the wire are path indices: the hash-table client can't read them.
        var asHashes = SyncPhaseClient(encoding: .messagepack)
        asHashes.receive(await fixture.transport.messages(for: fixture.session))
        #expect(!asHashes.decodeErrors.isEmpty, "a hash-form client decodes index frames: \(asHashes.view)")
    }
}

// MARK: - Late joiners and the broadcast key table (#90)

@Suite("TransportAdapter sync phase: late joiners decode merged broadcast frames (#90)", .timeLimit(.minutes(1)))
struct TransportAdapterSyncPhaseLateJoinerTests {
    @Test(
        "A player joining after a broadcast dynamic key was defined decodes every later frame, and so does the member",
        arguments: SyncPhaseEncoding.allCases
    )
    func lateJoinerDecodesBroadcastKeysDefinedBeforeItJoined(encoding: SyncPhaseEncoding) async throws {
        let fixture = try await SyncPhaseFixture.make(encoding: encoding, realMessagePack: true)
        // A broadcast dynamic key the member learns (opcode 107 defines it) before the join.
        try await fixture.set("item:x", 1)
        await fixture.sync()

        try await fixture.joinSecond()
        await fixture.sync()
        // The pre-join key changes, and a new key appears.
        try await fixture.set("item:x", 2)
        try await fixture.set("item:y", 3, second: true)
        await fixture.sync()

        let member = await fixture.clientState()
        let joiner = await fixture.clientState(second: true)
        #expect(member.decodeErrors.isEmpty, "member: \(member.decodeErrors), types \(member.updateTypes)")
        #expect(joiner.decodeErrors.isEmpty, "joiner: \(joiner.decodeErrors), types \(joiner.updateTypes)")
        #expect(member.view == (try await fixture.serverView()))
        #expect(joiner.view == (try await fixture.serverView(second: true)))
    }

    @Test("No reset while the broadcast key table is empty; a join after a broadcast key exists requests one")
    func resetOnlyOnceBroadcastKeysExist() async throws {
        let fixture = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true)
        // The first player's firstSync, nothing broadcast yet.
        #expect(await fixture.adapter.isKeyScopeResetPending() == false)
        try await fixture.set("item:x", 1)
        await fixture.sync()
        #expect(await fixture.adapter.isKeyScopeResetPending() == false)

        try await fixture.joinSecond()
        #expect(await fixture.adapter.isKeyScopeResetPending())
        await fixture.sync()
        #expect(await fixture.adapter.isKeyScopeResetPending() == false)
    }

    @Test("An encoder without key compression keeps no tables, so joins request no reset")
    func noKeyTableWithoutCompression() {
        let hasher = PathHasher(pathHashes: syncPhasePathHashes)
        #expect(OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher).keepsDynamicKeyTables)
        #expect(OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, dynamicKeyCompression: false).keepsDynamicKeyTables == false)
        #expect(OpcodeMessagePackStateUpdateEncoder(pathHasher: nil).keepsDynamicKeyTables == false)
    }

    @Test("A skipped joiner, then a broadcast-only cycle, then a full cycle: the joiner decodes every frame")
    func skippedJoinerThenBroadcastOnly() async throws {
        let fixture = try await SyncPhaseFixture.make(encoding: .messagepack)
        try await fixture.set("item:x", 1)
        await fixture.sync()

        // The joiner's firstSync does not encode even empty: it is skipped, still unsynced.
        fixture.failingPlayer.set(fixture.player2)
        try await fixture.joinSecond()
        #expect(await fixture.adapter.waitForOutboundDrain())
        fixture.failingPlayer.set(nil)
        #expect(await fixture.adapter.isKeyScopeResetPending())

        // A broadcast-only cycle touching the pre-join key, then a full cycle.
        try await fixture.set("item:x", 2)
        await fixture.adapter.syncBroadcastOnly()
        #expect(await fixture.adapter.waitForOutboundDrain())
        try await fixture.set("item:y", 3)
        await fixture.sync()

        let member = await fixture.clientState()
        let joiner = await fixture.clientState(second: true)
        #expect(member.decodeErrors.isEmpty, "member: \(member.decodeErrors)")
        #expect(joiner.decodeErrors.isEmpty, "joiner: \(joiner.decodeErrors), types \(joiner.updateTypes)")
        #expect(joiner.view == (try await fixture.serverView(second: true)))
    }
}

/// A JoinResponse for the in-turn join path; the test clients skip it (not a state update).
private let syncPhaseJoinResponse: @Sendable (PlayerID, Int32) -> Data? = { playerID, slot in
    try? JSONEncoder().encode(TransportMessage.joinResponse(
        requestID: "r-\(playerID.rawValue)",
        success: true,
        playerID: playerID.rawValue,
        playerSlot: slot,
        encoding: "json"
    ))
}

extension SyncPhaseFixture {
    /// Joins `session2` / `player2` through the in-turn path (#69): the join flips in a committed
    /// sync phase, which a stepped sync loop iteration runs once the keeper consumed its inputs.
    func joinSecondInTurnAndFlip() async throws {
        await keeper.setTransport(adapter)
        await adapter.onConnect(sessionID: session2, clientID: client2)
        let adapter = self.adapter
        let session2 = self.session2, client2 = self.client2, player2 = self.player2
        let join = Task {
            try await adapter.performJoin(
                playerSession: PlayerSession(playerID: player2.rawValue, deviceID: "dev", metadata: [:]),
                clientID: client2,
                sessionID: session2,
                authInfo: nil,
                joinResponse: syncPhaseJoinResponse
            )
        }
        var awaiting = false
        for _ in 0..<2000 {
            awaiting = await adapter.hasJoinsAwaitingSyncForTesting()
            if awaiting { break }
            try? await safeTaskSleep(for: .milliseconds(1))
        }
        #expect(awaiting, "the join never became ready to flip")
        await keeper.runSyncLoopIterationForTesting()
        let result = try #require(try await join.value)
        #expect(result.completedInTurn)
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }
}

@Suite(
    "A late joiner flipped in a turn decodes every frame (#69, #90)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: the in-turn join path is off")
)
struct TransportAdapterSyncPhaseJoinFlipTests {
    @Test(
        "A joiner flipped after a broadcast dynamic key was defined decodes every later frame, and so does the member",
        arguments: SyncPhaseEncoding.allCases
    )
    func flippedJoinerDecodesBroadcastKeysDefinedBeforeItJoined(encoding: SyncPhaseEncoding) async throws {
        let fixture = try await SyncPhaseFixture.make(encoding: encoding, realMessagePack: true)
        try await fixture.set("item:x", 1)
        await fixture.sync()

        try await fixture.joinSecondInTurnAndFlip()
        try await fixture.set("item:x", 2)
        try await fixture.set("item:y", 3, second: true)
        await fixture.sync()

        let member = await fixture.clientState()
        let joiner = await fixture.clientState(second: true)
        #expect(member.decodeErrors.isEmpty, "member: \(member.decodeErrors), types \(member.updateTypes)")
        #expect(joiner.decodeErrors.isEmpty, "joiner: \(joiner.decodeErrors), types \(joiner.updateTypes)")
        #expect(member.view == (try await fixture.serverView()))
        #expect(joiner.view == (try await fixture.serverView(second: true)))
    }

    @Test("path index on (the schema's path table): member and flipped joiner decode every frame")
    func pathIndexMemberAndJoinerDecode() async throws {
        let fixture = try await SyncPhaseFixture.make(encoding: .messagepack, realMessagePack: true, pathIndex: true)
        // Every kind of path: top-level values, map keys, nested map keys, per-player slices.
        try await fixture.set("item:x", 1)
        try await fixture.set("fragileval", 4)
        try await fixture.set("pfragile", 5)
        try await fixture.set("bag:k1", 6)
        try await fixture.set("ratio:r", 7)
        await fixture.sync()

        try await fixture.joinSecondInTurnAndFlip()
        try await fixture.set("item:x", 2)
        try await fixture.set("fragileval", 8)
        try await fixture.set("pfragile", 9, second: true)
        try await fixture.set("bag:k2", 10, second: true)
        await fixture.sync()

        let member = await fixture.clientState()
        let joiner = await fixture.clientState(second: true)
        #expect(member.decodeErrors.isEmpty, "member: \(member.decodeErrors), types \(member.updateTypes)")
        #expect(joiner.decodeErrors.isEmpty, "joiner: \(joiner.decodeErrors), types \(joiner.updateTypes)")
        #expect(member.view == (try await fixture.serverView()))
        #expect(joiner.view == (try await fixture.serverView(second: true)))
        #expect(member.value(at: "/fragile") == .int(8))
        #expect(joiner.value(at: "/pfragiles/\(fixture.player2.rawValue)") == .int(9))
        // The hand-written hash table has exactly the schema's patterns; this keeps it so.
        #expect(Set(fixture.pathIndex?.pathHashes.keys ?? [:].keys) == Set(syncPhasePathPatterns))
        #expect(await fixture.adapter.unmappedPathPatches == 0)
        // The ids on the wire are path indices: the hash-table client can't read them.
        var asHashes = SyncPhaseClient(encoding: .messagepack)
        asHashes.receive(await fixture.transport.messages(for: fixture.session))
        #expect(!asHashes.decodeErrors.isEmpty, "a hash-form client decodes index frames: \(asHashes.view)")
    }
}

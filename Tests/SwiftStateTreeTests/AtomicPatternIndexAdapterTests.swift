// Tests/SwiftStateTreeTests/AtomicPatternIndexAdapterTests.swift
//
// The atomic pattern index (`AtomicPatternIndex`) on the legacy sync path (in-turn sync off):
// there, no row entries are made and a patch carries a split only from the sync tables. Every
// frame a client receives decodes to the live state, and no atomic value in it is keyed.
// Plan: Notes/plans/2026-11-12-atomic-node-once-per-pattern.md.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

@StateNodeBuilder
struct PatternIndexAdapterUnit: StateNodeProtocol {
    @Sync(.broadcast) var position: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var marks: [String: Position2] = [:]

    public init() {}
}

@StateNodeBuilder
struct PatternIndexAdapterState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var target: Position2? = nil
    @Sync(.broadcast) var units: [String: PatternIndexAdapterUnit] = [:]

    public init() {}
}

/// The next change, applied by the next tick.
private final class PatternIndexAdapterScript: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [@Sendable (inout PatternIndexAdapterState) -> Void] = []

    func queue(_ step: @escaping @Sendable (inout PatternIndexAdapterState) -> Void) {
        lock.lock(); steps.append(step); lock.unlock()
    }

    func apply(_ state: inout PatternIndexAdapterState) {
        lock.lock()
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        step?(&state)
    }
}

/// Records every frame with its target, in send order.
private actor PatternIndexAdapterFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    /// The frames `sessionID` receives: its own and the broadcasts.
    func frames(for sessionID: SessionID) -> [Data] {
        frames.compactMap { frame in
            switch frame.target {
            case .session(let s) where s == sessionID: return frame.data
            case .broadcast: return frame.data
            default: return nil
            }
        }
    }
}

private func patternIndexAdapterLand(_ script: PatternIndexAdapterScript) -> LandDefinition<PatternIndexAdapterState> {
    Land("pattern-index-adapter", using: PatternIndexAdapterState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout PatternIndexAdapterState, _: LandContext) in
                script.apply(&state)
            }
        }
    }
}

private func patternIndexAdapterEnv(tables: Bool) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: false,
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
    config.useSyncTables = tables
    return config
}

/// `value` with every number as a double: a decoder reads a whole double (`0.0`) as an integer.
private func numbersAsDoubles(_ value: SnapshotValue) -> SnapshotValue {
    switch value {
    case .int(let v): return .double(Double(v))
    case .object(let fields): return .object(fields.mapValues(numbersAsDoubles))
    case .array(let items): return .array(items.map(numbersAsDoubles))
    default: return value
    }
}

/// The paths in `value` (at `path`) that hold an atomic value in its keyed form (`{v: {x, y}}`).
private func keyedAtomicPaths(_ value: SnapshotValue, at path: String) -> [String] {
    switch value {
    case .object(let fields):
        let own = fields["v"].map { _ in [path] } ?? []
        return own + fields.flatMap { keyedAtomicPaths($0.value, at: path + "/" + $0.key) }
    case .array(let items):
        return items.enumerated().flatMap { keyedAtomicPaths($0.element, at: path + "/\($0.offset)") }
    default:
        return []
    }
}

struct PatternIndexAdapterCase: CustomTestStringConvertible, Sendable {
    let messagePack: Bool
    let tables: Bool

    var testDescription: String { "\(messagePack ? "MessagePack" : "opcode JSON"), sync tables \(tables ? "on" : "off")" }

    static let all = [true, false].flatMap { messagePack in [true, false].map { PatternIndexAdapterCase(messagePack: messagePack, tables: $0) } }
}

@Suite("Atomic pattern index: the legacy sync path")
struct AtomicPatternIndexAdapterTests {
    @Test("In-turn sync off: every frame decodes to the live state, and no atomic value in it is keyed", arguments: PatternIndexAdapterCase.all)
    func legacyPathRoundTrips(_ testCase: PatternIndexAdapterCase) async throws {
        let script = PatternIndexAdapterScript()
        let frames = PatternIndexAdapterFrames()
        let definition = patternIndexAdapterLand(script)
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition)])
        let pathHashes = try #require(schema.lands["pattern-index-adapter"]?.pathHashes)
        let keeper = LandKeeper(definition: definition, initialState: PatternIndexAdapterState(), autoStartLoops: false)
        let adapter = TransportAdapter<PatternIndexAdapterState>(
            keeper: keeper,
            transport: frames,
            landID: "pattern-index-adapter",
            transportEnvConfig: patternIndexAdapterEnv(tables: testCase.tables),
            encodingConfig: testCase.messagePack ? .messagepack : .opcode,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true,
            inTurnSync: false
        )
        #expect(!adapter.inTurnSyncEnabled)
        #expect(await adapter.usesSyncTablesForTesting() == testCase.tables)
        await frames.setDelegate(adapter)
        await keeper.setTransport(adapter)

        // The legacy join: the keeper's join, the session, then its first view.
        let session = SessionID("s-p1")
        let client = ClientID("c-p1")
        await adapter.onConnect(sessionID: session, clientID: client)
        let decision = try await keeper.join(
            session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, services: LandServices()
        )
        guard case .allow(let player) = decision else {
            Issue.record("the join was denied")
            return
        }
        await adapter.registerSession(sessionID: session, clientID: client, playerID: player, authInfo: nil)
        _ = await adapter.allocatePlayerSlot(accountKey: player.rawValue, for: player)
        await adapter.syncStateForNewPlayer(playerID: player, sessionID: session)
        #expect(await adapter.waitForOutboundDrain())

        let hasher = PathHasher(pathHashes: pathHashes)
        let format: StateFrameFormat = testCase.messagePack ? .messagePack : .json
        // The client reads atomic values keyed; the second decoder, without the layout, shows
        // them as they were sent.
        let decoder = OpcodeJSONStateUpdateDecoder(
            pathHasher: hasher, atomicLayout: AtomicLayoutTable.forState(PatternIndexAdapterState.self), pathIndex: true
        )
        let wireDecoder = OpcodeJSONStateUpdateDecoder(pathHasher: PathHasher(pathHashes: pathHashes), pathIndex: true)
        var view = SnapshotClientView()
        var read = 0
        var keyed: [String] = []
        var stateFrames = 0

        func readFrames(_ step: String) async throws {
            let all = await frames.frames(for: session)
            for data in all.dropFirst(read) {
                if (try? JSONDecoder().decode(TransportMessage.self, from: data)) != nil { continue }
                guard let decoded = try decoder.decodeFrame(data, format: format),
                      let wire = try wireDecoder.decodeFrame(data, format: format) else { continue }
                switch decoded.update {
                case .noChange: break
                case .diff(let patches), .firstSync(let patches):
                    try view.apply(patches)
                    stateFrames += 1
                }
                switch wire.update {
                case .noChange: break
                case .diff(let patches), .firstSync(let patches):
                    for patch in patches {
                        switch patch.operation {
                        case .set(let value), .add(let value):
                            keyed += keyedAtomicPaths(value, at: patch.path).map { "\(step): \($0)" }
                        case .delete:
                            break
                        }
                    }
                }
            }
            read = all.count
            let live = try await keeper.currentState().broadcastSnapshot(dirtyFields: nil).values.mapValues(numbersAsDoubles)
            #expect(view.fields.mapValues(numbersAsDoubles) == live, "\(testCase.testDescription), \(step): the client holds the live state")
        }

        try await readFrames("join")
        let steps: [(String, @Sendable (inout PatternIndexAdapterState) -> Void)] = [
            ("rows created, keys equal to property names", { state in
                state.round = 1
                state.target = Position2(x: 1, y: 2)
                for (offset, key) in ["a", "position", "hp", ""].enumerated() {
                    var unit = PatternIndexAdapterUnit()
                    unit.position = Position2(x: Float(offset), y: Float(-offset))
                    unit.hp = offset
                    state.units[key] = unit
                }
            }),
            ("an atomic field and a scalar of one row", { state in
                state.units["a"]?.hp = 9
                state.units["a"]?.position = Position2(x: 5, y: 6)
                state.units["position"]?.position = Position2(x: 7, y: 8)
            }),
            ("null at an atomic path, a map of atomic values", { state in
                state.target = nil
                state.units["hp"]?.marks["position"] = Position2(x: 3, y: 3)
                state.units[""]?.marks["x"] = Position2(x: 4, y: 4)
            }),
            ("a delete and a create", { state in
                state.units["a"] = nil
                var unit = PatternIndexAdapterUnit()
                unit.position = Position2(x: 9, y: 9)
                state.units["new"] = unit
            }),
        ]
        for (name, step) in steps {
            script.queue(step)
            await keeper.stepTickOnce()
            await adapter.syncNow()
            #expect(await adapter.waitForOutboundDrain())
            try await readFrames(name)
        }
        #expect(stateFrames > steps.count, "\(testCase.testDescription): the join's view and every step reached the client")
        #expect(keyed.isEmpty, "\(testCase.testDescription): keyed atomic values sent at \(keyed)")
    }
}

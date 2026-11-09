// Tests/SwiftStateTreeTransportTests/DirtyTrackingByteIdentityTests.swift
//
// Dirty tracking is an optimization: with it on, a sync extracts only dirty fields; off, every
// field. Auto dirty tracking switches between the two at any sync, and records don't say which
// mode was on, so both must send the same frames. One script runs on adapters that differ only
// in the mode, and each recipient must get the same frames, in order, on every encoding.
//
// "The same" is byte-identical up to hash order. The diff and the per-session sends iterate
// dictionaries, whose order Swift seeds per instance, so two adapters in one process can send
// to sessions in a different interleaving and emit a frame's patches in a different order (with
// SWIFT_DETERMINISTIC_HASHING=1 the two runs are byte-identical frame for frame). So frames are
// compared per recipient, in that recipient's order, and a frame whose bytes differ is decoded
// and compared with its patch entries as a multiset and its dynamic-key definitions as a set;
// since #292 the slots themselves don't depend on order.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

@StateNodeBuilder
struct DirtyIdentityState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var title: String = ""
    @Sync(.broadcast) var monsters: [Int: Int] = [:]
    @Sync(.broadcast) var positions: [String: Int] = [:]
    @Sync(.perPlayerSlice()) var inventories: [PlayerID: [String]] = [:]
    @Sync(.serverOnly) var secret: Int = 0

    public init() {}
}

/// One script step. `@Payload` rejects optionals: 0 and "" mean "none".
@Payload
struct DirtyIdentityStep: ClientEventPayload {
    let addMonster: Int
    let removeMonster: Int
    let moveAll: Int
    let title: String
    let item: String
    let clearInventory: Bool
    let secretOnly: Bool
}

@Payload
struct DirtyIdentityNotice: ServerEventPayload {
    let round: Int
}

private func makeDirtyIdentityDefinition(landID: String) -> LandDefinition<DirtyIdentityState> {
    Land(landID, using: DirtyIdentityState.self) {
        ClientEvents { Register(DirtyIdentityStep.self) }
        ServerEvents { Register(DirtyIdentityNotice.self) }
        Rules {
            OnJoin { (state: inout DirtyIdentityState, ctx: LandContext) in
                state.inventories[ctx.playerID] = []
                state.positions[ctx.playerID.rawValue] = 0
            }
            OnLeave { (state: inout DirtyIdentityState, ctx: LandContext) in
                state.inventories.removeValue(forKey: ctx.playerID)
                state.positions.removeValue(forKey: ctx.playerID.rawValue)
            }
            HandleEvent(DirtyIdentityStep.self) { (state: inout DirtyIdentityState, step: DirtyIdentityStep, ctx: LandContext) in
                state.secret += 1
                if step.secretOnly { return }
                state.round += 1
                if step.addMonster != 0 { state.monsters[step.addMonster] = step.addMonster * 10 }
                if step.removeMonster != 0 { state.monsters.removeValue(forKey: step.removeMonster) }
                if step.moveAll != 0 {
                    for key in state.positions.keys.sorted() { state.positions[key, default: 0] += step.moveAll }
                }
                if !step.title.isEmpty { state.title = step.title }
                if step.clearInventory { state.inventories.removeValue(forKey: ctx.playerID) }
                if !step.item.isEmpty { state.inventories[ctx.playerID, default: []].append(step.item) }
                ctx.emitEvent(DirtyIdentityNotice(round: state.round), to: .all)
            }
        }
    }
}

/// Every frame sent, in order, with its target.
actor DirtyIdentityRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [(target: String, data: Data)] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append(("\(target)", message))
    }
}

/// A land and its adapter, driven one step at a time.
struct DirtyIdentityRun {
    let keeper: LandKeeper<DirtyIdentityState>
    let adapter: TransportAdapter<DirtyIdentityState>
    let transport: DirtyIdentityRecordingTransport

    init(envConfig: TransportEnvConfig, encoding: TransportEncodingConfig) async {
        // The same land ID in every run: it is part of the frames.
        let landID = "dirty-identity"
        transport = DirtyIdentityRecordingTransport()
        keeper = LandKeeper<DirtyIdentityState>(
            definition: makeDirtyIdentityDefinition(landID: landID),
            initialState: DirtyIdentityState(),
            // No sync loop: syncs happen only where the script asks, so runs are comparable.
            autoStartLoops: false
        )
        adapter = TransportAdapter<DirtyIdentityState>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            transportEnvConfig: envConfig,
            encodingConfig: encoding
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
    }

    func join(_ n: Int) async throws {
        let session = SessionID("s\(n)"), client = ClientID("c\(n)")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p\(n)"))
        await keeper.waitForInFlightWorkForTesting()
    }

    func leave(_ n: Int) async {
        await adapter.onDisconnect(sessionID: SessionID("s\(n)"), clientID: ClientID("c\(n)"))
        await keeper.waitForInFlightWorkForTesting()
    }

    func step(
        _ n: Int, add: Int = 0, remove: Int = 0, move: Int = 0, title: String = "",
        item: String = "", clearInventory: Bool = false, secretOnly: Bool = false
    ) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(DirtyIdentityStep(
                addMonster: add, removeMonster: remove, moveAll: move, title: title,
                item: item, clearInventory: clearInventory, secretOnly: secretOnly
            )),
            playerID: PlayerID("p\(n)"), clientID: ClientID("c\(n)"), sessionID: SessionID("s\(n)")
        )
        await keeper.waitForInFlightWorkForTesting()
    }

    func sync() async {
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    /// Low change rate: one field of one object.
    func quietStep(_ round: Int) async throws {
        try await step(1, title: "t\(round)")
    }

    /// High change rate: a new monster and every player's position.
    func busyStep(_ round: Int) async throws {
        try await step(1, add: 100 + round, move: 1)
    }

    /// The fixed script: joins, broadcast and per-player changes, a server-only change, an idle
    /// sync, removals, a vanished and restored per-player slice, a leave and a late join.
    func runScript() async throws {
        for n in 1...3 { try await join(n) }
        await sync()
        for round in 1...4 {
            try await step(1, add: round, title: "r\(round)")
            try await step(2, move: round, item: "item\(round)")
            await sync()
        }
        await sync()
        try await step(2, secretOnly: true)
        await sync()
        try await step(3, remove: 2, move: -1)
        await sync()
        try await step(1, clearInventory: true)
        await sync()
        try await step(1, item: "back")
        await sync()
        await leave(2)
        await sync()
        try await join(4)
        try await step(4, add: 42, item: "late")
        await sync()
    }
}

func dirtyIdentityConfig(
    dirtyTracking: Bool,
    autoDirtyTracking: Bool = false,
    requiredSamples: Int = 30
) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: dirtyTracking,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: autoDirtyTracking,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: requiredSamples,
        profilingConfig: nil
    )
}

let dirtyIdentityEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("jsonOpcode", .jsonOpcode),
    ("messagepack", .messagepack),
]

func expectSameFrames(
    _ a: [(target: String, data: Data)],
    _ b: [(target: String, data: Data)],
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(a.count == b.count, "\(label): frame count", sourceLocation: sourceLocation)
    let left = Dictionary(grouping: a, by: \.target).mapValues { $0.map(\.data) }
    let right = Dictionary(grouping: b, by: \.target).mapValues { $0.map(\.data) }
    #expect(Set(left.keys) == Set(right.keys), "\(label): recipients", sourceLocation: sourceLocation)
    for target in left.keys.sorted() {
        let mine = left[target] ?? [], theirs = right[target] ?? []
        guard mine.count == theirs.count else {
            Issue.record("\(label): \(target) got \(mine.count) vs \(theirs.count) frames", sourceLocation: sourceLocation)
            continue
        }
        for (index, (one, other)) in zip(mine, theirs).enumerated() where one != other {
            let oneForm = orderFreeFrameForm(one), otherForm = orderFreeFrameForm(other)
            if oneForm == nil || oneForm != otherForm {
                Issue.record("\(label): \(target) frame \(index) differs beyond hash order", sourceLocation: sourceLocation)
                break
            }
        }
    }
}

/// A frame's content with patch order taken out: canonical JSON text of the frame, with each
/// state update's entries sorted and its dynamic-key definitions moved to a sorted list. Nil
/// when the frame doesn't decode.
func orderFreeFrameForm(_ data: Data) -> String? {
    let decoded: Any
    if let first = data.first, first == UInt8(ascii: "[") || first == UInt8(ascii: "{"),
       let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        decoded = json
    } else if let packed = try? unpack(data) {
        decoded = jsonCompatible(packed)
    } else {
        return nil
    }
    return canonicalText(orderFree(decoded))
}

/// Opcode state updates are `[0|1|2, entry…]`; a merged frame is `[107, update, events]`; the
/// JSON encoding's update is an object with `type` and `patches`.
private func orderFree(_ value: Any) -> Any {
    if let array = value as? [Any] {
        if let opcode = array.first as? Int, (0...2).contains(opcode), array.dropFirst().allSatisfy({ $0 is [Any] }) {
            var definitions: [String] = []
            let entries = array.dropFirst().map { entry -> String in
                var fields = entry as! [Any]
                if fields.count > 1 { fields[1] = slotsOnly(fields[1], definitions: &definitions) }
                return canonicalText(fields)
            }
            return [opcode, entries.sorted(), definitions.sorted()] as [Any]
        }
        if let opcode = array.first as? Int, opcode == 107, array.count == 3 {
            return [107, orderFree(array[1]), array[2]] as [Any]
        }
        return array.map(orderFree)
    }
    if let object = value as? [String: Any] {
        var result = object.mapValues(orderFree)
        if object["type"] is String, let patches = object["patches"] as? [Any] {
            result["patches"] = patches.map(canonicalText).sorted()
        }
        return result
    }
    return value
}

/// A dynamic-key field with each `[slot, "key"]` definition replaced by its slot, the
/// definitions collected: which entry carries a definition depends on patch order.
private func slotsOnly(_ value: Any, definitions: inout [String]) -> Any {
    guard let array = value as? [Any] else { return value }
    if array.count == 2, let slot = array[0] as? Int, let key = array[1] as? String {
        definitions.append("\(slot)=\(key)")
        return slot
    }
    return array.map { slotsOnly($0, definitions: &definitions) }
}

private func jsonCompatible(_ value: MessagePackValue) -> Any {
    switch value {
    case .nil: return NSNull()
    case .bool(let v): return v
    case .int(let v): return Int(v)
    case .uint(let v): return Int(v)
    case .float(let v): return Double(v)
    case .double(let v): return v
    case .string(let v): return v
    case .binary(let v): return v.base64EncodedString()
    case .array(let v): return v.map(jsonCompatible)
    case .map(let v):
        var object: [String: Any] = [:]
        for (key, item) in v { object["\(jsonCompatible(key))"] = jsonCompatible(item) }
        return object
    case .extended(let type, let data): return ["ext": Int(type), "data": data.base64EncodedString()]
    }
}

private func canonicalText(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
        return "\(value)"
    }
    return String(decoding: data, as: UTF8.self)
}

@Suite("Dirty tracking on and off send the same frames", .timeLimit(.minutes(1)))
struct DirtyTrackingByteIdentityTests {
    @Test("The same script sends the same frames with dirty tracking on and off", arguments: dirtyIdentityEncodings.map(\.0))
    func onAndOffSendIdenticalFrames(encodingName: String) async throws {
        let encoding = try #require(dirtyIdentityEncodings.first { $0.0 == encodingName }?.1)
        let on = await DirtyIdentityRun(envConfig: dirtyIdentityConfig(dirtyTracking: true), encoding: encoding)
        let off = await DirtyIdentityRun(envConfig: dirtyIdentityConfig(dirtyTracking: false), encoding: encoding)
        try await on.runScript()
        try await off.runScript()
        let onFrames = await on.transport.sent
        let offFrames = await off.transport.sent
        #expect(onFrames.count > 20, "the script sends frames")
        expectSameFrames(onFrames, offFrames, encodingName)
    }
}

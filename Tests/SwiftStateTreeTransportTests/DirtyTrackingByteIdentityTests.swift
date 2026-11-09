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

/// An entity: a state node with fields of its own, kept in a map (`units`) and nested (`boss`).
@StateNodeBuilder
struct DirtyIdentityUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 100
    @Sync(.broadcast) var x: Int = 0

    public init() {}
}

@StateNodeBuilder
struct DirtyIdentityState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var title: String = ""
    @Sync(.broadcast) var monsters: [Int: Int] = [:]
    @Sync(.broadcast) var positions: [String: Int] = [:]
    @Sync(.broadcast) var units: [Int: DirtyIdentityUnit] = [:]
    @Sync(.broadcast) var boss: DirtyIdentityUnit = DirtyIdentityUnit()
    @Sync(.perPlayerSlice()) var inventories: [PlayerID: [String]] = [:]
    @Sync(.serverOnly) var secret: Int = 0

    public init() {}
}

/// One script step. `@Payload` rejects optionals: 0 and "" mean "none".
@Payload
struct DirtyIdentityStep: ClientEventPayload {
    let addMonster: Int
    let removeMonster: Int
    let addUnit: Int
    let removeUnit: Int
    let hitUnit: Int
    let moveBoss: Int
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
                if step.addUnit != 0 {
                    var unit = DirtyIdentityUnit()
                    unit.x = step.addUnit
                    state.units[step.addUnit] = unit
                }
                if step.removeUnit != 0 { state.units.removeValue(forKey: step.removeUnit) }
                if step.hitUnit != 0 { state.units[step.hitUnit]?.hp -= 7 }
                if step.moveBoss != 0 { state.boss.x += step.moveBoss }
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
        item: String = "", clearInventory: Bool = false, secretOnly: Bool = false,
        addUnit: Int = 0, removeUnit: Int = 0, hitUnit: Int = 0, moveBoss: Int = 0
    ) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(DirtyIdentityStep(
                addMonster: add, removeMonster: remove,
                addUnit: addUnit, removeUnit: removeUnit, hitUnit: hitUnit, moveBoss: moveBoss,
                moveAll: move, title: title,
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

    /// The fixed script: joins, broadcast and per-player changes, entities added, changed and
    /// removed in a map and a nested one moved, a server-only change, an idle sync, removals, a
    /// vanished and restored per-player slice, a leave and a late join.
    func runScript() async throws {
        for n in 1...3 { try await join(n) }
        await sync()
        for round in 1...4 {
            try await step(1, add: round, title: "r\(round)", addUnit: round)
            try await step(2, move: round, item: "item\(round)")
            if round > 1 { try await step(3, hitUnit: round - 1, moveBoss: round) }
            await sync()
        }
        await sync()
        try await step(2, secretOnly: true)
        await sync()
        try await step(3, remove: 2, move: -1, removeUnit: 2, hitUnit: 3)
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
        for (side, frames) in [("first", mine), ("second", theirs)] {
            if let problem = slotUseBeforeDefinition(frames) {
                Issue.record("\(label): \(target), \(side) run: \(problem)", sourceLocation: sourceLocation)
            }
        }
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

/// A frame decoded to JSON-compatible values: JSON text as is, MessagePack unpacked.
private func decodedFrame(_ data: Data) -> Any? {
    if let first = data.first, first == UInt8(ascii: "[") || first == UInt8(ascii: "{") {
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    return (try? unpack(data)).map(jsonCompatible)
}

/// A frame's content with hash order taken out, or nil when it doesn't decode. Only the state
/// update's entry list is normalized, at its known position in the frame:
/// - an opcode state update `[opcode 0–3, seq?, entry…]` (the sequence, when the frame carries
///   one, is the integer at index 1 and is kept), alone or as the update of a merged
///   `[107, update, events]` frame, whose events are kept as sent;
/// - a JSON-object update `{"type", "patches", …}`.
/// Entries are grouped by path, the groups sorted, and the order within a group kept: the order
/// of two patches on one path matters. An opcode entry's path is its path string, or its path
/// hash and dynamic-key slots; a `[slot, "key"]` definition is replaced by its slot and the frame's
/// definitions are compared as a sorted list, since which entry carries one follows patch
/// order. Since #292 the slots themselves don't. Any other frame is compared as decoded.
func orderFreeFrameForm(_ data: Data) -> String? {
    guard let frame = decodedFrame(data) else { return nil }
    if let array = frame as? [Any], let opcode = array.first as? Int {
        if opcode == 107, array.count == 3, let update = array[1] as? [Any],
           let normalized = orderFreeOpcodeUpdate(update) {
            return canonicalText([107, normalized, array[2]] as [Any])
        }
        if let normalized = orderFreeOpcodeUpdate(array) {
            return canonicalText(normalized)
        }
    }
    if var object = frame as? [String: Any], object["type"] is String, let patches = object["patches"] as? [Any] {
        let grouped = Dictionary(grouping: patches, by: { (($0 as? [String: Any])?["path"] as? String) ?? "" })
        object["patches"] = grouped.keys.sorted().map { [$0, grouped[$0]!.map(canonicalText)] as [Any] }
        return canonicalText(object)
    }
    return canonicalText(frame)
}

private func orderFreeOpcodeUpdate(_ update: [Any]) -> [Any]? {
    guard let opcode = update.first as? Int, (0...3).contains(opcode) else { return nil }
    var head: [Any] = [opcode]
    var rest = update.dropFirst()
    if let seq = rest.first, !(seq is [Any]) {
        head.append(seq)
        rest = rest.dropFirst()
    }
    guard rest.allSatisfy({ $0 is [Any] }) else { return nil }
    var definitions: [String] = []
    var groups: [String: [String]] = [:]
    for case var fields as [Any] in rest {
        let keyed = hasDynamicKeys(fields)
        if keyed { fields[1] = slotsOnly(fields[1], definitions: &definitions) }
        let path = canonicalText(Array(fields.prefix(keyed ? 2 : 1)))
        groups[path, default: []].append(canonicalText(fields))
    }
    let entries = groups.keys.sorted().map { [$0, groups[$0]!] as [Any] }
    return head + [entries, definitions.sorted()]
}

/// The first dynamic-key slot a recipient's frames use before defining it, or nil. The
/// decoder refuses such a frame, and a full sort of the entries would hide it.
func slotUseBeforeDefinition(_ frames: [Data]) -> String? {
    var defined = Set<Int>()
    for (index, data) in frames.enumerated() {
        guard let frame = decodedFrame(data) as? [Any], let opcode = frame.first as? Int else { continue }
        var update = frame
        if opcode == 107, frame.count == 3, let inner = frame[1] as? [Any] { update = inner }
        guard let updateOpcode = update.first as? Int, (0...3).contains(updateOpcode) else { continue }
        if updateOpcode == 1 || updateOpcode == 3 { defined.removeAll() }
        for case let fields as [Any] in update.dropFirst() where hasDynamicKeys(fields) {
            var uses: [(slot: Int, defines: Bool)] = []
            collectSlots(fields[1], into: &uses)
            for use in uses {
                if use.defines { defined.insert(use.slot) }
                else if !defined.contains(use.slot) { return "frame \(index) uses slot \(use.slot) before defining it" }
            }
        }
    }
    return nil
}

/// Whether an opcode entry carries a dynamic-key field: a path-hash or path-index entry
/// `[pathHash, keys, op, value…]` does, a path-string entry `[path, op, value]` doesn't.
private func hasDynamicKeys(_ fields: [Any]) -> Bool {
    fields.count > 1 && fields[0] is Int
}

private func collectSlots(_ value: Any, into uses: inout [(slot: Int, defines: Bool)]) {
    if let slot = value as? Int { uses.append((slot, false)); return }
    guard let array = value as? [Any] else { return }
    if array.count == 2, let slot = array[0] as? Int, array[1] is String {
        uses.append((slot, true))
        return
    }
    array.forEach { collectSlots($0, into: &uses) }
}

/// A dynamic-key field with each `[slot, "key"]` definition replaced by its slot, the
/// definitions collected.
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

@Suite("The frame comparison takes out hash order only")
struct OrderFreeFrameFormTests {
    private func form(_ text: String) -> String? {
        orderFreeFrameForm(Data(text.utf8))
    }

    @Test("Independent entries or definitions in another order compare equal")
    func independentOrderIsTakenOut() {
        // Two patches on different paths, swapped; the key definition moves with its first use.
        #expect(form(#"[2,7,[11,[0,"a"],1,5],[12,0,1,6]]"#) == form(#"[2,7,[12,[0,"a"],1,6],[11,0,1,5]]"#))
        // Path-string entries (a first sync), whose second field is the operation, not keys.
        #expect(form(#"[1,["/round",1,0],["/title",1,""]]"#) == form(#"[1,["/title",1,""],["/round",1,0]]"#))
        // The same inside a merged frame, with its events kept.
        #expect(form(#"[107,[2,[11,null,1,5],[12,null,1,6]],[[103,"e"]]]"#) == form(#"[107,[2,[12,null,1,6],[11,null,1,5]],[[103,"e"]]]"#))
        // JSON-object frames.
        #expect(form(#"{"type":"diff","patches":[{"path":"/a","op":"replace","value":1},{"path":"/b","op":"replace","value":2}]}"#)
            == form(#"{"type":"diff","patches":[{"path":"/b","op":"replace","value":2},{"path":"/a","op":"replace","value":1}]}"#))
    }

    @Test("A changed value, an extra or duplicated entry, or a same-path reorder differs")
    func contentDifferencesRemain() {
        let base = #"[2,7,[11,null,1,5],[12,null,1,6]]"#
        #expect(form(base) != form(#"[2,7,[11,null,1,5],[12,null,1,9]]"#), "a changed value")
        #expect(form(base) != form(#"[2,7,[11,null,1,5],[12,null,1,6],[13,null,1,1]]"#), "an extra entry")
        #expect(form(base) != form(#"[2,7,[11,null,1,5],[12,null,1,6],[12,null,1,6]]"#), "a duplicated entry")
        #expect(form(base) != form(#"[2,8,[11,null,1,5],[12,null,1,6]]"#), "another sync sequence")
        // Two patches on one path (a remove, then a set) in the other order.
        #expect(form(#"[2,[11,[0,"a"],3],[11,0,1,4]]"#) != form(#"[2,[11,[0,"a"],1,4],[11,0,3]]"#), "same-path reorder")
        #expect(form(#"[1,["/a",3],["/a",1,4]]"#) != form(#"[1,["/a",1,4],["/a",3]]"#), "same-path reorder (path strings)")
        // An event payload array is not an entry list.
        #expect(form(#"[107,[2,[11,null,1,5]],[[103,[1,2]]]]"#) != form(#"[107,[2,[11,null,1,5]],[[103,[2,1]]]]"#), "event payload order")
        #expect(form(#"{"type":"diff","patches":[{"path":"/a","op":"remove"},{"path":"/a","op":"add","value":1}]}"#)
            != form(#"{"type":"diff","patches":[{"path":"/a","op":"add","value":1},{"path":"/a","op":"remove"}]}"#), "same-path reorder (JSON object)")
    }

    @Test("A slot used before its definition is reported")
    func slotUseBeforeDefinitionIsReported() {
        let defineThenUse = [#"[2,[11,[0,"a"],1,5]]"#, #"[2,[11,0,1,6]]"#].map { Data($0.utf8) }
        let useThenDefine = [#"[2,[11,0,1,6],[12,[0,"a"],1,5]]"#].map { Data($0.utf8) }
        #expect(slotUseBeforeDefinition(defineThenUse) == nil)
        #expect(slotUseBeforeDefinition(useThenDefine) != nil)
        // A path-string entry's operation code is not a slot.
        #expect(slotUseBeforeDefinition([Data(#"[1,["/round",1,0]]"#.utf8)]) == nil)
    }
}

// Tests/SwiftStateTreeTransportTests/PackDepthTests.swift
//
// #697: a frame the server builds may nest at most `messagePackMaxNestingDepth` (64) arrays and
// maps, counted as the unpacker counts them. The packer refuses a deeper frame, which the
// server's own readers would refuse, so the encode fails and the land ends (fail fast) instead
// of sending it. A typed leaf that writes objects nested deeper than any frame can hold is
// refused as it writes them, so it never builds a value deep enough to exhaust the stack.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Values of a given depth

/// How a value nests its containers.
enum PackDepthShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// Arrays in arrays.
    case arrays
    /// Maps in maps, under string keys.
    case maps
    /// Arrays around a map whose key is an array: the key counts as a level, as it does when
    /// unpacking.
    case containerKey
    var testDescription: String { rawValue }

    /// A value with `depth` nested containers (`depth` ≥ 2 for `containerKey`).
    func value(depth: Int) -> MessagePackValue {
        switch self {
        case .arrays:
            return (0..<depth).reduce(MessagePackValue.int(1)) { inner, _ in .array([inner]) }
        case .maps:
            return (0..<depth).reduce(MessagePackValue.int(1)) { inner, _ in .map([.string("n"): inner]) }
        case .containerKey:
            let keyed = MessagePackValue.map([.array([.int(1)]): .int(2)])
            return (0..<(depth - 2)).reduce(keyed) { inner, _ in .array([inner]) }
        }
    }
}

/// A leaf that writes `depth` objects, one inside another: `{"n": {"n": ... 1}}`. Its `Codable`
/// form is only the depth; the MessagePack writer is what builds the nesting.
struct NestedObjectsLeaf: _PayloadWireLeaf, Codable, Sendable, Equatable {
    let depth: Int

    func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        for _ in 0..<depth {
            writer.object(count: 1)
            writer.key("n")
        }
        writer.int(1)
    }
}

@Payload
struct NestedLeafEvent: ServerEventPayload {
    let leaf: NestedObjectsLeaf
}

private func writeNestedLeaf(depth: Int) throws -> MessagePackValue {
    var writer = MessagePackPayloadFieldWriter()
    try writer.leaf(NestedObjectsLeaf(depth: depth))
    return try #require(writer.fields.first)
}

// MARK: - Lands

/// A land whose tick emits a `NestedLeafEvent` of `depth` objects to `target`, and syncs.
private func makeNestedLeafLand(depth: Int, target: SwiftStateTree.EventTarget) -> LandDefinition<UntypedPayloadState> {
    Land("pack-depth-event", using: UntypedPayloadState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout UntypedPayloadState, ctx: LandContext) in
                state.round += 1
                ctx.emitEvent(NestedLeafEvent(leaf: NestedObjectsLeaf(depth: depth)), to: target)
                ctx.requestSyncNow()
            }
        }
        ServerEvents {
            Register(NestedLeafEvent.self)
        }
    }
}

/// A node whose `children` nest it: each level is two containers in a snapshot (the node's
/// object and the map of its children).
@StateNodeBuilder
struct PackDepthNode: StateNodeProtocol {
    @Sync(.broadcast) var children: [String: PackDepthNode] = [:]
}

@StateNodeBuilder
struct PackDepthState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var tree: PackDepthNode = PackDepthNode()
}

/// `levels` nodes, each the only child of the one above.
private func packDepthChain(levels: Int) -> PackDepthNode {
    var node = PackDepthNode()
    for _ in 0..<levels {
        var parent = PackDepthNode()
        parent.children["c"] = node
        node = parent
    }
    return node
}

/// A land whose tick sets its tree to `levels` nested nodes, and syncs.
private func makeDeepStateLand(levels: Int) -> LandDefinition<PackDepthState> {
    Land("pack-depth-state", using: PackDepthState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout PackDepthState, ctx: LandContext) in
                state.round += 1
                state.tree = packDepthChain(levels: levels)
                ctx.requestSyncNow()
            }
        }
    }
}

/// One `PackDepthState` land with one joined session, on MessagePack.
private struct DeepStateLand {
    let keeper: LandKeeper<PackDepthState>
    let adapter: TransportAdapter<PackDepthState>
    let transport: UntypedPayloadTransport

    static func make(levels: Int) async throws -> DeepStateLand {
        let definition = makeDeepStateLand(levels: levels)
        let transport = UntypedPayloadTransport()
        let keeper = LandKeeper<PackDepthState>(definition: definition, initialState: PackDepthState())
        let adapter = TransportAdapter<PackDepthState>(
            keeper: keeper, transport: transport, landID: definition.id, encodingConfig: .messagepack)
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let session = SessionID("s1")
        let client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"), waitsByEvent: true)
        return DeepStateLand(keeper: keeper, adapter: adapter, transport: transport)
    }
}

/// The deepest nesting of arrays and maps in `value`, counted as the unpacker counts it (a map's
/// keys included). Recursive: only for the shallow values these tests measure.
private func nestingDepth(_ value: MessagePackValue) -> Int {
    switch value {
    case .array(let elements):
        return 1 + (elements.map(nestingDepth).max() ?? 0)
    case .map(let pairs):
        return 1 + (pairs.map { max(nestingDepth($0.key), nestingDepth($0.value)) }.max() ?? 0)
    default:
        return 0
    }
}

@Payload
struct PackDepthAction: ActionPayload {
    typealias Response = PackDepthReply
    let depth: Int
}

@Payload
struct PackDepthReply: ResponsePayload {
    let leaf: NestedObjectsLeaf
}

/// A land whose action answers with a leaf of `action.depth` nested objects.
private func makeDeepResponseLand() -> LandDefinition<UntypedPayloadState> {
    Land("pack-depth-response", using: UntypedPayloadState.self) {
        Rules {
            HandleAction(PackDepthAction.self) {
                (_: inout UntypedPayloadState, action: PackDepthAction, _: LandContext) in
                PackDepthReply(leaf: NestedObjectsLeaf(depth: action.depth))
            }
        }
    }
}

/// Sends one `PackDepthAction` from the land's session, as a client frame; returns once the
/// adapter has handled it (answered it or ended the land).
private func sendDeepAction(_ land: UntypedPayloadLand, depth: Int) async throws {
    let envelope = ActionEnvelope(
        typeIdentifier: String(describing: PackDepthAction.self),
        payload: AnyCodable(PackDepthAction(depth: depth))
    )
    let frame = try land.encoding.config.makeCodec().encode(TransportMessage.action(requestID: "r1", action: envelope))
    await land.adapter.onMessage(frame, from: UntypedPayloadLand.session)
}

/// The frames `transport` received after the first `before`.
private func framesSent(_ transport: UntypedPayloadTransport, after before: Int) async -> [Data] {
    Array(await transport.sent.dropFirst(before))
}

/// The opcode of a MessagePack frame (its first element).
private func opcode(_ frame: MessagePackValue) -> Int64? {
    guard case .array(let elements) = frame, let first = elements.first else { return nil }
    switch first {
    case .int(let value): return value
    case .uint(let value): return Int64(exactly: value)
    default: return nil
    }
}

@Suite("A server-built MessagePack frame nests at most 64 deep; a deeper one ends the land (#697)", .serialized, .timeLimit(.minutes(1)))
struct PackDepthTests {
    // MARK: Packer

    @Test("The packer refuses exactly the values the unpacker refuses, at the default limit",
          arguments: PackDepthShape.allCases)
    func packerAgreesWithUnpacker(shape: PackDepthShape) throws {
        let limit = messagePackMaxNestingDepth
        #expect(limit == PayloadNesting.serverFrameMaxDepth)
        for depth in max(2, limit - 2)...(limit + 2) {
            let value = shape.value(depth: depth)
            // Bytes written with no limit, to ask the unpacker.
            let unbounded = try pack(value, maxDepth: .max)
            let unpacks = (try? unpack(unbounded)) != nil
            let packed = try? pack(value)
            #expect((packed != nil) == unpacks, "\(shape) at \(depth): pack and unpack disagree")
            #expect((packed != nil) == (depth <= limit), "\(shape) at \(depth)")
            if let packed {
                #expect(packed == unbounded, "\(shape) at \(depth): the bound changes no byte")
                #expect(try unpack(packed) == value, "\(shape) at \(depth): round trip")
            }
        }
    }

    @Test("Past the limit, pack throws the unpacker's error")
    func packerError() {
        let error = #expect(throws: MessagePackError.self) {
            _ = try pack(PackDepthShape.arrays.value(depth: messagePackMaxNestingDepth + 1))
        }
        guard case .invalidData(let reason)? = error else {
            Issue.record("expected invalidData, got \(String(describing: error))")
            return
        }
        #expect(reason == "Nesting deeper than \(messagePackMaxNestingDepth)")
    }

    @Test("Siblings each nested to the limit pack: the depth goes back down after each container")
    func siblingsAtTheLimit() throws {
        let limit = messagePackMaxNestingDepth
        // In one array: two siblings 63 deep, and a map whose value is 62 deep. Each path is 64
        // levels, so the whole value is as deep as one of them.
        let inner = PackDepthShape.arrays.value(depth: limit - 1)
        let mapped = MessagePackValue.map([.string("k"): PackDepthShape.arrays.value(depth: limit - 2)])
        let siblings = MessagePackValue.array([inner, inner, mapped])
        let packed = try pack(siblings)
        #expect(try unpack(packed) == siblings)
        #expect(nestingDepth(siblings) == limit)
    }

    // MARK: Leaf writer

    @Test("A leaf may write objects nested 64 deep; one more is refused with an encoding error")
    func leafWriterBound() throws {
        let limit = messagePackMaxNestingDepth
        let atLimit = try writeNestedLeaf(depth: limit)
        #expect(atLimit == PackDepthShape.maps.value(depth: limit))
        var writer = MessagePackPayloadFieldWriter()
        let error = #expect(throws: EncodingError.self) { try writer.leaf(NestedObjectsLeaf(depth: limit + 1)) }
        guard case let .invalidValue(_, context)? = error else {
            Issue.record("expected invalidValue, got \(String(describing: error))")
            return
        }
        #expect(context.debugDescription.contains("nested deeper than \(limit)"), "\(context.debugDescription)")
    }

    // Exit codes of the child: 0 pass; 10 the leaf was written; 20 it threw something else.
    @Test("A leaf that writes 100,000 nested objects is refused, and the process keeps running (exit test)")
    func deepLeafDoesNotCrash() async {
        await #expect(processExitsWith: .success) {
            var writer = MessagePackPayloadFieldWriter()
            do {
                try writer.leaf(NestedObjectsLeaf(depth: 100_000))
                exit(10)
            } catch is EncodingError {
                exit(0)
            } catch {
                exit(20)
            }
        }
    }

    // MARK: Lands

    // In an opcode 107 frame a payload field sits 4 containers deep: the frame, its events, the
    // event's body, its positional payload. In an opcode 103 frame, 2: the frame (the body is
    // spliced into it) and the payload.

    @Test("A broadcast event at the deepest the merged frame holds is sent and unpacks; one level more ends the land with .eventEncode",
          arguments: [(60, true), (61, false)])
    func mergedEventDepth(leafDepth: Int, fits: Bool) async throws {
        try await expectEventDepth(leafDepth: leafDepth, fits: fits, target: .all, opcode: Int64(MessageKindOpcode.stateUpdateWithEvents))
    }

    @Test("A targeted event at the deepest its own frame holds is sent and unpacks; one level more ends the land with .eventEncode",
          arguments: [(62, true), (63, false)])
    func targetedEventDepth(leafDepth: Int, fits: Bool) async throws {
        try await expectEventDepth(leafDepth: leafDepth, fits: fits, target: .player(UntypedPayloadLand.player), opcode: Int64(MessageKindOpcode.event.rawValue))
    }

    @Test("A leaf deeper than any frame is refused when its body is written: the event is lost and the land ends with .eventEncode")
    func leafPastTheWriterBound() async throws {
        let land = try await UntypedPayloadLand.make(
            makeNestedLeafLand(depth: messagePackMaxNestingDepth + 1, target: .all), encoding: .messagepack, waitsByEvent: true)
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        await land.tick()
        try #require(await land.keeper.waitForFailureForTesting(), "the land failed")
        await land.keeper.waitUntilDrained()
        #expect(land.keeper.failure?.kind == .eventEncode)
        #expect(land.keeper.failure?.detail == "event NestedLeaf did not encode", "\(String(describing: land.keeper.failure))")
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == before, "the failing tick sends nothing")
        #expect(await land.transport.closes == [SessionClose.Code.landFailed])
    }

    // MARK: State frames

    /// The state frame's own levels sit around the patch value. They are measured on a shallow
    /// frame, so the deepest value that fits is exact: it encodes to a frame exactly 64 deep, and
    /// one level more is refused by the packer. The value is built iteratively, so nothing
    /// recurses before the encoder does.
    @Test("A state frame deeper than 64 is refused by the packer; the deepest one that fits is exactly 64 deep")
    func stateFrameBound() throws {
        let encoder = OpcodeMessagePackStateUpdateEncoder()
        func frame(_ depth: Int) throws -> Data {
            let value = (0..<depth).reduce(SnapshotValue.int(1)) { inner, _ in .object(["n": inner]) }
            let update = StateUpdate.diff([StatePatch(path: "/tree", operation: .set(value))])
            return try encoder.encode(update: update, landID: "pack-depth-state", playerID: PlayerID("p1"))
        }
        let limit = messagePackMaxNestingDepth
        let overhead = nestingDepth(try unpack(frame(2))) - 2
        #expect(overhead >= 1, "the frame has levels of its own")
        let deepest = limit - overhead
        for depth in (deepest - 2)...deepest {
            let fits = try frame(depth)
            #expect(nestingDepth(try unpack(fits)) == depth + overhead, "depth \(depth)")
        }
        #expect(nestingDepth(try unpack(frame(deepest))) == limit)
        for depth in (deepest + 1)...(deepest + 2) {
            let error = #expect(throws: MessagePackError.self, "depth \(depth)") { _ = try frame(depth) }
            guard case .invalidData(let reason)? = error else {
                Issue.record("depth \(depth): expected invalidData, got \(String(describing: error))")
                continue
            }
            #expect(reason == "Nesting deeper than \(limit)", "depth \(depth)")
        }
    }

    // MARK: Merged state frames (opcode 107)

    /// A state array whose own frame nests `frameDepth` containers: the frame and an array chain.
    private func stateArray(frameDepth: Int) -> [MessagePackValue] {
        [.int(0), PackDepthShape.arrays.value(depth: frameDepth - 1)]
    }

    /// In `[107, state, events]` the state sits one level deeper than in its own frame. A state
    /// whose own frame doesn't pack is the state's failure (a plain pack error, which the adapter
    /// reports as `.syncEncode`), with or without events. One whose own frame packs but not merged
    /// ends the land with `.eventEncode` only when events are pending, and says the state alone
    /// packs; without events the state frame goes alone.
    @Test("A merged frame that doesn't pack blames the state when the state alone doesn't pack, and the events otherwise",
          arguments: [(63, true), (63, false), (64, true), (64, false), (65, true), (65, false)])
    func mergedStateDepth(frameDepth: Int, withEvent: Bool) throws {
        let pipeline = EncodingPipeline(
            stateUpdateEncoder: OpcodeMessagePackStateUpdateEncoder(),
            messageEncoder: MessagePackTransportMessageEncoder(),
            landID: "pack-depth-merge"
        )
        let state = stateArray(frameDepth: frameDepth)
        let events: [MessagePackValue] = withEvent ? [.array([.int(1), .int(2)])] : []
        let label = "state frame \(frameDepth), \(withEvent ? "one event" : "no event")"
        let limit = messagePackMaxNestingDepth
        do {
            let data = try pipeline.mergeEvents(into: .array(state), eventBodies: events, failsPack: false)
            let frame = try unpack(data)
            if frameDepth + 1 <= limit {
                #expect(opcode(frame) == Int64(MessageKindOpcode.stateUpdateWithEvents), "\(label): merged")
            } else {
                #expect(frameDepth <= limit && !withEvent, "\(label): sent although it can't be")
                #expect(opcode(frame) == 0 && nestingDepth(frame) == frameDepth, "\(label): the state frame alone")
            }
        } catch let failure as LandFailure {
            #expect(frameDepth == limit && withEvent, "\(label): \(failure)")
            #expect(failure.kind == .eventEncode, "\(label)")
            #expect(failure.detail.contains("Nesting deeper than \(limit)"), "\(label): \(failure.detail)")
            #expect(failure.detail.contains("the state frame alone packs, but it nests \(limit) deep"), "\(label): \(failure.detail)")
        } catch let error as MessagePackError {
            #expect(frameDepth > limit, "\(label): \(error)")
            guard case .invalidData(let reason) = error else {
                Issue.record("\(label): expected invalidData, got \(error)")
                return
            }
            #expect(reason == "Nesting deeper than \(limit)", "\(label)")
        }
    }

    // MARK: Responses

    // A typed response doesn't go through the state snapshot, so a land-level case can pass the
    // limit. The leaf stays under the writer's own 64, so the refusal is the packer's.
    @Test("A response that nests past 64 ends the land with .responseEncode and sends nothing; a shallower one is answered",
          arguments: [(40, true), (63, false)])
    func responseDepth(leafDepth: Int, fits: Bool) async throws {
        let land = try await UntypedPayloadLand.make(makeDeepResponseLand(), encoding: .messagepack, waitsByEvent: true)
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        try await sendDeepAction(land, depth: leafDepth)
        await land.adapter.waitForOutboundIdleForTesting()
        let label = "leaf \(leafDepth)"
        if fits {
            await land.keeper.waitUntilDrained()
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(land.keeper.failure == nil, "\(label): \(String(describing: land.keeper.failure))")
            let frames = try await framesSent(land.transport, after: before).map { try unpack($0) }
            #expect(frames.contains { nestingDepth($0) >= leafDepth }, "\(label): the answer carries the leaf")
        } else {
            try #require(await land.keeper.waitForFailureForTesting(), "\(label): the land failed")
            await land.keeper.waitUntilDrained()
            #expect(land.keeper.failure?.kind == .responseEncode, "\(label): \(String(describing: land.keeper.failure))")
            #expect(land.keeper.failure?.detail.contains("Nesting deeper than \(messagePackMaxNestingDepth)") == true,
                    "\(label): the packer's refusal, not the writer's: \(String(describing: land.keeper.failure))")
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(await land.transport.sends == before, "\(label): no answer was sent")
            #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(label)")
        }
    }

    /// A land's state reaches the packer through its snapshot, which recurses once per level of
    /// nested state nodes. The state conversion's budget (#716) refuses a tree past
    /// `stateMaxDepth` before it recurses deeper, so the land-level cases sit at the limit;
    /// `stateFrameBound` checks the packer's refusal at the encoder.
    @Test("Nested state within the state limit syncs, and its frames unpack")
    func shallowStateSyncs() async throws {
        // 2·(levels + 1) containers: exactly at the limit, as the whole value counts them (the
        // sync path without tables). The sync tables count 2 fewer, since a map row starts from
        // the root budget (#716 S1a-2), so this converts on both paths.
        let levels = PayloadNesting.stateMaxDepth / 2 - 1
        let land = try await DeepStateLand.make(levels: levels)
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        await land.keeper.stepTickOnce()
        await land.keeper.waitUntilDrained()
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(land.keeper.failure == nil, "\(String(describing: land.keeper.failure))")
        let frames = await framesSent(land.transport, after: before)
        #expect(!frames.isEmpty, "the sync sent a frame")
        for frame in frames { #expect(throws: Never.self) { _ = try unpack(frame) } }
        // `levels` levels of nodes, 2 containers each: some frame carries the whole tree.
        let depths = try frames.map { nestingDepth(try unpack($0)) }
        #expect((depths.max() ?? 0) >= 2 * levels, "the tree is in a frame: \(depths)")
    }

    @Test("Nested state past the state limit ends the land with syncConversion, naming the field (#716)")
    func statePastTheLimitEndsTheLand() async throws {
        // The shallowest chain of this shape refused on both sync paths: the tables' count, 2
        // fewer than the whole value's, passes the limit only here.
        let land = try await DeepStateLand.make(levels: PayloadNesting.stateMaxDepth / 2 + 1)
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        await land.keeper.stepTickOnce()
        await land.keeper.waitUntilDrained()
        await land.adapter.waitForOutboundIdleForTesting()
        let failure = try #require(land.keeper.failure, "the land ended")
        #expect(failure.kind == .syncConversion, "\(failure)")
        #expect(failure.field == "tree", "\(failure)")
        #expect(failure.detail.contains("nestingTooDeep"), "\(failure)")
        #expect(await land.transport.sends == before, "no state frame went out")
    }

    private func expectEventDepth(leafDepth: Int, fits: Bool, target: SwiftStateTree.EventTarget, opcode expected: Int64) async throws {
        let land = try await UntypedPayloadLand.make(
            makeNestedLeafLand(depth: leafDepth, target: target), encoding: .messagepack, waitsByEvent: true)
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        await land.tick()
        let label = "leaf \(leafDepth), \(target)"
        if fits {
            await land.keeper.waitUntilDrained()
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(land.keeper.failure == nil, "\(label): \(String(describing: land.keeper.failure))")
            // Every frame unpacks at the default limit, and one of them carries the event.
            let frames = try await framesSent(land.transport, after: before).map { try unpack($0) }
            #expect(frames.contains { opcode($0) == expected }, "\(label): a frame with opcode \(expected)")
        } else {
            try #require(await land.keeper.waitForFailureForTesting(), "\(label): the land failed")
            await land.keeper.waitUntilDrained()
            #expect(land.keeper.failure?.kind == .eventEncode, "\(label): \(String(describing: land.keeper.failure))")
            #expect(land.keeper.failure?.detail.contains("Nesting deeper than \(messagePackMaxNestingDepth)") == true,
                    "\(label): the detail names the cause: \(String(describing: land.keeper.failure))")
            #expect(land.keeper.failure?.detail.contains("the state frame alone packs") == false,
                    "\(label): the state isn't blamed: \(String(describing: land.keeper.failure))")
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(await land.transport.sends == before, "\(label): the failing tick sends nothing")
            #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(label)")
        }
    }
}

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
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
        return DeepStateLand(keeper: keeper, adapter: adapter, transport: transport)
    }
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
        guard case .invalidData(let reason)? = error else { return }
        #expect(reason == "Nesting deeper than \(messagePackMaxNestingDepth)")
    }

    // MARK: Leaf writer

    @Test("A leaf may write objects nested 64 deep; one more is refused with an encoding error")
    func leafWriterBound() throws {
        let limit = messagePackMaxNestingDepth
        let atLimit = try writeNestedLeaf(depth: limit)
        #expect(atLimit == PackDepthShape.maps.value(depth: limit))
        var writer = MessagePackPayloadFieldWriter()
        let error = #expect(throws: EncodingError.self) { try writer.leaf(NestedObjectsLeaf(depth: limit + 1)) }
        guard case let .invalidValue(_, context)? = error else { return }
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
        let land = try await UntypedPayloadLand.make(makeNestedLeafLand(depth: messagePackMaxNestingDepth + 1, target: .all), encoding: .messagepack)
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

    /// The state frame's own levels sit around the patch value, so the deepest value that fits is
    /// found, not assumed: every depth up to it encodes and unpacks, and every depth past it is
    /// refused by the packer. The value is built iteratively, so nothing recurses before the
    /// encoder does.
    @Test("A state frame deeper than 64 is refused by the packer; every shallower one encodes and unpacks")
    func stateFrameBound() throws {
        let encoder = OpcodeMessagePackStateUpdateEncoder()
        var firstRefused: Int?
        for depth in 50...(messagePackMaxNestingDepth + 2) {
            let value = (0..<depth).reduce(SnapshotValue.int(1)) { inner, _ in .object(["n": inner]) }
            let update = StateUpdate.diff([StatePatch(path: "/tree", operation: .set(value))])
            do {
                let frame = try encoder.encode(update: update, landID: "pack-depth-state", playerID: PlayerID("p1"))
                #expect(firstRefused == nil, "depth \(depth) encodes after \(firstRefused ?? 0) was refused")
                #expect(throws: Never.self, "depth \(depth): the frame unpacks") { _ = try unpack(frame) }
            } catch let MessagePackError.invalidData(reason) {
                #expect(reason == "Nesting deeper than \(messagePackMaxNestingDepth)", "depth \(depth)")
                if firstRefused == nil { firstRefused = depth }
            }
        }
        let refused = try #require(firstRefused, "some depth up to the limit + 2 is refused")
        // The frame adds at least one level of its own, so the refusal starts at or below the limit.
        #expect(refused <= messagePackMaxNestingDepth)
    }

    /// A land's state reaches the packer through its snapshot, which recurses once per level of
    /// nested state nodes. Nested deep enough to pass 64, those levels can overflow the stack
    /// before the packer refuses the frame (#716), so the land-level case stays at a depth that
    /// fits; `stateFrameBound` checks the refusal at the encoder, and a thrown state encode ends
    /// the land with `.syncEncode` as for any state frame that doesn't encode.
    @Test("Nested state that fits in a frame syncs, and its frames unpack")
    func shallowStateSyncs() async throws {
        let land = try await DeepStateLand.make(levels: 20)
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        await land.keeper.stepTickOnce()
        await land.keeper.waitUntilDrained()
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(land.keeper.failure == nil, "\(String(describing: land.keeper.failure))")
        let frames = await framesSent(land.transport, after: before)
        #expect(!frames.isEmpty, "the sync sent a frame")
        for frame in frames { #expect(throws: Never.self) { _ = try unpack(frame) } }
    }

    private func expectEventDepth(leafDepth: Int, fits: Bool, target: SwiftStateTree.EventTarget, opcode expected: Int64) async throws {
        let land = try await UntypedPayloadLand.make(makeNestedLeafLand(depth: leafDepth, target: target), encoding: .messagepack)
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
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(await land.transport.sends == before, "\(label): the failing tick sends nothing")
            #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(label)")
        }
    }
}

// Tests/SwiftStateTreeTransportTests/MessagePackPayloadSourceTests.swift
//
// The MessagePack decode source (#521 PR 2), built directly from a value. On a client frame the
// unpacker bounds the depth (a payload inside a frame of at most 32 levels is at most 31 deep),
// so the source's own depth check can't fire there; it bounds a source made from any other value,
// and is pinned here at the limit and one past it, with arrays and with maps.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
import SwiftStateTreeTestSupport

@Payload
struct SourceProbeAction: ActionPayload {
    typealias Response = SourceProbeResponse
    let count: Int
    let deep: Nest
}

@Payload
struct SourceProbeResponse: ResponsePayload {
    let ok: Bool
}

@Suite("The MessagePack decode source refuses what today's intake refuses (#521 PR 2)")
struct MessagePackPayloadSourceTests {
    static let limit = PayloadNesting.clientFrameMaxDepth

    /// `levels` nested containers: arrays (`[[…]]`) or single-key maps (`{"k": {…}}`).
    static func nested(_ levels: Int, maps: Bool) -> MessagePackValue {
        var value: MessagePackValue = maps ? .map([:]) : .array([])
        for _ in 1..<max(1, levels) {
            value = maps ? .map([.string("k"): value]) : .array([value])
        }
        return value
    }

    @Test("A value nested to the limit passes; one past it throws TooDeep(limit: 32)", arguments: [false, true])
    func depthAtTheLimit(maps: Bool) throws {
        let atLimit = try MessagePackPayloadSource(validating: Self.nested(Self.limit, maps: maps))
        try atLimit.validateRecordable()
        let past = try MessagePackPayloadSource(validating: Self.nested(Self.limit + 1, maps: maps))
        #expect {
            try past.validateRecordable()
        } throws: { error in
            (error as? PayloadNesting.TooDeep)?.limit == Self.limit
        }
    }

    @Test("A map key that isn't a string is refused when the source is made, at any depth")
    func nonStringKeyRefused() {
        #expect(throws: (any Error).self) {
            _ = try MessagePackPayloadSource(validating: .map([.int(1): .bool(true)]))
        }
        #expect(throws: (any Error).self) {
            _ = try MessagePackPayloadSource(validating: .map([.string("a"): .array([.map([.int(1): .nil])])]))
        }
    }

    @Test("A non-finite number anywhere in the tree is refused by the whole-tree check",
          arguments: [MessagePackValue.double(.nan), .double(.infinity), .float(-.infinity)])
    func nonFiniteRefused(number: MessagePackValue) throws {
        let source = try MessagePackPayloadSource(validating: .map([
            .string("count"): .int(1),
            .string("deep"): .array([]),
            .string("undeclared"): .array([number]),
        ]))
        #expect(throws: EncodingError.self) { try source.validateRecordable() }
        #expect(throws: EncodingError.self) { _ = try source.makeRecordPayload() }
    }

    @Test("The source counts one walk, when it is made")
    func oneWalk() async throws {
        let walks = PayloadNesting.WalkCounter()
        try PayloadNesting.$walks.withValue(walks) {
            let source = try MessagePackPayloadSource(validating: .map([.string("count"): .int(3), .string("deep"): .array([.array([])])]))
            try source.validateRecordable()
            _ = try source.decode(SourceProbeAction.self)
            _ = source.boxedPayload
        }
        #expect(walks.count == 1)
    }

    @Test("It decodes into the type without JSON, and its tree is today's")
    func decodesAndBoxes() throws {
        let value: MessagePackValue = .map([.string("count"): .int(3), .string("deep"): .array([.array([]), .array([.array([])])])])
        let source = try MessagePackPayloadSource(validating: value)
        let action = try source.decode(SourceProbeAction.self)
        #expect(action.count == 3)
        #expect(action.deep == .node([.leaf, .nested(2)]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let boxed = String(decoding: try encoder.encode(source.boxedPayload), as: UTF8.self)
        #expect(boxed == #"{"count":3,"deep":[[],[[]]]}"#)
    }
}

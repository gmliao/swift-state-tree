// Tests/SwiftStateTreeTransportTests/WireIntegerConversionTests.swift
//
// A number from the wire that doesn't fit the type it decodes to is a decode error, never a
// trap: one crafted frame must not crash the process that decodes it. The same holds for a
// container whose declared count can't fit in the bytes left, and for nesting past the limit.
// On a decoder that traps, these tests crash the test process instead of failing.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMessagePack

private let codec = MessagePackTransportCodec()

private func packed(_ value: MessagePackValue) throws -> Data {
    try pack(value)
}

/// Out-of-range values for a field that decodes to `Int` or narrower.
private let oversizedIntegers: [MessagePackValue] = [
    .uint(UInt64.max),
    .uint(UInt64(Int64.max) + 1),
]

@Suite("Wire-fed integers: exact conversions that throw")
struct WireIntegerConversionTests {
    // MARK: Client-sent fields (server-side decode)

    @Test("A MessagePack event whose direction doesn't fit an Int throws", arguments: oversizedIntegers)
    func eventDirection(direction: MessagePackValue) throws {
        let frame = try packed(.array([.uint(103), direction, .string("Chat"), .map([:])]))
        #expect(throws: (any Error).self) { try codec.decode(TransportMessage.self, from: frame) }
    }

    @Test("A MessagePack opcode that doesn't fit an Int64 isn't an opcode: the frame throws")
    func oversizedOpcode() throws {
        let frame = try packed(.array([.uint(UInt64.max), .string("r"), .string("t"), .map([:])]))
        #expect(throws: (any Error).self) { try codec.decode(TransportMessage.self, from: frame) }
    }

    @Test("A sync ack with an oversized or negative sequence isn't an ack")
    func syncAckSequence() throws {
        #expect(SyncAckFrame.parse(try packed(.array([.uint(108), .int(-1)]))) == nil)
        #expect(SyncAckFrame.parse(try packed(.array([.uint(108), .uint(UInt64.max)]))) == UInt64.max)
        #expect(SyncAckFrame.parse(Data("[108,-1]".utf8)) == nil)
        #expect(SyncAckFrame.parse(Data("[108,1e400]".utf8)) == nil)
    }

    // MARK: Server-sent fields (client-side decode)

    @Test("A joinResponse playerSlot past Int32 throws, in the map form and the MessagePack opcode array", arguments: [
        MessagePackValue.uint(UInt64.max), .uint(UInt64(Int32.max) + 1), .int(Int64(Int32.min) - 1),
    ])
    func playerSlot(slot: MessagePackValue) throws {
        let map = try packed(.map([
            .string("kind"): .string("joinResponse"),
            .string("payload"): .map([.string("joinResponse"): .map([
                .string("requestID"): .string("r"),
                .string("success"): .bool(true),
                .string("playerSlot"): slot,
            ])]),
        ]))
        #expect(throws: (any Error).self) { try codec.decode(TransportMessage.self, from: map) }
        let array = try packed(.array([.uint(105), .string("r"), .uint(1), .string("game"), .string("room"), slot]))
        #expect(throws: (any Error).self) { try codec.decode(TransportMessage.self, from: array) }
    }

    @Test("A MessagePack joinResponse whose success flag doesn't fit an Int throws")
    func joinResponseSuccess() throws {
        let array = try packed(.array([.uint(105), .string("r"), .uint(UInt64.max)]))
        #expect(throws: (any Error).self) { try codec.decode(TransportMessage.self, from: array) }
    }

    @Test("A JSON opcode-array joinResponse playerSlot past Int32 throws", arguments: ["4294967296", "-2147483649"])
    func jsonPlayerSlot(slot: String) {
        let text = Data(#"[105,"r",1,"game","room",\#(slot)]"#.utf8)
        #expect(throws: (any Error).self) { try OpcodeTransportMessageDecoder().decode(from: text) }
    }

    @Test("A JSON state update that is empty, or whose path hash doesn't fit a UInt32, throws", arguments: [
        "[]", "[2,[-1,null,1,0]]", "[2,[4294967296,null,1,0]]",
    ])
    func jsonStateUpdate(text: String) {
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: PathHasher(pathHashes: ["count": 1]))
        #expect(throws: (any Error).self) { try decoder.decode(data: Data(text.utf8)) }
    }

    // MARK: Typed decode (MessagePackValueDecoder)

    private struct Narrow: Codable {
        let i8: Int8
        let i16: Int16
        let i32: Int32
        let u8: UInt8
        let u16: UInt16
        let u32: UInt32
        let u: UInt
        let i64: Int64
    }

    private static let fits: [String: MessagePackValue] = [
        "i8": .int(-128), "i16": .int(-32768), "i32": .int(Int64(Int32.min)),
        "u8": .uint(255), "u16": .uint(65535), "u32": .uint(UInt64(UInt32.max)),
        "u": .uint(UInt64.max), "i64": .int(Int64.min),
    ]

    @Test("A typed field decodes at its type's bounds")
    func typedFieldsAtBounds() throws {
        let map = MessagePackValue.map(Dictionary(uniqueKeysWithValues: Self.fits.map { (.string($0.key), $0.value) }))
        let value = try MessagePackSerializer().decode(Narrow.self, from: try packed(map))
        #expect(value.i8 == .min && value.u8 == .max && value.u32 == .max && value.u == .max && value.i64 == .min)
    }

    @Test("A typed field one past its type's range throws", arguments: [
        ("i8", MessagePackValue.int(128)), ("i8", .int(-129)),
        ("i16", .int(32768)), ("i32", .uint(UInt64(Int32.max) + 1)),
        ("u8", .uint(256)), ("u8", .int(-1)), ("u16", .int(-1)), ("u32", .uint(UInt64(UInt32.max) + 1)),
        ("u", .int(-1)), ("i64", .uint(UInt64.max)),
    ])
    func typedFieldOutOfRange(field: String, value: MessagePackValue) throws {
        var values = Self.fits
        values[field] = value
        let map = MessagePackValue.map(Dictionary(uniqueKeysWithValues: values.map { (.string($0.key), $0.value) }))
        #expect(throws: (any Error).self) { try MessagePackSerializer().decode(Narrow.self, from: try packed(map)) }
    }

    @Test("A typed array element past its type's range throws")
    func typedArrayElement() throws {
        #expect(throws: (any Error).self) {
            try MessagePackSerializer().decode([UInt8].self, from: try packed(.array([.uint(1), .uint(300)])))
        }
        #expect(throws: (any Error).self) {
            try MessagePackSerializer().decode(Int16.self, from: try packed(.int(Int64(Int16.max) + 1)))
        }
    }

    // MARK: Containers (the unpacker)

    @Test("An array or map whose count can't fit in the bytes left throws before reserving it", arguments: [
        [UInt8](arrayLiteral: 0xdd, 0xff, 0xff, 0xff, 0xff),
        [0xdf, 0xff, 0xff, 0xff, 0xff],
        [0xdc, 0xff, 0xff, 0x01],
        [0x9f, 0x01],
    ])
    func oversizedContainer(bytes: [UInt8]) {
        // The count check's own error: a reservation followed by a short read would end in
        // `unexpectedEOF` instead.
        do {
            _ = try unpack(Data(bytes))
            Issue.record("decoded")
        } catch MessagePackError.invalidData(let message) {
            #expect(message.hasPrefix("Container count"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Nesting past the limit throws; at the limit it decodes")
    func nesting() throws {
        let limit = messagePackMaxNestingDepth
        #expect(throws: (any Error).self) { try unpack(Data(repeating: 0x91, count: 100_000) + [0xc0]) }
        #expect(throws: (any Error).self) { try unpack(Data(repeating: 0x91, count: limit + 1) + [0xc0]) }
        _ = try unpack(Data(repeating: 0x91, count: limit) + [0xc0])
        #expect(throws: (any Error).self) {
            try codec.decode(TransportMessage.self, from: Data(repeating: 0x91, count: 100_000) + [0xc0])
        }
    }
}

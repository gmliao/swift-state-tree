// Tests/SwiftStateTreeTests/CanonicalMessagePackBinaryTests.swift
//
// `CanonicalBinary` in canonical MessagePack (#700 K1a, record format 3.7): written as `bin` in its
// shortest form and read back as the same bytes. A plain `Data` keeps its array form, so values
// recorded before 3.7 (a resolver output holding a `Data`) are written and read as before.

import Foundation
import Testing
@testable import SwiftStateTree

private struct BinaryHolder: Codable, Equatable {
    let bytes: CanonicalBinary
}

private struct PlainDataHolder: Codable, Equatable {
    let bytes: Data
}

@Suite("Canonical MessagePack writes CanonicalBinary as bin (#700 K1a)")
struct CanonicalMessagePackBinaryTests {
    @Test("CanonicalBinary is bin8, bin16 or bin32 by its length, and reads back", arguments: [0, 1, 255, 256, 65_535, 65_536])
    func binInShortestForm(count: Int) throws {
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let bytes = try CanonicalMessagePack.encode(CanonicalBinary(data))
        let header: [UInt8]
        switch count {
        case 0...0xff: header = [0xc4, UInt8(count)]
        case 0x100...0xffff: header = [0xc5, UInt8(count >> 8), UInt8(count & 0xff)]
        default: header = [0xc6, UInt8(count >> 24), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff), UInt8(count & 0xff)]
        }
        #expect(Array(bytes.prefix(header.count)) == header)
        #expect(Array(bytes.dropFirst(header.count)) == Array(data))
        #expect(try CanonicalMessagePack.decode(CanonicalBinary.self, from: bytes) == CanonicalBinary(data))
    }

    @Test("CanonicalBinary inside a value is bin, byte for byte")
    func binInsideAValue() throws {
        let value = BinaryHolder(bytes: CanonicalBinary(Data([1, 2, 250])))
        let bytes = try CanonicalMessagePack.encode(value)
        // fixmap(1), "bytes", bin8(3) 01 02 fa
        #expect(bytes == [0x81, 0xa5] + Array("bytes".utf8) + [0xc4, 3, 1, 2, 250])
        #expect(try CanonicalMessagePack.decode(BinaryHolder.self, from: bytes) == value)
    }

    @Test("A plain Data keeps its array form and reads into an AnyCodable tree, as before 3.7")
    func plainDataUnchanged() throws {
        let bytes = try CanonicalMessagePack.encode(PlainDataHolder(bytes: Data([1, 2, 250])))
        // fixmap(1), "bytes", fixarray(3) 1 2 uint8 250
        #expect(bytes == [0x81, 0xa5] + Array("bytes".utf8) + [0x93, 1, 2, 0xcc, 250])
        #expect(try CanonicalMessagePack.decode(PlainDataHolder.self, from: bytes) == PlainDataHolder(bytes: Data([1, 2, 250])))
        _ = try CanonicalMessagePack.decode(AnyCodable.self, from: bytes)
    }

    @Test("CanonicalBinary is base64 in JSON")
    func jsonIsBase64() throws {
        let json = try JSONEncoder().encode(BinaryHolder(bytes: CanonicalBinary(Data([1, 2, 250]))))
        #expect(String(decoding: json, as: UTF8.self) == #"{"bytes":"AQL6"}"#)
        #expect(try JSONDecoder().decode(BinaryHolder.self, from: json).bytes == CanonicalBinary(Data([1, 2, 250])))
    }

    @Test("A bin is refused where another type is expected, an array where bin is, and a truncated bin")
    func binRefusals() throws {
        #expect(throws: (any Error).self) { _ = try CanonicalMessagePack.decode(String.self, from: [0xc4, 1, 0x41]) }
        #expect(throws: (any Error).self) { _ = try CanonicalMessagePack.decode(CanonicalBinary.self, from: [0x91, 1]) }
        #expect(throws: CanonicalMessagePackError.truncated) { _ = try CanonicalMessagePack.decode(CanonicalBinary.self, from: [0xc4, 3, 1]) }
    }
}

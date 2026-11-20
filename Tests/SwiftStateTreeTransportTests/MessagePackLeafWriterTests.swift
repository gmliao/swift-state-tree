// Tests/SwiftStateTreeTransportTests/MessagePackLeafWriterTests.swift
//
// #690: the positional MessagePack writer builds a leaf's value from the calls of the public
// `_PayloadWireLeaf._writeWire(into:)`. A leaf that writes a malformed value used to trap
// (an index out of range, `preconditionFailure`, `precondition`); it now fails the encode.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A leaf that writes one kind of malformed value, or a well-formed nested object.
private struct ScriptedLeaf: _PayloadWireLeaf, Codable, Sendable, Equatable {
    enum Script: String, Codable, CaseIterable, Sendable {
        case keyOutsideObject, valueWithoutKey, objectWithoutKey, twoValues, twoKeys, sameKeyTwice,
             negativeCount
    }

    /// An object with fewer entries than its count, which threw before #690 too.
    var incomplete = false

    var script: Script?

    func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        if incomplete {
            writer.object(count: 2)
            writer.key("a")
            writer.int(1)
            return
        }
        switch script {
        case .keyOutsideObject:
            writer.key("a")
            writer.int(1)
        case .valueWithoutKey:
            writer.object(count: 1)
            writer.int(1)
        case .objectWithoutKey:
            writer.object(count: 1)
            writer.object(count: 1)
        case .twoValues:
            writer.int(1)
            writer.int(2)
        case .twoKeys:
            writer.object(count: 1)
            writer.key("a")
            writer.key("b")
            writer.int(1)
        case .sameKeyTwice:
            writer.object(count: 2)
            writer.key("a")
            writer.int(1)
            writer.key("a")
            writer.int(2)
        case .negativeCount:
            writer.object(count: -1)
        case nil:
            // {"a": 1, "b": {"c": true}}
            writer.object(count: 2)
            writer.key("a")
            writer.int(1)
            writer.key("b")
            writer.object(count: 1)
            writer.key("c")
            writer.bool(true)
        }
    }
}

extension ScriptedLeaf.Script {
    /// The part of the violation's description that names this script's malformed call.
    var violation: String {
        switch self {
        case .keyOutsideObject: "outside an object"
        case .valueWithoutKey, .objectWithoutKey: "value without its key"
        case .twoValues: "more than one value"
        case .twoKeys: "before the previous key's value"
        case .sameKeyTwice: "twice in one object"
        case .negativeCount: "negative count"
        }
    }
}

@Payload
private struct ScriptedLeafEvent: ServerEventPayload {
    let leaf: ScriptedLeaf
}

private func writeLeaf(_ script: ScriptedLeaf.Script?) throws -> [MessagePackValue] {
    var writer = MessagePackPayloadFieldWriter()
    try writer.leaf(ScriptedLeaf(script: script))
    return writer.fields
}

@Suite("MessagePack: a leaf that writes a malformed value fails the encode, never the process (#690)")
struct MessagePackLeafWriterTests {
    // Exit codes of the child: 0 pass; 10 + n the n-th script wrote a value; 30 + n it threw
    // something other than an encoding error naming the script's own violation.
    @Test("each malformed leaf throws in the encode (exit test)")
    func malformedLeafThrows() async {
        await #expect(processExitsWith: .success) {
            for (index, script) in ScriptedLeaf.Script.allCases.enumerated() {
                let n = Int32(index + 1)
                do {
                    _ = try writeLeaf(script)
                    exit(10 + n)
                } catch let EncodingError.invalidValue(_, context) {
                    if !context.debugDescription.contains(script.violation) { exit(30 + n) }
                } catch {
                    exit(30 + n)
                }
                do {
                    _ = try MessagePackPayloadFieldWriter.positional(ScriptedLeafEvent(leaf: ScriptedLeaf(script: script)))
                    exit(10 + n)
                } catch is EncodingError {
                } catch {
                    exit(30 + n)
                }
            }
            exit(0)
        }
    }

    @Test("a well-formed nested leaf is written as before")
    func wellFormedLeaf() throws {
        let expected = MessagePackValue.map([
            .string("a"): .int(1),
            .string("b"): .map([.string("c"): .bool(true)]),
        ])
        #expect(try writeLeaf(nil) == [expected])
        #expect(try MessagePackPayloadFieldWriter.positional(ScriptedLeafEvent(leaf: ScriptedLeaf(script: nil))) == .array([expected]))
    }

    @Test("an object with fewer entries than its count is refused as incomplete")
    func incompleteObject() {
        var writer = MessagePackPayloadFieldWriter()
        let error = #expect(throws: EncodingError.self) { try writer.leaf(ScriptedLeaf(incomplete: true)) }
        guard case let .invalidValue(_, context)? = error else { return }
        #expect(context.debugDescription == "a leaf wrote an incomplete value")
    }
}

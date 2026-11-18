// Tests/SwiftStateTreeTests/PayloadNestingTests.swift
//
// The nesting limit of a client's data (#362): JSON is refused past it before it is parsed, and
// every payload is checked again before its re-encode, whatever its source.

import Foundation
import Testing
@testable import SwiftStateTree

/// `levels` nested arrays as JSON text, `[]` at the bottom.
private func nestedArrays(_ levels: Int) -> String {
    String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
}

/// `levels` nested arrays as an `AnyCodable` base, built without recursion.
private func nestedValue(_ levels: Int) -> Any {
    var value: Any = [Any]()
    for _ in 1..<max(1, levels) { value = [value] }
    return value
}

private struct Payload: Decodable {
    let a: AnyCodable
}

@Suite("Payload nesting limit (#362)")
struct PayloadNestingTests {
    let limit = PayloadNesting.clientFrameMaxDepth

    @Test("checkJSON takes the limit and refuses one past it, in arrays and in objects")
    func jsonAtTheLimit() throws {
        try PayloadNesting.checkJSON(Data(nestedArrays(limit).utf8))
        #expect(throws: PayloadNesting.TooDeep.self) { try PayloadNesting.checkJSON(Data(nestedArrays(limit + 1).utf8)) }
        let objects = { (levels: Int) in
            String(repeating: "{\"a\":", count: levels - 1) + "{}" + String(repeating: "}", count: levels - 1)
        }
        try PayloadNesting.checkJSON(Data(objects(limit).utf8))
        #expect(throws: PayloadNesting.TooDeep.self) { try PayloadNesting.checkJSON(Data(objects(limit + 1).utf8)) }
    }

    @Test("Brackets inside strings don't count, escaped quotes included")
    func jsonStringsDontCount() throws {
        let deepText = nestedArrays(limit + 10)
        // A string holding brackets, an escaped quote and an escaped backslash before its end.
        let frame = "[\"\(deepText)\\\"\(deepText)\\\\\", {\"k\": \"{{{{\"}]"
        #expect(throws: Never.self) { try PayloadNesting.checkJSON(Data(frame.utf8)) }
        // The same brackets outside a string do count.
        #expect(throws: PayloadNesting.TooDeep.self) { try PayloadNesting.checkJSON(Data("[\(deepText)]".utf8)) }
    }

    @Test("check takes a value at the limit and refuses one past it; dictionaries count as levels")
    func valueAtTheLimit() throws {
        try PayloadNesting.check(nestedValue(limit))
        #expect(throws: PayloadNesting.TooDeep.self) { try PayloadNesting.check(nestedValue(limit + 1)) }
        var dictionary: Any = [String: Any]()
        for _ in 1..<(limit + 1) { dictionary = ["k": dictionary] }
        #expect(throws: PayloadNesting.TooDeep.self) { try PayloadNesting.check(dictionary) }
        try PayloadNesting.check(["a": 1, "b": [true, "x"]] as [String: Any])
        try PayloadNesting.check(42)
    }

    @Test("A replayed payload deeper than the limit throws from the payload decode, at Foundation's depth and beyond, on the cooperative pool")
    func replayedPayloadRefused() async throws {
        for levels in [limit + 1, 512, 600] {
            let payload = AnyCodable(["a": nestedValue(levels - 1)] as [String: Any])
            let outcome = await Task.detached { () -> String in
                do {
                    _ = try InboundPayloadDecoding.decode(Payload.self, from: payload, decoder: JSONDecoder())
                    return "decoded"
                } catch let error as PayloadNesting.TooDeep {
                    return "\(error)"
                } catch {
                    return "other: \(error)"
                }
            }.value
            #expect(outcome == "Nesting deeper than \(limit)", "\(levels) levels")
        }
        // At the limit it decodes.
        let payload = AnyCodable(["a": nestedValue(limit - 1)] as [String: Any])
        _ = try InboundPayloadDecoding.decode(Payload.self, from: payload, decoder: JSONDecoder())
    }

    @Test("A 2.x JSON record nested deeper than a 3.x record can is refused before it is parsed")
    func deepJSONRecordRefused() {
        let levels = CanonicalMessagePack.maxDepth + 1
        let record = "{\"recordMetadata\": \(nestedArrays(levels - 1))}"
        #expect(throws: PayloadNesting.TooDeep.self) {
            _ = try JSONReevaluationSource(data: Data(record.utf8))
        }
    }
}

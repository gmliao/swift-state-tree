// Tests/SwiftStateTreeTests/IdentifierWireShapeTests.swift
//
// PlayerID, ClientID and SessionID are strings on the wire (#154): Codable encodes each as a
// single string, decodes only a string, and a dictionary keyed by one is an object keyed by
// that string, the same shape SnapshotValue gives state.

import Foundation
import Testing
@testable import SwiftStateTree

private struct IdentifierPayload: Codable, Equatable {
    let player: PlayerID
    let client: ClientID
    let session: SessionID
    let players: [PlayerID]
    let byPlayer: [PlayerID: Int]
    let byClient: [ClientID: Int]
    let bySession: [SessionID: Int]
}

private let payload = IdentifierPayload(
    player: PlayerID("p1"), client: ClientID("c1"), session: SessionID("s1"),
    players: [PlayerID("p2")],
    byPlayer: [PlayerID("p3"): 1], byClient: [ClientID("c3"): 2], bySession: [SessionID("s3"): 3]
)

private let expectedJSON =
    #"{"byClient":{"c3":2},"byPlayer":{"p3":1},"bySession":{"s3":3},"client":"c1","player":"p1","players":["p2"],"session":"s1"}"#

private func sortedJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite("Identifier wire shape (#154)")
struct IdentifierWireShapeTests {

    @Test("Identifiers encode as strings and identifier-keyed dictionaries as objects")
    func encodesAsStrings() throws {
        #expect(try sortedJSON(payload) == expectedJSON)
        #expect(try sortedJSON(PlayerID("p1")) == #""p1""#)
    }

    @Test("The string form decodes")
    func decodesStrings() throws {
        let decoded = try JSONDecoder().decode(IdentifierPayload.self, from: Data(expectedJSON.utf8))
        #expect(decoded == payload)
    }

    @Test("The old {rawValue} object form is rejected")
    func rejectsRawValueObjects() {
        for json in [#"{"rawValue":"p1"}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(PlayerID.self, from: Data(json.utf8)) }
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClientID.self, from: Data(json.utf8)) }
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(SessionID.self, from: Data(json.utf8)) }
        }
        // The old key/value array form of an identifier-keyed dictionary
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([PlayerID: Int].self, from: Data(#"[{"rawValue":"p3"},1]"#.utf8))
        }
    }

    @Test("SnapshotValue and Codable give the same shape")
    func snapshotValueMatchesCodable() throws {
        let snapshot = try SnapshotValue.make(from: payload)
        let snapshotJSON = try sortedJSON(snapshot)
        #expect(snapshotJSON == expectedJSON)
    }
}

@Suite("Identifier schema (#154)")
struct IdentifierSchemaTests {

    @Test("SchemaGen describes PlayerID, ClientID and SessionID as strings under their own defs")
    func identifierDefsAreStrings() {
        for type in [PlayerID.self, ClientID.self, SessionID.self] as [Any.Type] {
            var definitions: [String: JSONSchema] = [:]
            var visited: Set<String> = []
            let schema = TypeToSchemaConverter.convert(type, definitions: &definitions, visitedTypes: &visited)
            let name = String(describing: type)
            #expect(schema.ref == "#/defs/\(name)")
            #expect(definitions[name]?.type == .string, "\(name)")
            #expect(definitions[name]?.properties == nil, "\(name)")
        }
    }
}

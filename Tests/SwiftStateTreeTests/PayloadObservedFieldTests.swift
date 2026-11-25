// Tests/SwiftStateTreeTests/PayloadObservedFieldTests.swift
//
// #837: a property with only observers (`willSet`/`didSet`) has storage, so `@Payload` lists it
// as a field, as the PlainData witness already checks it. Before, `@Payload` skipped every
// property with an accessor block, so an observed field was checked but never written.

import Foundation
import Testing
@testable import SwiftStateTree

@Payload
struct ObservedFieldEvent: ServerEventPayload {
    var hp: Int = 0 {
        didSet {}
    }
    let name: String
    var shown: Int { hp * 2 }
}

@Suite("@Payload treats an observed property as a field (#837)")
struct PayloadObservedFieldTests {
    @Test("The field metadata, the positional writer's forms and the Codable round trip include the observed field; a computed one stays out")
    func observedFieldIsAField() throws {
        #expect(ObservedFieldEvent.getFieldMetadata().map(\.name).sorted() == ["hp", "name"])
        #expect(ObservedFieldEvent._payloadFieldForms.map(\.name).sorted() == ["hp", "name"])
        let event = ObservedFieldEvent(hp: 7, name: "a")
        let decoded = try JSONDecoder().decode(ObservedFieldEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded.hp == 7 && decoded.name == "a")
    }
}

// #521 PR 1b-2b: the event name checks at registration.
// - EV2: a registered server event, client event or action type whose wire name
//   (`_payloadWireName`) isn't the schema's ID for it is refused.
// - EV3: with the host's `eventHashes`, a registered server event that has no entry is refused.
// Two types under one name are #599's (`WireNameCollisionTests`).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct EventNameState: StateNodeProtocol {
    @Sync(.broadcast)
    var n: Int = 0

    public init() {}
}

@Payload
struct ENNotice: ServerEventPayload {
    let n: Int
}

@Payload
struct ENTap: ClientEventPayload {}

@Payload
struct ENAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct ENOpenAction: ActionPayload {
    typealias Response = ENAck
}

/// Renamed from `ENOldBell`; the hand-written wire name keeps the old one.
struct ENBellEvent: ServerEventPayload {
    static var _payloadWireName: String { "ENOldBell" }
}

/// A client event whose hand-written wire name isn't its schema name.
struct ENKnockEvent: ClientEventPayload {
    static var _payloadWireName: String { "ENOldKnock" }
}

/// Renamed from `ENOldDoorAction`; the hand-written wire name keeps the old schema name.
struct ENDoorAction: ActionPayload {
    typealias Response = ENAck
    static func getFieldMetadata() -> [FieldMetadata] { [] }
    static var _payloadWireName: String { "ENOldDoor" }
}

/// No `@Payload`: the runtime rule names it.
struct ENPlainEvent: ServerEventPayload {}

enum ENOuter {
    /// Nested: the schema's ID is the last component, `ENNestedMove`.
    @Payload
    struct ENNestedMoveEvent: ServerEventPayload {
        let n: Int
    }
}

@Payload
struct ENGenericEvent<T: Codable & Sendable>: ServerEventPayload {
    let value: T
}

@Payload
struct ENGenericAction<T: Codable & Sendable>: ActionPayload {
    typealias Response = ENAck
    let value: T
}

private func registrationError(
    _ definition: LandDefinition<EventNameState>,
    _ context: LandRegistrationContext = .encodingIndependent
) throws -> LandRegistrationError {
    try #require(throws: LandRegistrationError.self) {
        try definition.validateForRegistration(context: context)
    }
}

/// A land that registers the three renamed types, one of each kind.
private func renamedLand() -> LandDefinition<EventNameState> {
    Land("event-names-renamed", using: EventNameState.self) {
        ClientEvents { Register(ENKnockEvent.self) }
        ServerEvents { Register(ENBellEvent.self) }
        Rules {
            HandleAction(ENDoorAction.self) { (_: inout EventNameState, _: ENDoorAction, _: LandContext) in ENAck(ok: true) }
        }
    }
}

/// A land whose names all follow the rule.
private func passingLand() -> LandDefinition<EventNameState> {
    Land("event-names-ok", using: EventNameState.self) {
        ClientEvents { Register(ENTap.self) }
        ServerEvents {
            Register(ENNotice.self)
            Register(ENPlainEvent.self)
            Register(ENOuter.ENNestedMoveEvent.self)
            Register(ENGenericEvent<Int>.self)
        }
        Rules {
            HandleAction(ENOpenAction.self) { (_: inout EventNameState, _: ENOpenAction, _: LandContext) in ENAck(ok: true) }
            HandleAction(ENGenericAction<Int>.self) { (_: inout EventNameState, _: ENGenericAction<Int>, _: LandContext) in ENAck(ok: true) }
        }
    }
}

/// Registers `ENNotice` and `ENPlainEvent`.
private func twoEventLand(_ id: String = "event-hashes") -> LandDefinition<EventNameState> {
    Land(id, using: EventNameState.self) {
        ServerEvents {
            Register(ENNotice.self)
            Register(ENPlainEvent.self)
        }
        Rules {}
    }
}

@Suite("Land registration: event names (#521 PR 1b-2b, EV2 and EV3)")
struct EventNameRegistrationTests {
    @Test("EV2: a server event, a client event and an action whose wire name keeps an old name are refused, each with both names")
    func keptOldNamesAreRefused() throws {
        let error = try registrationError(renamedLand())
        #expect(error.wireNameMismatches.count == 3, "\(error.wireNameMismatches)")
        let byKind = Dictionary(grouping: error.wireNameMismatches) { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        let server = try #require(byKind["server event"]?.first)
        #expect(server.contains("ENBellEvent") && server.contains("wire name ENOldBell") && server.contains("schema name ENBell"), "\(server)")
        let client = try #require(byKind["client event"]?.first)
        #expect(client.contains("ENKnockEvent") && client.contains("wire name ENOldKnock") && client.contains("schema name ENKnock"), "\(client)")
        let action = try #require(error.wireNameMismatches.first { $0.hasPrefix("action ") })
        #expect(action.contains("ENDoorAction") && action.contains("wire name ENOldDoor") && action.contains("schema name ENDoor"), "\(action)")
        #expect(error.description.contains("regenerate the schema and the clients"))
    }

    @Test("EV2: every context runs it, the encoding-independent one included")
    func everyContextRunsIt() throws {
        for context in [
            LandRegistrationContext.encodingIndependent,
            LandRegistrationContext(payloadsCompressed: false),
            LandRegistrationContext(recordsForReplay: true),
        ] {
            #expect(try registrationError(renamedLand(), context).wireNameMismatches.count == 3)
        }
    }

    @Test("EV2: names that follow the rule pass: @Payload, the runtime rule, a nested payload, a generic event and a generic action")
    func ruleNamesPass() throws {
        let land = passingLand()
        try land.validateForRegistration(context: .encodingIndependent)
        #expect(land.wireNameMismatches().isEmpty)
        #expect(ENOuter.ENNestedMoveEvent._payloadWireName == "ENNestedMove")
    }

    @Test("EV2: schema extraction and the replay engine refuse the land before reading anything")
    func extractionAndEngineRefuse() async throws {
        #expect(throws: LandRegistrationError.self) { _ = try SchemaExtractor.extract(from: renamedLand()) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("event-names-\(UUID().uuidString).sstr").path
        let error = await #expect(throws: LandRegistrationError.self) {
            _ = try await ReevaluationEngine.run(definition: renamedLand(), initialState: EventNameState(), recordFilePath: missing)
        }
        #expect(error?.wireNameMismatches.count == 3, "the definition is refused before the file is opened")
    }

    @Test("EV3: a registered server event without an entry in eventHashes is refused, by name and type")
    func missingHashIsRefused() throws {
        let error = try registrationError(twoEventLand(), LandRegistrationContext(eventHashes: ["ENNotice": 1]))
        #expect(error.serverEventsWithoutHash.count == 1)
        let line = try #require(error.serverEventsWithoutHash.first)
        #expect(line.hasPrefix("ENPlain (") && line.contains("ENPlainEvent"), "\(line)")
        #expect(error.description.contains("eventHashes has no entry"))
    }

    @Test("EV3 passes with no table, the schema's own table, a table with extra names, and a complete table with other opcodes")
    func tablesThatPass() throws {
        let land = twoEventLand()
        try land.validateForRegistration(context: LandRegistrationContext(eventHashes: nil))
        let schema = try #require(try SchemaExtractor.extract(from: land).lands[land.id]?.eventHashes)
        try land.validateForRegistration(context: LandRegistrationContext(eventHashes: schema))
        try land.validateForRegistration(context: LandRegistrationContext(eventHashes: ["ENNotice": 1, "ENPlain": 2, "Other": 3]))
        // The limit: EV3 reads the keys, not the opcodes.
        try land.validateForRegistration(context: LandRegistrationContext(eventHashes: ["ENNotice": 9, "ENPlain": 7]))
    }

    @Test("With recording on and only EV2 and EV3 failing, both are reported, and the fingerprint isn't computed in their place")
    func fingerprintGateKeepsBothRows() throws {
        let land = Land("event-names-gate", using: EventNameState.self) {
            ServerEvents {
                Register(ENBellEvent.self)
                Register(ENNotice.self)
            }
            Rules {}
        }
        let error = try registrationError(land, LandRegistrationContext(recordsForReplay: true, eventHashes: ["ENBell": 1]))
        #expect(error.wireNameMismatches.count == 1)
        #expect(error.serverEventsWithoutHash.map { $0.hasPrefix("ENNotice (") } == [true])
        #expect(error.schemaFingerprint == nil)
        #expect(error.payload == nil && error.sync == nil && error.duplicateHandlers.isEmpty)
        #expect(!land.schemaFingerprintCache.isComputedForTesting)
    }

    @Test("With recording on and only EV3 failing, the fingerprint isn't computed; with the table complete, it is")
    func fingerprintGateWaitsForEV3() throws {
        let land = twoEventLand("event-names-gate-ev3")
        let error = try registrationError(land, LandRegistrationContext(recordsForReplay: true, eventHashes: ["ENNotice": 1]))
        #expect(error.serverEventsWithoutHash.count == 1)
        #expect(error.wireNameMismatches.isEmpty)
        #expect(!land.schemaFingerprintCache.isComputedForTesting, "EV3 failing skips the fingerprint")
        try land.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true, eventHashes: ["ENNotice": 1, "ENPlain": 2]))
        #expect(land.schemaFingerprintCache.isComputedForTesting, "with every row holding it is computed")
    }

    @Test("With recording on and only EV2 failing, the fingerprint isn't attempted, and the error is the outer one")
    func fingerprintGateWaitsForEV2() throws {
        let land = Land("event-names-gate-ev2", using: EventNameState.self) {
            ServerEvents { Register(ENBellEvent.self) }
            Rules {}
        }
        let error = try registrationError(land, LandRegistrationContext(recordsForReplay: true))
        #expect(error.wireNameMismatches.count == 1, "\(error)")
        #expect(error.schemaFingerprint == nil, "\(error)")
        // The fingerprint's extraction would rerun EV2 and fail inside it; the cache keeps that failure too.
        #expect(!land.schemaFingerprintCache.isComputedForTesting, "EV2 failing skips the fingerprint")
    }

    @Test("One throw: an EV1 type (compressed), an EV2 type, an event without a hash and a #599 shared name")
    func allRowsInOneThrow() throws {
        let land = Land("event-names-all", using: EventNameState.self) {
            ServerEvents {
                Register(ENBellEvent.self)   // EV1 (no @Payload) and EV2
                Register(ENNotice.self)      // no hash
                Register(WNShout.self)       // #599 with WNShoutEvent
                Register(WNShoutEvent.self)
            }
            Rules {}
        }
        let error = try registrationError(
            land, LandRegistrationContext(payloadsCompressed: true, eventHashes: ["ENBell": 1, "WNShout": 2])
        )
        #expect(error.payload?.typesWithoutWriter.contains { $0.contains("ENBellEvent") } == true)
        #expect(error.wireNameMismatches.count == 1)
        #expect(error.serverEventsWithoutHash.contains { $0.hasPrefix("ENNotice (") })
        #expect(error.duplicateHandlers.contains { $0.wireName == "WNShout" })
    }
}

// #521 EV2 and EV3 through `LandManager`: a manager with `eventHashes` refuses a land type that
// registers a server event without an entry, at its first create, and builds nothing; so does any
// manager for a land whose event's wire name isn't the schema's. A manager with the schema's own
// table, or with none, creates it.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

private func hashedLand(_ landType: String) -> LandDefinition<RegistrationTestState> {
    Land(landType, using: RegistrationTestState.self) {
        ServerEvents { Register(RTTypedNotice.self) }
        Rules {}
    }
}

/// Renamed from `EHTOldChime`; the hand-written wire name keeps the old one.
@PlainData
struct EHTChimeEvent: ServerEventPayload {
    static var _payloadWireName: String { "EHTOldChime" }
}

private func renamedLand(_ landType: String) -> LandDefinition<RegistrationTestState> {
    Land(landType, using: RegistrationTestState.self) {
        ServerEvents { Register(EHTChimeEvent.self) }
        Rules {}
    }
}

private func makeManager(
    eventHashes: [String: Int]?,
    encoding: TransportEncodingConfig = .messagepack,
    land: @escaping @Sendable (String) -> LandDefinition<RegistrationTestState> = hashedLand
) -> LandManager<RegistrationTestState> {
    LandManager<RegistrationTestState>(
        landFactory: { land($0.landType) },
        initialStateFactory: { _ in RegistrationTestState() },
        transportEncoding: encoding,
        eventHashes: eventHashes
    )
}

private func create(
    _ manager: LandManager<RegistrationTestState>,
    _ landID: LandID,
    _ land: (String) -> LandDefinition<RegistrationTestState> = hashedLand
) async throws {
    _ = try await manager.getOrCreateLand(
        landID: landID, definition: land(landID.landType), initialState: RegistrationTestState(), metadata: [:]
    )
}

@Suite("Land registration through LandManager: eventHashes (#521 EV3)")
struct LandRegistrationEventHashTests {
    @Test("A manager whose table lacks a registered event refuses the land type and creates nothing")
    func missingHashRefuses() async throws {
        let manager = makeManager(eventHashes: ["SomethingElse": 1])
        let landID = LandID(landType: "eh-missing", instanceId: "a")
        let error = await #expect(throws: LandRegistrationError.self) { try await create(manager, landID) }
        #expect(error?.serverEventsWithoutHash.map { $0.hasPrefix("RTTypedNotice (") } == [true], "\(String(describing: error))")
        #expect(await manager.listLands().isEmpty)
    }

    @Test("A manager with the schema's own table, or with none, creates the land", arguments: [true, false])
    func schemaTableOrNoneCreates(withTable: Bool) async throws {
        let table = withTable ? try SchemaExtractor.extract(from: hashedLand("eh-ok")).lands["eh-ok"]?.eventHashes : nil
        #expect(!withTable || table?["RTTypedNotice"] != nil)
        let manager = makeManager(eventHashes: table)
        let landID = LandID(landType: "eh-ok", instanceId: "a")
        try await create(manager, landID)
        #expect(await manager.listLands() == [landID])
    }

    @Test("Any manager refuses a land whose server event's wire name isn't the schema's (EV2), and creates nothing")
    func wireNameMismatchRefuses() async throws {
        let manager = makeManager(eventHashes: nil, encoding: .json, land: renamedLand)
        let landID = LandID(landType: "eh-renamed", instanceId: "a")
        let error = await #expect(throws: LandRegistrationError.self) { try await create(manager, landID, renamedLand) }
        #expect(error?.wireNameMismatches.count == 1, "\(String(describing: error))")
        #expect(await manager.listLands().isEmpty)
    }
}

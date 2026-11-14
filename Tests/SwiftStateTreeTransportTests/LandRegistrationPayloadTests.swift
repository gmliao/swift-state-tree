// EV1 (#521): a land whose server-written payloads (its server events, each action's response)
// have no positional writer is refused where payloads are compressed, before any land is built,
// instead of failing at the first send.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct RegistrationTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
}

/// Conforms by hand, with no `@Payload`.
struct RTHandWrittenResponse: ResponsePayload {
    let ok: Bool
    static func getFieldMetadata() -> [FieldMetadata] { [] }
}

/// Conforms by hand, with no `@Payload` and no `getResponseType()`: `HandleAction` must not call
/// the trapping default.
struct RTHandWrittenAction: ActionPayload {
    typealias Response = RTHandWrittenResponse
    let n: Int
    static func getFieldMetadata() -> [FieldMetadata] { [] }
}

@Payload
struct RTTypedNotice: ServerEventPayload {
    let value: Int
}

@Payload
struct RTTypedResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct RTTypedAction: ActionPayload {
    typealias Response = RTTypedResponse
    let n: Int
}

/// Server event `PWHandWrittenEvent` and action response `RTHandWrittenResponse` have no writer.
private func refusedLand(_ landType: String) -> LandDefinition<RegistrationTestState> {
    Land(landType, using: RegistrationTestState.self) {
        ServerEvents { Register(PWHandWrittenEvent.self) }
        Rules {
            HandleAction(RTHandWrittenAction.self) { (_: inout RegistrationTestState, _: RTHandWrittenAction, _: LandContext) in
                RTHandWrittenResponse(ok: true)
            }
        }
    }
}

private func cleanLand(_ landType: String) -> LandDefinition<RegistrationTestState> {
    Land(landType, using: RegistrationTestState.self) {
        ServerEvents { Register(RTTypedNotice.self) }
        Rules {
            HandleAction(RTTypedAction.self) { (_: inout RegistrationTestState, _: RTTypedAction, _: LandContext) in
                RTTypedResponse(ok: true)
            }
        }
    }
}

private func makeManager(
    _ factory: @escaping @Sendable (LandID) -> LandDefinition<RegistrationTestState>,
    encoding: TransportEncodingConfig = .messagepack
) -> LandManager<RegistrationTestState> {
    LandManager<RegistrationTestState>(
        landFactory: factory,
        initialStateFactory: { _ in RegistrationTestState() },
        transportEncoding: encoding
    )
}

private func create(
    _ manager: LandManager<RegistrationTestState>,
    _ landID: LandID,
    _ definition: LandDefinition<RegistrationTestState>
) async throws -> LandContainer<RegistrationTestState> {
    try await manager.getOrCreateLand(
        landID: landID, definition: definition, initialState: RegistrationTestState(), metadata: [:]
    )
}

@Suite("Land registration: payload writers (#521 EV1)")
struct LandRegistrationPayloadTests {
    @Test("A land with payloads without a writer is refused where payloads are compressed, naming each")
    func refusedWhenCompressed() throws {
        let land = refusedLand("rt-refused")
        let error = try #require(throws: LandRegistrationError.self) {
            try land.validateForRegistration(context: LandRegistrationContext(payloadsCompressed: true))
        }
        #expect(error.landType == "rt-refused")
        let types = try #require(error.payload).typesWithoutWriter
        #expect(types.count == 2)
        #expect(types.contains { $0.contains("PWHandWrittenEvent") })
        #expect(types.contains { $0.contains("RTHandWrittenResponse") && $0.contains("RTHandWrittenAction") })
        #expect(error.description.contains("add @Payload"))
    }

    @Test("The same land passes uncompressed and encoding-independent checks")
    func passesUncompressed() throws {
        let land = refusedLand("rt-refused")
        try land.validateForRegistration(context: LandRegistrationContext(payloadsCompressed: false))
        try land.validateForRegistration(context: .encodingIndependent)
    }

    @Test("A land whose payloads all use @Payload passes compressed")
    func cleanPasses() throws {
        try cleanLand("rt-clean").validateForRegistration(context: LandRegistrationContext(payloadsCompressed: true))
    }

    @Test("HandleAction reads an action's response from its associated type, not getResponseType()")
    func handleActionWithoutPayloadMacro() {
        let land = refusedLand("rt-refused")
        let handler = land.actionHandlers.first { $0.getActionType() == RTHandWrittenAction.self }
        #expect(handler?.getResponseType() == RTHandWrittenResponse.self)
    }

    @Test("createLand refuses a type once, rethrows on every create, and builds nothing")
    func createLandRefusesAndCaches() async throws {
        let manager = makeManager { refusedLand($0.landType) }
        for instance in ["a", "b"] {
            let landID = LandID(landType: "rt-refused", instanceId: instance)
            await #expect(throws: LandRegistrationError.self) {
                _ = try await create(manager, landID, refusedLand(landID.landType))
            }
        }
        #expect(await manager.registrationValidations == 1)
        #expect(await manager.listLands().isEmpty)
    }

    @Test("A clean type is validated once, even with a second create running while the first is held")
    func createLandValidatesOnceAcrossInterleavedCreates() async throws {
        let manager = makeManager { cleanLand($0.landType) }
        let gate = TestGate()
        let first = LandID(landType: "rt-clean", instanceId: "a")
        let second = LandID(landType: "rt-clean", instanceId: "b")
        // Hold only the first create at `.creation`, after its registration check.
        let holds = HoldOnce(gate: gate)
        await manager.installHolds(HoldRegistry.at(.creation) { await holds.arrive() })

        let firstCall = Task { try await create(manager, first, cleanLand(first.landType)) }
        #expect(await gate.waitForArrivals(1))
        let secondContainer = try await create(manager, second, cleanLand(second.landType))
        gate.open()
        let firstContainer = try await firstCall.value

        #expect(await manager.registrationValidations == 1)
        #expect(Set(await manager.listLands()) == [first, second])
        #expect(ObjectIdentifier(firstContainer.keeper) != ObjectIdentifier(secondContainer.keeper))
    }

    @Test("Two managers with the same land type and different definitions each get their own verdict")
    func verdictIsPerManager() async throws {
        let refusing = makeManager { refusedLand($0.landType) }
        let accepting = makeManager { cleanLand($0.landType) }
        let landID = LandID(landType: "rt-shared", instanceId: "a")
        await #expect(throws: LandRegistrationError.self) {
            _ = try await create(refusing, landID, refusedLand(landID.landType))
        }
        _ = try await create(accepting, landID, cleanLand(landID.landType))
        #expect(await accepting.listLands() == [landID])
    }

    @Test("An uncompressed manager creates the land")
    func uncompressedManagerCreates() async throws {
        let manager = makeManager({ refusedLand($0.landType) }, encoding: .json)
        let landID = LandID(landType: "rt-refused", instanceId: "a")
        _ = try await create(manager, landID, refusedLand(landID.landType))
        #expect(await manager.listLands() == [landID])
    }
}

/// Holds the first arrival at the gate; later arrivals pass.
private final class HoldOnce: @unchecked Sendable {
    private let gate: TestGate
    private let lock = NSLock()
    private var arrived = false

    init(gate: TestGate) { self.gate = gate }

    func arrive() async {
        let isFirst = lock.withLock { () -> Bool in
            defer { arrived = true }
            return !arrived
        }
        if isFirst { await gate.arrive() }
    }
}

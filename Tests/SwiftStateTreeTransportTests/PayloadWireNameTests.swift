// `@Payload`'s static members (#521): the wire name it fixes at expansion is the name the schema
// and the runtime rule give the type, and its field forms say which fields have a typed form.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

@Payload
struct WNPlayerShotEvent: ServerEventPayload {
    let a: Int
    let b: [Int]
    let c: Position2
    let d: Decimal
}

@Payload
struct WNPing: ServerEventPayload {
    let n: Int
}

@Payload
struct WNOpenDoorResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct WNOpenDoorAction: ActionPayload {
    typealias Response = WNOpenDoorResponse
    let door: String
}

/// A payload with its own generic parameter named `W`: the macro's writer parameter must not
/// shadow it (#559).
@Payload
struct WNGenericEvent<W: Codable & Sendable>: ServerEventPayload {
    let w: W
}

struct WNBox<T> {
    /// Inside a generic type: the macro fixes no name, so the runtime rule applies.
    @Payload
    struct InnerEvent: ServerEventPayload {
        let n: Int
    }
}

@Suite("Payload: wire names and field forms (#521)")
struct PayloadWireNameTests {
    @Test("The name fixed at expansion is the schema's name for the type")
    func namesMatchTheRule() {
        #expect(WNPlayerShotEvent._payloadWireName == "WNPlayerShot")
        #expect(WNPlayerShotEvent._payloadWireName == payloadEventName(for: WNPlayerShotEvent.self))
        #expect(WNPing._payloadWireName == "WNPing")
        #expect(WNOpenDoorAction._payloadWireName == "WNOpenDoor")
        #expect(WNOpenDoorAction._payloadWireName == payloadActionName(for: WNOpenDoorAction.self))
        #expect(WNBox<Int>.InnerEvent._payloadWireName == payloadEventName(for: WNBox<Int>.InnerEvent.self))
        #expect(AnyServerEvent(WNPlayerShotEvent(a: 1, b: [], c: Position2(x: 0, y: 0), d: 1)).type == "WNPlayerShot")
    }

    @Test("A payload with a generic parameter named W writes its field through Codable")
    func genericParameterNamedW() throws {
        #expect(WNGenericEvent<Int>._payloadFieldForms == [_PayloadFieldFormEntry("w", .codable)])
        let message = TransportMessage.event(event: .fromServer(event: AnyServerEvent(WNGenericEvent(w: 7))))
        let data = try OpcodeTransportMessageEncoder(enablePayloadCompression: true).encode(message)
        #expect(String(decoding: data, as: UTF8.self).hasSuffix(",[7]]"))
    }

    @Test("Field forms list each field, in name order, typed or written through Codable")
    func fieldForms() {
        #expect(WNPlayerShotEvent._payloadFieldForms == [
            _PayloadFieldFormEntry("a", .typed),
            _PayloadFieldFormEntry("b", .codable),
            _PayloadFieldFormEntry("c", .typed),
            _PayloadFieldFormEntry("d", .codable),
        ])
        #expect(WNPlayerShotEvent._payloadHasTypedWriter)
    }
}

// Distinct input types that share a wire name (#599). Inputs are dispatched by name: an action by
// its type name, the name's last component or its schema name; a client event by its event name
// through the registry; a server input by its type name. Two types that meet on a name left the
// second one unreachable, with nothing said. They are refused like one type declared twice.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct WireNameState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    public init() {}
}

@Payload
struct WireNameAck: ResponsePayload {
    let total: Int
}

// `WNPingAction`'s schema name is `WNPing`, the other type's name.
@Payload
struct WNPing: ActionPayload {
    typealias Response = WireNameAck
}

@Payload
struct WNPingAction: ActionPayload {
    typealias Response = WireNameAck
}

// Schema names `WNCasePing` and `WNCASEPING`: they differ only in case, and intake matches a
// schema name case-insensitively, so `WNCASEPING` reaches both.
@Payload
struct WNCasePingAction: ActionPayload {
    typealias Response = WireNameAck
}

@Payload
struct WNCASEPINGAction: ActionPayload {
    typealias Response = WireNameAck
}

// `WNPINGACTIONAction`'s schema name is `WNPINGACTION`, which matches `WNPingAction`'s own type
// name case-insensitively: a client sending `WNPingAction` reaches both.
@Payload
struct WNPINGACTIONAction: ActionPayload {
    typealias Response = WireNameAck
}

// Two `Move` and two `Nudge` types under different enclosing types: one last component, and
// `String(describing:)` names each by it alone.
enum WNLeft {
    @Payload
    struct Move: ActionPayload {
        typealias Response = WireNameAck
    }

    struct Nudge: ServerInputPayload {}
}

enum WNRight {
    @Payload
    struct Move: ActionPayload {
        typealias Response = WireNameAck
    }

    struct Nudge: ServerInputPayload {}
}

// `WNHitEvent`'s event name is `WNHit`, the other type's name.
@Payload
struct WNHit: ClientEventPayload {}

@Payload
struct WNHitEvent: ClientEventPayload {}

@Payload
struct WNShout: ServerEventPayload {}

@Payload
struct WNShoutEvent: ServerEventPayload {}

private func registrationError(_ definition: LandDefinition<WireNameState>) throws -> LandRegistrationError {
    try #require(throws: LandRegistrationError.self) {
        try definition.validateForRegistration(context: .encodingIndependent)
    }
}

@Suite("Distinct input types that share a wire name are refused (#599)")
struct WireNameCollisionTests {
    @Test("Ping and PingAction: the second's schema name is the first's type name")
    func schemaNameMeetsTypeName() throws {
        let definition = Land("wire-ping", using: WireNameState.self) {
            Rules {
                HandleAction(WNPing.self) { (state: inout WireNameState, _: WNPing, _: LandContext) in WireNameAck(total: state.total) }
                HandleAction(WNPingAction.self) { (state: inout WireNameState, _: WNPingAction, _: LandContext) in WireNameAck(total: -1) }
            }
        }
        #expect(definition.actionHandlers.count == 1, "the first is kept")
        let duplicate = try #require(try registrationError(definition).duplicateHandlers.first)
        #expect(duplicate.kind == "action")
        #expect(duplicate.wireName == "WNPing")
        #expect(duplicate.firstTypeName?.hasSuffix(".WNPing") == true, "\(duplicate)")
        #expect(duplicate.typeName.hasSuffix(".WNPingAction"), "\(duplicate)")
        #expect(duplicate.firstSite?.hasPrefix("SwiftStateTreeTests/WireNameCollisionTests.swift:") == true)
        #expect(duplicate.firstSite != duplicate.duplicateSite)
        #expect(duplicate.description.contains("are both matched by the name WNPing"), "\(duplicate)")
    }

    @Test("Two schema names that differ only in case: intake's case-insensitive match reaches both")
    func schemaNamesDifferInCase() throws {
        let definition = Land("wire-case", using: WireNameState.self) {
            Rules {
                HandleAction(WNCasePingAction.self) { (state: inout WireNameState, _: WNCasePingAction, _: LandContext) in WireNameAck(total: state.total) }
                HandleAction(WNCASEPINGAction.self) { (state: inout WireNameState, _: WNCASEPINGAction, _: LandContext) in WireNameAck(total: -1) }
            }
        }
        let duplicate = try #require(try registrationError(definition).duplicateHandlers.first)
        #expect(duplicate.kind == "action")
        #expect(duplicate.wireName == "WNCASEPING")
        #expect(duplicate.firstTypeName?.hasSuffix(".WNCasePingAction") == true, "\(duplicate)")
        #expect(duplicate.typeName.hasSuffix(".WNCASEPINGAction"), "\(duplicate)")
    }

    @Test("The reported name is one both types are matched by: the other type's name, not a schema name it doesn't match")
    func caseInsensitiveReportsTheSharedName() throws {
        let definition = Land("wire-case-name", using: WireNameState.self) {
            Rules {
                HandleAction(WNPINGACTIONAction.self) { (state: inout WireNameState, _: WNPINGACTIONAction, _: LandContext) in WireNameAck(total: state.total) }
                HandleAction(WNPingAction.self) { (state: inout WireNameState, _: WNPingAction, _: LandContext) in WireNameAck(total: -1) }
            }
        }
        let duplicate = try #require(try registrationError(definition).duplicateHandlers.first)
        #expect(duplicate.wireName == "WNPingAction")
    }

    @Test("Two nested Move types: one last component")
    func nestedTypesShareTheirName() throws {
        let definition = Land("wire-move", using: WireNameState.self) {
            Rules {
                HandleAction(WNLeft.Move.self) { (state: inout WireNameState, _: WNLeft.Move, _: LandContext) in WireNameAck(total: state.total) }
                HandleAction(WNRight.Move.self) { (state: inout WireNameState, _: WNRight.Move, _: LandContext) in WireNameAck(total: -1) }
            }
        }
        let duplicate = try #require(try registrationError(definition).duplicateHandlers.first)
        #expect(duplicate.kind == "action")
        #expect(duplicate.wireName == "Move")
        // Named in full: `String(describing:)` would print `Move` for both.
        #expect(duplicate.firstTypeName?.hasSuffix("WNLeft.Move") == true, "\(duplicate)")
        #expect(duplicate.typeName.hasSuffix("WNRight.Move"), "\(duplicate)")
    }

    @Test("Two nested server-input types with one name are refused, not a crash")
    func serverInputsShareTheirName() throws {
        let definition = Land("wire-nudge", using: WireNameState.self) {
            Rules {
                HandleServerInput(WNLeft.Nudge.self) { (state: inout WireNameState, _: WNLeft.Nudge, _: LandContext) in state.total += 1 }
                HandleServerInput(WNRight.Nudge.self) { (state: inout WireNameState, _: WNRight.Nudge, _: LandContext) in state.total -= 1 }
            }
        }
        let duplicate = try #require(try registrationError(definition).duplicateHandlers.first)
        #expect(duplicate.kind == "server input")
        #expect(duplicate.wireName == "Nudge")
        #expect(duplicate.firstTypeName?.hasSuffix("WNLeft.Nudge") == true, "\(duplicate)")
        #expect(duplicate.typeName.hasSuffix("WNRight.Nudge"), "\(duplicate)")
    }

    @Test("Two registered client-event types with one event name, and two server-event types")
    func eventTypesShareTheirName() throws {
        let definition = Land("wire-events", using: WireNameState.self) {
            ClientEvents {
                Register(WNHit.self)
                Register(WNHitEvent.self)
            }
            ServerEvents {
                Register(WNShout.self)
                Register(WNShoutEvent.self)
            }
            Rules {
                HandleEvent(WNHit.self) { (state: inout WireNameState, _: WNHit, _: LandContext) in state.total += 1 }
                HandleEvent(WNHitEvent.self) { (state: inout WireNameState, _: WNHitEvent, _: LandContext) in state.total -= 1 }
            }
        }
        let duplicates = try registrationError(definition).duplicateHandlers
        #expect(duplicates.map(\.kind) == ["client event", "server event"])
        #expect(duplicates.map(\.wireName) == ["WNHit", "WNShout"])
        #expect(duplicates.first?.firstTypeName?.hasSuffix(".WNHit") == true)
        // Event registrations have no declaration site; the message says nothing about one.
        let message = try #require(duplicates.first).description
        #expect(!message.contains("unknown"), "\(message)")
        #expect(message.hasSuffix("are both matched by the name WNHit; give each type its own name"), "\(message)")
    }

    @Test("One type registered twice is kept once, and names that only look alike pass")
    func distinctNamesPass() throws {
        let definition = Land("wire-ok", using: WireNameState.self) {
            ClientEvents {
                Register(WNHit.self)
                Register(WNHit.self)
            }
            Rules {
                HandleAction(WNPing.self) { (state: inout WireNameState, _: WNPing, _: LandContext) in WireNameAck(total: state.total) }
                HandleAction(WNLeft.Move.self) { (state: inout WireNameState, _: WNLeft.Move, _: LandContext) in WireNameAck(total: state.total) }
                HandleEvent(WNHit.self) { (state: inout WireNameState, _: WNHit, _: LandContext) in state.total += 1 }
                HandleServerInput(WNLeft.Nudge.self) { (state: inout WireNameState, _: WNLeft.Nudge, _: LandContext) in state.total += 1 }
            }
        }
        #expect(definition.duplicateHandlers.isEmpty, "\(definition.duplicateHandlers)")
        try definition.validateForRegistration(context: .encodingIndependent)
    }

    @Test("A keeper built without registration refuses a shared wire name at initialization")
    func keeperBackstop() async throws {
        let definition = Land("wire-keeper", using: WireNameState.self) {
            Rules {
                HandleAction(WNPing.self) { (state: inout WireNameState, _: WNPing, _: LandContext) in WireNameAck(total: state.total) }
                HandleAction(WNPingAction.self) { (state: inout WireNameState, _: WNPingAction, _: LandContext) in WireNameAck(total: -1) }
            }
        }
        let keeper = LandKeeper<WireNameState>(definition: definition, initialState: WireNameState(), autoStartLoops: false)
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        }
        let registration = try #require(failure.underlying as? LandRegistrationError)
        #expect(registration.duplicateHandlers.map(\.wireName) == ["WNPing"])
    }
}

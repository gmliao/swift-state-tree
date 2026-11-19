// Tests/SwiftStateTreeTransportTests/AdapterErrorMappingTests.swift
//
// The code and message an action or a join failure is answered with (#554 X4), without an adapter.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

private struct MappingError: Error, LocalizedError, CustomStringConvertible {
    let text: String
    var errorDescription: String? { text }
    var description: String { "MappingError(\(text))" }
}

@Suite("The adapter's error mappings (#554)")
struct AdapterErrorMappingTests {
    @Test("An unregistered action names its type; any other action error is a handler error with its description")
    func actionErrors() {
        let unregistered = AdapterErrorMapping.mapActionError(LandError.actionNotRegistered, actionType: "Move")
        #expect(unregistered.code == .actionNotRegistered)
        #expect(unregistered.message == "Action not registered: Move")

        let otherLandError = AdapterErrorMapping.mapActionError(LandError.invalidActionType, actionType: "Move")
        #expect(otherLandError.code == .actionHandlerError)
        #expect(otherLandError.message == "\(LandError.invalidActionType)")

        let thrown = AdapterErrorMapping.mapActionError(MappingError(text: "boom"), actionType: "Move")
        #expect(thrown.code == .actionHandlerError)
        #expect(thrown.message == "MappingError(boom)")
    }

    @Test("A join failure whose description says full is a full room; any other is a deny with its description")
    func joinFailures() {
        let full = AdapterErrorMapping.mapJoinFailure(MappingError(text: "Land is FULL"))
        #expect(full.0 == .joinRoomFull)
        #expect(full.1 == "Room is full")

        let denied = AdapterErrorMapping.mapJoinFailure(MappingError(text: "not invited"))
        #expect(denied.0 == .joinDenied)
        #expect(denied.1 == "MappingError(not invited)")
    }
}

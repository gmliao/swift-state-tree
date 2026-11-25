// expect-error: generic struct 'Sync' requires that 'T' conform to 'PlainData'
import SwiftStateTree

// A generic node whose parameter isn't constrained to PlainData.
@StateNodeBuilder
struct Box<T: Codable & Sendable>: StateNodeProtocol {
    @Sync(.broadcast)
    var value: T? = nil

    init() {}
}

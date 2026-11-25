// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A nested user type without @PlainData, inside a dictionary: the field's check names it.
struct Card: Codable, Sendable {
    var rank: Int
}

@StateNodeBuilder
struct TableState: StateNodeProtocol {
    @Sync(.broadcast)
    var cards: [String: Card] = [:]

    init() {}
}

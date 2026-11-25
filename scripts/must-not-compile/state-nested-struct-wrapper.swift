// expect-error: generic struct 'Sync' requires that 'Card' conform to 'PlainData'
import SwiftStateTree

// The same nested type: `Sync`'s own constraint refuses it at the field.
struct Card: Codable, Sendable {
    var rank: Int
}

@StateNodeBuilder
struct TableState: StateNodeProtocol {
    @Sync(.broadcast)
    var card: Card = Card(rank: 1)

    init() {}
}

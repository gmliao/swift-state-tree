import SwiftStateTree

/// A recursive plain value for the depth tests: its `Codable` form nests one array per level, as
/// an `AnyCodable` tree of arrays did (`.leaf` is `[]`, `.node(children)` is `[children…]`), so
/// the depths a test pins are the same. A payload can't hold an `AnyCodable`, which isn't
/// `PlainData`.
@PlainData
public indirect enum Nest: Codable, Sendable, Equatable {
    case leaf
    case node([Nest])

    /// `levels` nested arrays: 1 is `[]`, 2 is `[[]]`.
    public static func nested(_ levels: Int) -> Nest {
        var value = Nest.leaf
        for _ in 1..<max(1, levels) { value = .node([value]) }
        return value
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var children: [Nest] = []
        while !container.isAtEnd { children.append(try container.decode(Nest.self)) }
        self = children.isEmpty ? .leaf : .node(children)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        if case .node(let children) = self {
            for child in children { try container.encode(child) }
        }
    }
}

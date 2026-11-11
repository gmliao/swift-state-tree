import Foundation
import SwiftStateTree

/// One encoder's canonical emit order: the land's `CanonicalPatchOrder`, and a key template per
/// schema pattern so a hashed encoder keys a patch from the split it already made.
///
/// The adapter gives every state-update encoder its land's order at registration, and the encoder
/// sorts each frame's patches by it before planning or encoding them. `flat` (one table, keys
/// compared by path components) is the order without a state type.
package struct CanonicalFrameOrder: Sendable {
    package let order: CanonicalPatchOrder
    private let templates: [UInt32: CanonicalPatchOrder.Template]

    /// - Parameter pathHashes: the schema patterns a hashed encoder splits against.
    package init(order: CanonicalPatchOrder, pathHashes: [String: UInt32]? = nil) {
        self.order = order
        var templates: [UInt32: CanonicalPatchOrder.Template] = [:]
        for (pattern, hash) in pathHashes ?? [:] {
            templates[hash] = order.template(pattern: pattern)
        }
        self.templates = templates
    }

    /// No state type: every path is a field of one root table.
    package static let flat = CanonicalFrameOrder(order: CanonicalPatchOrder(types: [.init(fields: [:])]))

    /// A patch's key: from its split's pattern when it matched one, otherwise from its path.
    package func key(_ patch: StatePatch, split: (pathHash: UInt32, dynamicKeys: [String], inSchema: Bool)?) -> CanonicalPatchOrder.Key {
        if let split, split.inSchema, let template = templates[split.pathHash],
           let key = template.key(dynamicKeys: split.dynamicKeys) {
            return key
        }
        return order.key(path: patch.path)
    }

    /// The permutation of `patches` into canonical order; `splits` (parallel to `patches`) give
    /// the keys when present.
    package func permutation(
        _ patches: [StatePatch],
        splits: [(pathHash: UInt32, dynamicKeys: [String], inSchema: Bool)]? = nil
    ) -> [Int] {
        guard patches.count > 1 else { return Array(patches.indices) }
        let keys = patches.indices.map { key(patches[$0], split: splits?[$0]) }
        return CanonicalPatchOrder.order(of: keys)
    }

    /// `patches` in canonical order.
    package func sorted(_ patches: [StatePatch]) -> [StatePatch] {
        guard patches.count > 1 else { return patches }
        return permutation(patches).map { patches[$0] }
    }
}

extension StateUpdate {
    /// The update with its patches in canonical order.
    package func canonicallyOrdered(by order: CanonicalFrameOrder) -> StateUpdate {
        switch self {
        case .noChange: return self
        case .firstSync(let patches): return .firstSync(order.sorted(patches))
        case .diff(let patches): return .diff(order.sorted(patches))
        }
    }
}

/// A state-update encoder that takes the land's canonical order (all three built-in encoders).
package protocol CanonicallyOrderedStateUpdateEncoder: StateUpdateEncoder {
    func withCanonicalOrder(_ order: CanonicalPatchOrder) -> Self
}

/// A state-update encoder that splits paths with a `PathHasher` (both opcode encoders, when the
/// land has path hashes): a diff that walks the same trie can hand it the splits
/// (`StatePatch.split`).
package protocol PathSplittingStateUpdateEncoder: StateUpdateEncoder {
    var splittingPathHasher: PathHasher? { get }
}

extension OpcodeJSONStateUpdateEncoder: PathSplittingStateUpdateEncoder {
    package var splittingPathHasher: PathHasher? { pathHasher }
}

extension OpcodeMessagePackStateUpdateEncoder: PathSplittingStateUpdateEncoder {
    package var splittingPathHasher: PathHasher? { pathHasher }
}

extension JSONStateUpdateEncoder: CanonicallyOrderedStateUpdateEncoder {}
extension OpcodeJSONStateUpdateEncoder: CanonicallyOrderedStateUpdateEncoder {}
extension OpcodeMessagePackStateUpdateEncoder: CanonicallyOrderedStateUpdateEncoder {}

/// `encoder` with `order` when it takes one; any other encoder as it is.
package func applyingCanonicalOrder(_ order: CanonicalPatchOrder, to encoder: any StateUpdateEncoder) -> any StateUpdateEncoder {
    guard let ordered = encoder as? any CanonicallyOrderedStateUpdateEncoder else { return encoder }
    return ordered.withCanonicalOrder(order)
}

import Foundation
import SwiftStateTree

/// Which state-update features a joiner declares, for the join's feature check (the adapter's
/// join and the router's).
enum StateUpdateFeatureNegotiation {
    /// The features of `required` that the join metadata's `stateUpdateFeatures` (a list of
    /// strings) doesn't declare; nil when none is missing.
    static func missingStateUpdateFeatures(required: [String], metadata: [String: AnyCodable]?) -> [String]? {
        guard !required.isEmpty else { return nil }
        let raw = metadata?[StateUpdateFeature.metadataKey]?.base
        let declared: Set<String>
        if let strings = raw as? [String] {
            declared = Set(strings)
        } else if let values = raw as? [AnyCodable] {
            declared = Set(values.compactMap { $0.base as? String })
        } else if let values = raw as? [Any] {
            declared = Set(values.compactMap { $0 as? String })
        } else {
            declared = []
        }
        let missing = required.filter { !declared.contains($0) }
        return missing.isEmpty ? nil : missing
    }

    /// The join error's message for missing state-update features.
    static func missingFeaturesMessage(_ missing: [String]) -> String {
        "unsupported state update encoding: missing \(missing.joined(separator: ", "))"
    }
}

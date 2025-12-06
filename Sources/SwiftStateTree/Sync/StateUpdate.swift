// Sources/SwiftStateTree/Sync/StateUpdate.swift

import Foundation

/// Represents a state update, either no changes, first sync signal, or a set of patches.
///
/// The `firstSync` case is used to signal to the client that the sync engine has started
/// and will begin sending diff updates. This prevents race conditions between snapshot
/// initialization and diff updates.
///
/// The `firstSync` case includes patches to handle any changes that occurred between
/// join (snapshot) and the first diff generation. This ensures no changes are lost.
///
/// See [DESIGN_SYNC_FIRSTSYNC.md](../../../DESIGN_SYNC_FIRSTSYNC.md) for detailed design documentation.
public enum StateUpdate: Equatable, Sendable, Codable {
    /// No changes detected
    case noChange
    /// First sync signal - indicates sync engine has started and will begin sending diffs
    /// This is sent once per player when their cache is first populated.
    /// Includes patches to handle any changes between join and first diff generation.
    case firstSync([StatePatch])
    /// Changes represented as patches
    case diff([StatePatch])
    
    private enum CodingKeys: String, CodingKey {
        case type
        case patches
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .noChange:
            try container.encode("noChange", forKey: .type)
        case .firstSync(let patches):
            try container.encode("firstSync", forKey: .type)
            try container.encode(patches, forKey: .patches)
        case .diff(let patches):
            try container.encode("diff", forKey: .type)
            try container.encode(patches, forKey: .patches)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "noChange":
            self = .noChange
        case "firstSync":
            let patches = try container.decode([StatePatch].self, forKey: .patches)
            self = .firstSync(patches)
        case "diff":
            let patches = try container.decode([StatePatch].self, forKey: .patches)
            self = .diff(patches)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown StateUpdate type: \(type)"
            )
        }
    }
}


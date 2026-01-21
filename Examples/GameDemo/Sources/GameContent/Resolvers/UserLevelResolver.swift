import Foundation
import SwiftStateTree

// MARK: - UserLevel ResolverOutput

/// Resolver output containing user level determined deterministically from PlayerID hash
public struct UserLevel: ResolverOutput {
    public let level: Int
    
    public init(level: Int) {
        self.level = level
    }
}

// MARK: - UserLevelResolver

/// Resolver that determines user level deterministically based on PlayerID hash
///
/// This resolver ensures that the same PlayerID always gets the same level,
/// making it deterministic for replay purposes.
public struct UserLevelResolver: ContextResolver {
    public typealias Output = UserLevel
    
    /// Determine user level from PlayerID hash
    ///
    /// Uses a simple hash-based approach to ensure determinism:
    /// - Hash the PlayerID string
    /// - Map hash value to level range (1-3)
    /// - Same PlayerID always produces same level
    public static func resolve(
        ctx: ResolverContext
    ) async throws -> UserLevel {
        // IMPORTANT:
        // Never use Swift's `hashValue` here — it is not stable across runs/platforms.
        // Use DeterministicHash to guarantee deterministic re-evaluation.
        let stable = DeterministicHash.stableInt32(ctx.playerID.rawValue)
        
        // Map to level range (1-3).
        // Use bitPattern to avoid issues with Int32.min abs overflow.
        let level = Int(UInt32(bitPattern: stable) % 3) + 1
        
        return UserLevel(level: level)
    }
}

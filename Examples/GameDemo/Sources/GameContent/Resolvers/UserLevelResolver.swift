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
        // Hash the PlayerID string for deterministic level assignment
        let hashValue = ctx.playerID.rawValue.hashValue
        
        // Map hash to level range (1-3) for turret level impact
        // Use absolute value and modulo to ensure positive level
        let level = abs(hashValue) % 3 + 1
        
        return UserLevel(level: level)
    }
}

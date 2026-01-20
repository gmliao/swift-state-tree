import Foundation
import SwiftStateTree

// MARK: - AsyncTest ResolverOutput

/// Resolver output for testing async resolver behavior
public struct AsyncTestOutput: ResolverOutput {
    public let value: String
    public let resolvedAt: Date
    
    public init(value: String, resolvedAt: Date) {
        self.value = value
        self.resolvedAt = resolvedAt
    }
}

// MARK: - AsyncTestResolver

/// Test resolver that simulates async I/O operations with configurable delay
///
/// This resolver is used to test async resolver recording and replay:
/// - In live mode: Executes with delay, records the output
/// - In replay mode: Uses recorded output directly (no delay)
///
/// Example usage:
/// ```swift
/// OnJoin(resolvers: AsyncTestResolver.self) { state, ctx in
///     if let output = ctx.asyncTestOutput {
///         // Use the resolved value
///     }
/// }
/// ```
public struct AsyncTestResolver: ContextResolver {
    public typealias Output = AsyncTestOutput
    
    /// Default delay for testing (can be overridden via environment variable)
    private static let defaultDelay: Duration = .milliseconds(50)
    
    /// Resolve with async delay to simulate I/O operations
    ///
    /// - Parameter ctx: Resolver context
    /// - Returns: AsyncTestOutput with a deterministic value based on PlayerID
    public static func resolve(
        ctx: ResolverContext
    ) async throws -> AsyncTestOutput {
        // Get delay from environment variable for testing flexibility
        let delayMs = Int(ProcessInfo.processInfo.environment["ASYNC_TEST_RESOLVER_DELAY_MS"] ?? "50") ?? 50
        let delay = Duration.milliseconds(Int64(delayMs))
        
        // Simulate async I/O operation (e.g., database query, API call)
        try await Task.sleep(for: delay)
        
        // Generate deterministic value based on PlayerID (for replay verification)
        let playerID = ctx.playerID.rawValue
        let hashValue = playerID.hashValue
        let value = "async-resolved-\(abs(hashValue) % 1000)"
        
        // Record resolution timestamp for verification
        let resolvedAt = Date()
        
        return AsyncTestOutput(value: value, resolvedAt: resolvedAt)
    }
}

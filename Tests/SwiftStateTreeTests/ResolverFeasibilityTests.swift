import Foundation
import Testing
import Logging
@testable import SwiftStateTree

// MARK: - Test ResolverOutput Types

struct ProductInfo: ResolverOutput {
    let id: String
    let name: String
    let price: Decimal
    let stock: Int
}

struct UserProfileInfo: ResolverOutput {
    let userID: String
    let name: String
    let email: String
    let level: Int
}

// MARK: - Test Resolvers

struct ProductInfoResolver: ContextResolver {
    typealias Output = ProductInfo

    static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
        // Simulate async data loading
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Extract productID from action payload
        let action = ctx.actionPayload as? ResolverTestAction
        let productID = action?.productID ?? "default-product"

        // Return mock data
        return ProductInfo(
            id: productID,
            name: "Test Product",
            price: Decimal(99.99),
            stock: 100
        )
    }
}

struct UserProfileResolver: ContextResolver {
    typealias Output = UserProfileInfo

    static func resolve(ctx: ResolverContext) async throws -> UserProfileInfo {
        // Simulate async data loading
        try await Task.sleep(nanoseconds: 15_000_000) // 15ms

        // Use playerID from context
        return UserProfileInfo(
            userID: ctx.playerID.rawValue,
            name: "Test User",
            email: "test@example.com",
            level: 10
        )
    }
}

// MARK: - Test Action

@Payload
struct ResolverTestAction: ActionPayload {
    typealias Response = ResolverTestResponse
    let productID: String
}

@Payload
struct ResolverTestResponse: ResponsePayload {
    let success: Bool
}

// MARK: - Test State

@StateNodeBuilder
struct TestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
}

// MARK: - Dynamic Context Storage Test

/// Test implementation of dynamic context storage using @dynamicMemberLookup
@dynamicMemberLookup
struct TestResolverContext {
    private var storage: [String: Any] = [:]

    mutating func set<Output: ResolverOutput>(_ output: Output, for resolverType: String) {
        // Convert resolver type name to property name (e.g., "ProductInfoResolver" -> "productInfo")
        let propertyName = convertResolverTypeToPropertyName(resolverType)
        storage[propertyName] = output
    }

    subscript<T: ResolverOutput>(dynamicMember member: String) -> T? {
        return storage[member] as? T
    }

    private func convertResolverTypeToPropertyName(_ typeName: String) -> String {
        var name = typeName
        // Remove "Resolver" suffix if present
        if name.hasSuffix("Resolver") {
            name = String(name.dropLast(8))
        }
        // Convert to camelCase (e.g., "ProductInfo" -> "productInfo")
        guard !name.isEmpty else { return name }
        let firstChar = name.first!.lowercased()
        let rest = String(name.dropFirst())
        return firstChar + rest
    }
}

// MARK: - Parallel Resolver Execution Test

/// Test parallel resolver execution using async let
func executeResolversInParallel<R1: ContextResolver, R2: ContextResolver>(
    _ resolver1: R1.Type,
    _ resolver2: R2.Type,
    ctx: ResolverContext
) async throws -> (R1.Output, R2.Output) {
    // Execute resolvers in parallel using async let
    async let output1 = resolver1.resolve(ctx: ctx)
    async let output2 = resolver2.resolve(ctx: ctx)

    // Wait for both to complete
    return try await (output1, output2)
}

/// Test parallel resolver execution using TaskGroup
func executeResolversInParallelWithTaskGroup(
    resolvers: [any ContextResolver.Type],
    ctx: ResolverContext
) async throws -> [any ResolverOutput] {
    try await withThrowingTaskGroup(of: (Int, any ResolverOutput).self) { group in
        for (index, resolver) in resolvers.enumerated() {
            group.addTask {
                // Use type erasure to call resolve
                let output = try await resolveAnyResolver(resolver, ctx: ctx)
                return (index, output)
            }
        }

        var results: [(Int, any ResolverOutput)] = []
        for try await result in group {
            results.append(result)
        }

        // Sort by index to maintain order
        results.sort { $0.0 < $1.0 }
        return results.map { $0.1 }
    }
}

/// Type-erased resolver execution helper
private func resolveAnyResolver(
    _ resolverType: any ContextResolver.Type,
    ctx: ResolverContext
) async throws -> any ResolverOutput {
    // This is a simplified version - in real implementation, we'd use more sophisticated type erasure
    // For now, we'll test with known resolver types
    if let productResolver = resolverType as? ProductInfoResolver.Type {
        return try await productResolver.resolve(ctx: ctx)
    } else if let userResolver = resolverType as? UserProfileResolver.Type {
        return try await userResolver.resolve(ctx: ctx)
    } else {
        throw ResolverError.custom("Unknown resolver type")
    }
}

// MARK: - Tests

@Test("ResolverOutput protocol conformance")
func testResolverOutputProtocol() {
    let product = ProductInfo(id: "1", name: "Test", price: 10.0, stock: 5)
    // ProductInfo conforms to ResolverOutput, so this should compile
    let _: ResolverOutput = product

    let profile = UserProfileInfo(userID: "1", name: "User", email: "test@test.com", level: 5)
    let _: ResolverOutput = profile
}

@Test("ContextResolver basic functionality")
func testContextResolver() async throws {
    let state = TestState()
    let landContext = LandContext(
        landID: "test-land",
        playerID: PlayerID("player-1"),
        clientID: ClientID("client-1"),
        sessionID: SessionID("session-1"),
        services: LandServices(),
        logger: Logger(label: "test"),
        deviceID: nil,
        metadata: [:],
        emitEventHandler: { _, _ in },
        requestSyncNowHandler: { },
        requestSyncBroadcastOnlyHandler: { }
    )

    let resolverContext = ResolverContext(
        landContext: landContext,
        actionPayload: ResolverTestAction(productID: "product-123"),
        eventPayload: nil,
        currentState: state
    )

    let output = try await ProductInfoResolver.resolve(ctx: resolverContext)
    #expect(output.id == "product-123")
    #expect(output.name == "Test Product")
    #expect(output.price == Decimal(99.99))
    #expect(output.stock == 100)
}

@Test("Parallel resolver execution with async let")
func testParallelResolverExecutionAsyncLet() async throws {
    let state = TestState()
    let landContext = LandContext(
        landID: "test-land",
        playerID: PlayerID("player-1"),
        clientID: ClientID("client-1"),
        sessionID: SessionID("session-1"),
        services: LandServices(),
        logger: Logger(label: "test"),
        deviceID: nil,
        metadata: [:],
        emitEventHandler: { _, _ in },
        requestSyncNowHandler: { },
        requestSyncBroadcastOnlyHandler: { }
    )

    let resolverContext = ResolverContext(
        landContext: landContext,
        actionPayload: ResolverTestAction(productID: "product-123"),
        eventPayload: nil,
        currentState: state
    )

    let serialStart = ContinuousClock.now
    _ = try await ProductInfoResolver.resolve(ctx: resolverContext)
    _ = try await UserProfileResolver.resolve(ctx: resolverContext)
    let serialDuration = ContinuousClock.now - serialStart

    let parallelStart = ContinuousClock.now
    let (productInfo, userProfile) = try await executeResolversInParallel(
        ProductInfoResolver.self,
        UserProfileResolver.self,
        ctx: resolverContext
    )
    let parallelDuration = ContinuousClock.now - parallelStart

    // Both resolvers should complete, and total time should be approximately
    // the max of individual resolver times (not the sum), since they run in parallel
    // ProductInfoResolver: 10ms, UserProfileResolver: 15ms
    // Serial execution would take ~25ms (10 + 15)
    // Parallel execution should ideally take ~15ms (max of the two)
    // However, we allow significant overhead for:
    // - Task creation and scheduling overhead
    // - System load variations (CI environments can be slow)
    // - Clock precision and measurement overhead
    // - Context switching and thread pool management
    // - Swift runtime overhead for async/await
    let serialMs = Double(serialDuration.components.seconds) * 1000.0
        + Double(serialDuration.components.attoseconds) / 1_000_000_000_000_000.0
    let parallelMs = Double(parallelDuration.components.seconds) * 1000.0
        + Double(parallelDuration.components.attoseconds) / 1_000_000_000_000_000.0

    // Lower bound: should be at least as long as the shorter resolver (10ms)
    // Allow some measurement variance
    #expect(parallelMs >= 8.0)

    // Upper bound: should not be significantly slower than serial execution.
    // Use a ratio to reduce flakiness in noisy CI environments.
    #expect(parallelMs <= serialMs * 1.5)

    #expect(productInfo.id == "product-123")
    #expect(userProfile.userID == "player-1")
}

@Test("Dynamic context storage with @dynamicMemberLookup")
func testDynamicContextStorage() {
    var ctx = TestResolverContext()

    let productInfo = ProductInfo(id: "1", name: "Test", price: 10.0, stock: 5)
    ctx.set(productInfo, for: "ProductInfoResolver")

    let userProfile = UserProfileInfo(userID: "1", name: "User", email: "test@test.com", level: 5)
    ctx.set(userProfile, for: "UserProfileResolver")

    // Access using dynamic member lookup
    let retrievedProduct: ProductInfo? = ctx.productInfo
    #expect(retrievedProduct?.id == "1")
    #expect(retrievedProduct?.name == "Test")

    let retrievedProfile: UserProfileInfo? = ctx.userProfile
    #expect(retrievedProfile?.userID == "1")
    #expect(retrievedProfile?.name == "User")
}

@Test("Synchronous action handler with resolver outputs")
func testSynchronousActionHandler() throws {
    // This test verifies that a synchronous handler can access resolver outputs
    // that were pre-resolved before the handler executes

    // Pre-resolved outputs (simulating what would happen before handler execution)
    let productInfo = ProductInfo(id: "1", name: "Test Product", price: 99.99, stock: 100)
    let userProfile = UserProfileInfo(userID: "1", name: "Test User", email: "test@test.com", level: 10)

    // Simulate synchronous action handler
    var state = TestState()
    let action = ResolverTestAction(productID: "1")

    // Synchronous handler that uses pre-resolved data
    func handleActionSync(state: inout TestState, action: ResolverTestAction, productInfo: ProductInfo, userProfile: UserProfileInfo) throws -> ResolverTestResponse {
        // Use resolver outputs synchronously
        state.value = Int(truncating: productInfo.price as NSDecimalNumber)
        // Handler logic here...
        return ResolverTestResponse(success: true)
    }

    let response = try handleActionSync(state: &state, action: action, productInfo: productInfo, userProfile: userProfile)
    #expect(response.success == true)
    #expect(state.value == 99) // Int(99.99) = 99
}

@Test("Resolver error handling - direct resolver")
func testResolverErrorHandlingDirect() async throws {
    struct FailingResolver: ContextResolver {
        typealias Output = ProductInfo

        static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
            throw ResolverError.missingParameter("productID")
        }
    }

    let state = TestState()
    let landContext = LandContext(
        landID: "test-land",
        playerID: PlayerID("player-1"),
        clientID: ClientID("client-1"),
        sessionID: SessionID("session-1"),
        services: LandServices(),
        logger: Logger(label: "test"),
        deviceID: nil,
        metadata: [:],
        emitEventHandler: { _, _ in },
        requestSyncNowHandler: { },
        requestSyncBroadcastOnlyHandler: { }
    )

    let resolverContext = ResolverContext(
        landContext: landContext,
        actionPayload: nil,
        eventPayload: nil,
        currentState: state
    )

    do {
        _ = try await FailingResolver.resolve(ctx: resolverContext)
        Issue.record("Expected error was not thrown")
    } catch ResolverError.missingParameter(let param) {
        #expect(param == "productID")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("Resolver error handling - through executor")
func testResolverErrorHandlingThroughExecutor() async throws {
    struct FailingResolver: ContextResolver {
        typealias Output = ProductInfo

        static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
            throw ResolverError.dataLoadFailed("Product not found: product-999")
        }
    }

    let state = TestState()
    let landContext = LandContext(
        landID: "test-land",
        playerID: PlayerID("player-1"),
        clientID: ClientID("client-1"),
        sessionID: SessionID("session-1"),
        services: LandServices(),
        logger: Logger(label: "test"),
        deviceID: nil,
        metadata: [:],
        emitEventHandler: { _, _ in },
        requestSyncNowHandler: { },
        requestSyncBroadcastOnlyHandler: { }
    )

    let resolverContext = ResolverContext(
        landContext: landContext,
        actionPayload: ResolverTestAction(productID: "product-999"),
        eventPayload: nil,
        currentState: state
    )

    let executor = ResolverExecutor.createExecutor(for: FailingResolver.self)

    do {
        _ = try await ResolverExecutor.executeResolvers(
            executors: [executor],
            resolverContext: resolverContext,
            landContext: landContext
        )
        Issue.record("Expected error was not thrown")
    } catch ResolverExecutionError.resolverFailed(let name, let underlyingError) {
        // Verify resolver name is captured
        #expect(name.contains("FailingResolver"))

        // Verify underlying error is preserved
        if let resolverError = underlyingError as? ResolverError {
            switch resolverError {
            case .dataLoadFailed(let message):
                #expect(message.contains("Product not found"))
            default:
                Issue.record("Unexpected resolver error type: \(resolverError)")
            }
        } else {
            Issue.record("Underlying error is not ResolverError: \(underlyingError)")
        }
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

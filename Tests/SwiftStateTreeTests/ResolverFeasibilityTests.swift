import Foundation
import Testing
import Logging
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

// MARK: - Test ResolverOutput Types

@PlainData
struct ProductInfo: ResolverOutput {
    let id: String
    let name: String
    let priceCents: Int64
    let stock: Int
}

@PlainData
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
            priceCents: 9999,
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

// MARK: - Gated Resolvers (concurrency proof)

/// The gate the two gated resolvers below enter. Only `testParallelResolverExecutionAsyncLet`
/// uses these types, so one shared slot is enough; the test sets it before it runs them.
enum ResolverEntryGate {
    nonisolated(unsafe) static var gate = TestGate()
}

/// Like `ProductInfoResolver`, but it signals that it has entered and then waits for the gate to
/// open, instead of sleeping. A resolver that never starts can't signal.
struct GatedProductInfoResolver: ContextResolver {
    typealias Output = ProductInfo

    static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
        await ResolverEntryGate.gate.arrive()
        let action = ctx.actionPayload as? ResolverTestAction
        return ProductInfo(id: action?.productID ?? "default-product", name: "Test Product", priceCents: 9999, stock: 100)
    }
}

/// Like `UserProfileResolver`, gated in the same way.
struct GatedUserProfileResolver: ContextResolver {
    typealias Output = UserProfileInfo

    static func resolve(ctx: ResolverContext) async throws -> UserProfileInfo {
        await ResolverEntryGate.gate.arrive()
        return UserProfileInfo(userID: ctx.playerID.rawValue, name: "Test User", email: "test@example.com", level: 10)
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
    let product = ProductInfo(id: "1", name: "Test", priceCents: 1000, stock: 5)
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
    #expect(output.priceCents == 9999)
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

    // Concurrency is proved by events, not by elapsed time: each resolver signals that it has
    // entered the gate and waits there. The test opens the gate only once both have entered.
    // Run one after the other, the first resolver would wait at the gate for good and the second
    // would never enter, so the second arrival never comes and the deadline fails the test.
    let gate = TestGate()
    ResolverEntryGate.gate = gate
    let run = Task {
        try await executeResolversInParallel(
            GatedProductInfoResolver.self,
            GatedUserProfileResolver.self,
            ctx: resolverContext
        )
    }
    let bothEntered = await withinCancellingDeadline("both resolvers entered before either finished") {
        await gate.waitForArrivals(2)
    }
    gate.open()
    #expect(bothEntered == true)
    let (productInfo, userProfile) = try await run.value

    #expect(productInfo.id == "product-123")
    #expect(userProfile.userID == "player-1")
}

@Test("Dynamic context storage with @dynamicMemberLookup")
func testDynamicContextStorage() {
    var ctx = TestResolverContext()

    let productInfo = ProductInfo(id: "1", name: "Test", priceCents: 1000, stock: 5)
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
    let productInfo = ProductInfo(id: "1", name: "Test Product", priceCents: 9999, stock: 100)
    let userProfile = UserProfileInfo(userID: "1", name: "Test User", email: "test@test.com", level: 10)

    // Simulate synchronous action handler
    var state = TestState()
    let action = ResolverTestAction(productID: "1")

    // Synchronous handler that uses pre-resolved data
    func handleActionSync(state: inout TestState, action: ResolverTestAction, productInfo: ProductInfo, userProfile: UserProfileInfo) throws -> ResolverTestResponse {
        // Use resolver outputs synchronously
        state.value = Int(productInfo.priceCents / 100)
        // Handler logic here...
        return ResolverTestResponse(success: true)
    }

    let response = try handleActionSync(state: &state, action: action, productInfo: productInfo, userProfile: userProfile)
    #expect(response.success == true)
    #expect(state.value == 99) // 9999 cents = 99 whole units
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
        // No deadline: the test is about how the error is wrapped. With the default 5 s one, a
        // starved runner settled the race as a timeout before the resolver's error (#447).
        _ = try await ResolverDeadline.$overrideForTesting.withValue(.zero) {
            try await ResolverExecutor.executeResolvers(
                executors: [executor],
                resolverContext: resolverContext,
                landContext: landContext
            )
        }
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

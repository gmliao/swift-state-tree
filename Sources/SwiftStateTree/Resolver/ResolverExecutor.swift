import Foundation

/// Protocol for type-erased resolver execution
///
/// This allows storing resolver execution closures in a type-safe way.
public protocol AnyResolverExecutor: Sendable {
    func execute(ctx: ResolverContext) async throws -> (String, any ResolverOutput)
}

/// Type-erased wrapper for a specific resolver type
public struct ResolverExecutorWrapper<R: ContextResolver>: AnyResolverExecutor {
    public func execute(ctx: ResolverContext) async throws -> (String, any ResolverOutput) {
        let output = try await R.resolve(ctx: ctx)
        let propertyName = ResolverExecutor.convertResolverTypeToPropertyName(String(describing: R.self))
        return (propertyName, output)
    }
}

/// Utility for executing resolvers in parallel and populating LandContext with outputs.
///
/// This module handles the parallel execution of all declared resolvers before
/// a handler runs, ensuring all resolver outputs are available
/// synchronously in the handler.
public enum ResolverExecutor {
    /// Execute multiple resolvers in parallel and populate the context with outputs.
    ///
    /// - Parameters:
    ///   - executors: Array of type-erased resolver executors
    ///   - resolverContext: The context to pass to each resolver
    ///   - landContext: The LandContext to populate with resolver outputs
    /// - Returns: Updated LandContext with all resolver outputs populated
    /// - Throws: `ResolverExecutionError` if any resolver fails, containing information about which resolver failed and why,
    ///   or `.timedOut` if the group runs past `ResolverDeadline` (`RESOLVER_TIMEOUT_MS`, #104)
    ///
    /// **Deadline**: a group still running at the deadline is cancelled and the call throws
    /// `.timedOut`. A resolver that ignores cancellation keeps running, and so do its external
    /// effects: a retry of the join or action runs it again, so a resolver with side effects must
    /// be idempotent (at-least-once).
    ///
    /// **Error Handling**:
    /// - If any resolver throws an error, all remaining resolvers are cancelled
    /// - The error is wrapped in `ResolverExecutionError` with the resolver name for better diagnostics
    /// - Example: If `ProductInfoResolver` fails with "product not found", the error will be:
    ///   `ResolverExecutionError.resolverFailed(name: "ProductInfoResolver", error: ResolverError.dataLoadFailed("product not found"))`
    public static func executeResolvers(
        executors: [any AnyResolverExecutor],
        resolverContext: ResolverContext,
        landContext: LandContext
    ) async throws -> LandContext {
        guard !executors.isEmpty, let deadline = ResolverDeadline.current else {
            return try await runGroup(executors: executors, resolverContext: resolverContext, landContext: landContext, race: nil)
        }
        return try await runWithDeadline(deadline, executors: executors, resolverContext: resolverContext, landContext: landContext) {
            $0.noteTimedOut()
        }
    }

    /// `executeResolvers` for an action job: `abandonment` learns when the caller stops waiting
    /// while the group still runs (the deadline, or a cancellation), and when that group ends.
    package static func executeActionResolvers(
        executors: [any AnyResolverExecutor],
        resolverContext: ResolverContext,
        landContext: LandContext,
        abandonment: ActionAbandonment
    ) async throws -> LandContext {
        guard !executors.isEmpty, let deadline = ResolverDeadline.current else {
            return try await runGroup(executors: executors, resolverContext: resolverContext, landContext: landContext, race: nil)
        }
        return try await runWithDeadline(deadline, executors: executors, resolverContext: resolverContext, landContext: landContext, abandonment: abandonment) {
            $0.noteTimedOut()
        }
    }

    /// `executeResolvers` with the OnInitialize deadline (`RESOLVER_INIT_TIMEOUT_MS`, #104).
    /// Every join, leave and action awaits the initialization, so a stuck OnInitialize resolver
    /// would hold them all; a timeout fails the land's initialization instead.
    package static func executeInitializeResolvers(
        executors: [any AnyResolverExecutor],
        resolverContext: ResolverContext,
        landContext: LandContext
    ) async throws -> LandContext {
        guard !executors.isEmpty, let deadline = ResolverDeadline.currentInit else {
            return try await runGroup(executors: executors, resolverContext: resolverContext, landContext: landContext, race: nil)
        }
        return try await runWithDeadline(deadline, executors: executors, resolverContext: resolverContext, landContext: landContext) {
            $0.noteInitTimedOut()
        }
    }

    /// `executeResolvers` without the deadline, for the destroy handlers' resolvers
    /// (OnDestroyWhenEmpty, OnFinalize, #104). They run on the destroy path, outside every
    /// player's queue, and a cut-off one would skip its handler (a final save, for example).
    package static func executeResolversWithoutDeadline(
        executors: [any AnyResolverExecutor],
        resolverContext: ResolverContext,
        landContext: LandContext
    ) async throws -> LandContext {
        try await runGroup(executors: executors, resolverContext: resolverContext, landContext: landContext, race: nil)
    }

    /// Races the group against `deadline` (#104). The race returns at the deadline even if a
    /// resolver ignores cancellation: a task group waits for its children, so the group runs in
    /// an unstructured task the race doesn't wait for. A late result is dropped; the race writes
    /// no keeper state, so nothing changes when the abandoned task ends.
    ///
    /// The deadline bounds resolvers, not the scheduling of the task that delivers the group's
    /// result: when it passes with no resolver still running, the group's own result (its
    /// output or a resolver's error) wins, and no timeout is counted (#448).
    ///
    /// Cancelling the caller cancels the group, and the call throws `CancellationError` at once,
    /// even if a resolver ignores the cancellation: the group then counts as abandoned (not as a
    /// timeout) until its task ends.
    private static func runWithDeadline(
        _ deadline: Duration,
        executors: [any AnyResolverExecutor],
        resolverContext: ResolverContext,
        landContext: LandContext,
        abandonment: ActionAbandonment? = nil,
        countTimeout: @escaping @Sendable (ResolverDeadlineMetrics) -> Void
    ) async throws -> LandContext {
        let metrics = ResolverDeadline.metrics
        let race = ResolverDeadlineRace(names: executors.map(extractResolverName))
        let work = Task {
            try await runGroup(executors: executors, resolverContext: resolverContext, landContext: landContext, race: race)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ResolverDeadline.beforeRaceWaitForTesting?()
                race.install(continuation)
                Task {
                    let result = await work.result
                    await ResolverDeadline.beforeResultDeliveryForTesting?()
                    race.settle(result)
                }
                let timer = Task {
                    // A cancelled sleep: the group settled first.
                    guard (try? await safeTaskSleep(for: deadline)) != nil else { return }
                    await ResolverDeadline.deadlinePassedForTesting?()
                    let stillRunning = race.stillRunning
                    guard !stillRunning.isEmpty else {
                        // Every resolver has finished, and the task delivering the group's
                        // result hasn't settled the race yet (#448). What's left is the group's
                        // merge, which runs no resolver code, so the wait is bounded: the group's
                        // own result wins, and no timeout is counted.
                        race.settle(await work.result)
                        return
                    }
                    let timedOut = ResolverExecutionError.timedOut(names: stillRunning, after: deadline)
                    guard race.settle(.failure(timedOut), onWin: {
                        countTimeout(metrics)
                        abandonment?.noteBegan()
                    }) else { return }
                    work.cancel()
                    // The abandoned gauge comes down when the group's task ends, which a
                    // resolver that ignores cancellation may never let happen.
                    _ = await work.result
                    metrics.noteAbandonedEnded()
                    abandonment?.noteEnded()
                }
                race.setTimer(timer)
            }
        } onCancel: {
            // Settled before the group is cancelled: a group that honours the cancellation
            // would otherwise finish first, with its resolver's error instead.
            let won = race.settle(.failure(CancellationError()), onWin: {
                metrics.noteCallerCancelled()
                abandonment?.noteBegan()
            })
            work.cancel()
            guard won else { return }
            Task {
                _ = await work.result
                metrics.noteAbandonedEnded()
                abandonment?.noteEnded()
            }
        }
    }

    /// Test hook: called with a resolver's property name once the group has collected its
    /// output, so a test can order a sibling's failure after it without timing.
    @TaskLocal package static var outputCollectedForTesting: (@Sendable (String) -> Void)?

    private static func runGroup(
        executors: [any AnyResolverExecutor],
        resolverContext: ResolverContext,
        landContext: LandContext,
        race: ResolverDeadlineRace?
    ) async throws -> LandContext {
        var updatedContext = landContext

        // Execute all resolvers in parallel using TaskGroup
        // We use a custom error type to capture which resolver failed
        try await withThrowingTaskGroup(of: (String, any ResolverOutput).self) { group in
            for executor in executors {
                group.addTask {
                    let resolverName = extractResolverName(from: executor)
                    defer { race?.resolverFinished(resolverName) }
                    do {
                        return try await executor.execute(ctx: resolverContext)
                    } catch {
                        // Wrap error with resolver name for better diagnostics
                        throw ResolverExecutionError.resolverFailed(name: resolverName, underlyingError: error)
                    }
                }
            }

            // Collect all results
            // If any resolver throws, the error will be propagated and remaining tasks cancelled
            let outputCollected = outputCollectedForTesting
            for try await (propertyName, output) in group {
                updatedContext.setResolverOutput(output, forPropertyName: propertyName)
                outputCollected?(propertyName)
            }
        }

        return updatedContext
    }

    /// Create a resolver executor for a specific resolver type
    ///
    /// - Parameter resolverType: The resolver type
    /// - Returns: A type-erased executor that can execute the resolver
    public static func createExecutor<R: ContextResolver>(for resolverType: R.Type) -> any AnyResolverExecutor {
        return ResolverExecutorWrapper<R>()
    }

    /// Convert resolver type name to property name for dynamic member lookup
    ///
    /// Examples:
    /// - "ProductInfoResolver" -> "productInfo"
    /// - "UserProfileResolver" -> "userProfile"
    /// - "ShopConfigResolver" -> "shopConfig"
    public static func convertResolverTypeToPropertyName(_ typeName: String) -> String {
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
    
    /// Extract resolver name from executor for error reporting
    private static func extractResolverName(from executor: any AnyResolverExecutor) -> String {
        // Try to extract from type name
        let typeName = String(describing: type(of: executor))
        
        // ResolverExecutorWrapper<SomeResolver> -> SomeResolver
        if let genericStart = typeName.range(of: "<"),
           let genericEnd = typeName.range(of: ">", range: genericStart.upperBound..<typeName.endIndex) {
            let resolverTypeName = String(typeName[genericStart.upperBound..<genericEnd.lowerBound])
            return resolverTypeName
        }
        
        // Fallback to full type name
        return typeName
    }
}

// Sources/ServerLoadTest/ConcurrentTaskPool.swift
//
// Reusable concurrent task pool utility using TaskGroup.
// Limits the number of concurrent tasks to avoid actor contention.

import Foundation

/// Execute tasks with controlled concurrency using TaskGroup.
///
/// Example usage:
/// ```swift
/// await ConcurrentTaskPool.execute(
///     maxConcurrent: 20,
///     count: 100
/// ) { index in
///     await performWork(index)
/// }
/// ```
enum ConcurrentTaskPool {
    /// Execute a range of indexed tasks with limited concurrency
    /// - Parameters:
    ///   - maxConcurrent: Maximum number of concurrent tasks (default: 20)
    ///   - count: Number of tasks to execute (0..<count)
    ///   - work: Async closure that performs work for each index
    static func execute(
        maxConcurrent: Int = 20,
        count: Int,
        work: @escaping @Sendable (Int) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var submitted = 0
            var completed = 0

            while submitted < count || completed < submitted {
                // Fill worker pool up to maxConcurrent
                while submitted < count, (submitted - completed) < maxConcurrent {
                    let index = submitted
                    group.addTask {
                        await work(index)
                    }
                    submitted += 1
                }

                // Wait for one worker to complete
                if await group.next() != nil {
                    completed += 1
                }
            }
        }
    }
}

//  SafeSleep.swift
//  SwiftStateTurns
//
//  The same workaround as `safeTaskSleep(for:)` in Sources/SwiftStateTree/Support/SafeTaskSleep.swift:
//  `Task.sleep(for: Duration)` can crash in macOS release builds under load (SIGABRT in
//  swift_task_dealloc), so library code sleeps with `Task.sleep(nanoseconds:)`.
//
//  This target can't call that function: SwiftStateTree depends on SwiftStateTurns, not the other
//  way round. A public function of the same name in both modules would also be ambiguous in a file
//  that imports SwiftStateTree, which re-exports this module. So this helper is internal and has
//  its own name.

/// Sleeps for `nanoseconds` with `Task.sleep(nanoseconds:)`, never `Task.sleep(for:)`.
///
/// - Throws: `CancellationError` if the task is cancelled during the sleep.
func turnsSafeSleep(nanoseconds: UInt64) async throws {
    try await Task.sleep(nanoseconds: nanoseconds)
}

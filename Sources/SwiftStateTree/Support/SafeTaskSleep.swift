//
//  SafeTaskSleep.swift
//  SwiftStateTree
//
//  Created: 2026-01-26
//
//  Created to work around a Swift Concurrency runtime bug where Task.sleep(for: Duration)
//  can crash in macOS release builds under load (SIGABRT in swift_task_dealloc).
//
//  This module provides a safe alternative that converts Duration to nanoseconds
//  and uses Task.sleep(nanoseconds:) instead.
//
//  Related:
//  - Repository: https://github.com/gmliao/swift-state-tree
//  - Investigation: See Examples/GameDemo/MESSAGEPACK_INVESTIGATION.md
//  - Swift Concurrency Runtime Bug: Task.sleep(for: Duration) crashes on macOS release builds
//

import Foundation

/// Safe wrapper around Task.sleep that avoids the macOS release build crash bug.
///
/// **DO NOT use `Task.sleep(for:)` directly in library code.**
/// Use this function instead for all sleep operations in `Sources/SwiftStateTree`.
///
/// This function converts `Duration` to nanoseconds and uses `Task.sleep(nanoseconds:)`
/// to work around a known Swift Concurrency runtime bug on macOS release builds.
///
/// - Parameter duration: The duration to sleep for.
/// - Throws: `CancellationError` if the task is cancelled during sleep.
public func safeTaskSleep(for duration: Duration) async throws {
    // Convert Duration to nanoseconds for Task.sleep(nanoseconds:).
    //
    // NOTE: We intentionally avoid Task.sleep(for:) here. It was observed to crash in
    // macOS release builds under load (SIGABRT in swift_task_dealloc).
    let comps = duration.components
    let seconds = comps.seconds
    let attoseconds = comps.attoseconds
    
    // Validate non-negative values
    guard seconds >= 0, attoseconds >= 0 else {
        // Invalid duration, skip sleep
        return
    }
    
    // Convert attoseconds to nanoseconds (1e18 attos per second, 1e9 attos per nano)
    let nanosFromAttos = UInt64(attoseconds / 1_000_000_000)
    
    // Convert seconds to UInt64, checking for overflow
    guard let sec = UInt64(exactly: seconds) else {
        // Duration too large, skip sleep
        return
    }
    
    // Multiply seconds by 1 billion to get nanoseconds
    let mul = sec.multipliedReportingOverflow(by: 1_000_000_000)
    guard !mul.overflow else {
        // Overflow detected, skip sleep
        return
    }
    
    // Add attosecond-derived nanoseconds
    let add = mul.partialValue.addingReportingOverflow(nanosFromAttos)
    guard !add.overflow else {
        // Overflow detected, skip sleep
        return
    }
    
    let totalNanos = add.partialValue
    
    // Use Task.sleep(nanoseconds:) instead of Task.sleep(for:)
    try await Task.sleep(nanoseconds: totalNanos)
}

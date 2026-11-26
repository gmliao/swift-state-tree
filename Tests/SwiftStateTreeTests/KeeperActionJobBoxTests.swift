// Tests/SwiftStateTreeTests/KeeperActionJobBoxTests.swift
//
// The action job's box (#700 K1b-5 rev 2.5 D16): it holds the task handle and a cancel that
// came before the install, and it calls the task's `cancel()` after releasing its lock.

import Foundation
import Testing
@testable import SwiftStateTree

/// A task that waits until it is cancelled, and tells when its cancellation handler runs.
private final class CancellableWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    /// What the cancellation handler runs, inside the task's `cancel()`.
    var onCancel: @Sendable () -> Void = {}

    /// The body: waits inside the cancellation handler's scope until cancelled.
    func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let (resumeNow, enteredWaiter) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
                    hasEntered = true
                    defer { entered = nil }
                    if cancelled { return (true, entered) }
                    continuation = c
                    return (false, entered)
                }
                enteredWaiter?.resume()
                if resumeNow { c.resume() }
            }
        } onCancel: {
            onCancel()
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                cancelled = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }

    /// Returns once the body is waiting inside the handler's scope.
    func waitUntilEntered() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if hasEntered { return true }
                entered = c
                return false
            }
            if already { c.resume() }
        }
    }
}

@Suite("The action job's box: the handle and an early cancel under one lock (#700 K1b-5 D16)")
struct KeeperActionJobBoxTests {
    private func box() -> KeeperActionJobTask {
        KeeperActionJobTask(abandonment: ResolverAbandonment(kind: nil, counter: nil, metrics: ResolverDeadline.metrics))
    }

    @Test("A cancel before the install is kept, and the install cancels the task it installs")
    func cancelBeforeInstall() async {
        let box = box()
        let wait = CancellableWait()
        // The cancel a body stages after the job's start: it finds no handle.
        box.cancel()
        let task = Task { await wait.run() }
        box.install(task)
        #expect(task.isCancelled)
        #expect(box.installedTask != nil)
        // The task ends only on the cancel under test: cancel it here too, so a box that lost
        // the cancel fails the expect above instead of hanging the await.
        task.cancel()
        await task.value
    }

    @Test("A cancel after the install cancels the installed task")
    func cancelAfterInstall() async {
        let box = box()
        let wait = CancellableWait()
        let task = Task { await wait.run() }
        box.install(task)
        #expect(!task.isCancelled)
        box.cancel()
        #expect(task.isCancelled)
        task.cancel()
        await task.value
    }

    @Test("A cancellation handler that reads the box runs inside the cancel without finding it locked")
    func handlerReadsTheBox() async {
        let box = box()
        let wait = CancellableWait()
        let read = ActionJobCallerCancellation()
        wait.onCancel = {
            // Runs synchronously inside the task's `cancel()`: the box's lock must be released.
            _ = box.installedTask
            read.set()
        }
        let task = Task { await wait.run() }
        box.install(task)
        await wait.waitUntilEntered()
        box.cancel()
        // The handler ran inside `cancel()`, before it returned.
        #expect(read.isSet)
        task.cancel()
        await task.value
    }

    @Test("A cancellation handler that reads the box runs inside the install's forwarded cancel without finding it locked")
    func handlerReadsTheBoxDuringTheForwardedCancel() async {
        let box = box()
        let wait = CancellableWait()
        let read = ActionJobCallerCancellation()
        wait.onCancel = {
            // Runs synchronously inside the `cancel()` that `install` forwards: the box's lock
            // must be released by then.
            _ = box.installedTask
            read.set()
        }
        // A task already inside the handler's scope, so its handler runs inside `cancel()`.
        let task = Task { await wait.run() }
        await wait.waitUntilEntered()
        box.cancel()
        box.install(task)
        #expect(read.isSet)
        task.cancel()
        await task.value
    }
}

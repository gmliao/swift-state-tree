// Sources/SwiftStateTree/Support/Lifecycle.swift
//
// Start/stop as a state machine, for actors that own a server, a transport or a host (#101).

/// The lifecycle of a startable resource, owned by one actor (a stored `var`).
///
/// The phase changes synchronously before the first `await` of a start or a stop, so concurrent
/// calls see it: a second `start` while starting joins the in-flight start, a second `stop`
/// joins the in-flight stop, and a `stop` during a start runs after that start. A stopped
/// resource doesn't start again.
///
/// Usage, inside the owning actor:
/// ```swift
/// func start() async throws {
///     switch lifecycle.beginStart({ Task { try await self.doStart() } }) {
///     case .run(let task, let token):
///         let result = await task.result
///         lifecycle.finishStart(token, succeeded: (try? result.get()) != nil)
///         try result.get()
///     case .join(let task): try await task.value
///     case .alreadyRunning: return
///     case .stopped: throw LifecycleError.stopped
///     }
/// }
/// ```
package struct Lifecycle: Sendable {
    package enum Phase: Sendable, Equatable {
        case idle, starting, running, stopping, stopped
    }

    /// The outcome of `beginStart`.
    package enum StartDecision: Sendable {
        /// This call starts it: await `task`, then call `finishStart(token, succeeded:)`.
        case run(Task<Void, Error>, token: Epoch)
        /// A start is in flight: await it.
        case join(Task<Void, Error>)
        case alreadyRunning
        case stopped
    }

    /// The outcome of `beginStop`.
    package enum StopDecision: Sendable {
        /// This call stops it: await `task`, then call `finishStop(token)`.
        case run(Task<Void, Never>, token: Epoch)
        /// A stop is in flight: await it.
        case join(Task<Void, Never>)
        /// Never started, or already stopped.
        case nothingToStop
    }

    package private(set) var phase: Phase = .idle
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var counter = EpochCounter()
    private var token: Epoch?

    package init() {}

    /// Decides a start in this synchronous segment. `make` creates the start's task, only when
    /// this call starts it.
    package mutating func beginStart(_ make: () -> Task<Void, Error>) -> StartDecision {
        switch phase {
        case .idle:
            let task = make()
            let token = counter.next()
            self.token = token
            startTask = task
            phase = .starting
            return .run(task, token: token)
        case .starting:
            guard let startTask else { return .alreadyRunning }
            return .join(startTask)
        case .running:
            return .alreadyRunning
        case .stopping, .stopped:
            return .stopped
        }
    }

    /// Records the start's outcome. Ignored if a stop took over meanwhile (`token` not current).
    /// A failed start returns to `.idle`, so it can be started again.
    package mutating func finishStart(_ token: Epoch, succeeded: Bool) {
        guard self.token == token, phase == .starting else { return }
        startTask = nil
        phase = succeeded ? .running : .idle
    }

    /// Decides a stop in this synchronous segment. `make` gets the in-flight start, if any, so
    /// the stop can await it first; it is called only when this call stops it.
    package mutating func beginStop(_ make: (_ inFlightStart: Task<Void, Error>?) -> Task<Void, Never>) -> StopDecision {
        switch phase {
        case .idle, .stopped:
            phase = .stopped
            return .nothingToStop
        case .stopping:
            guard let stopTask else { return .nothingToStop }
            return .join(stopTask)
        case .starting, .running:
            let task = make(phase == .starting ? startTask : nil)
            let token = counter.next()
            self.token = token
            startTask = nil
            stopTask = task
            phase = .stopping
            return .run(task, token: token)
        }
    }

    /// Records the end of the stop.
    package mutating func finishStop(_ token: Epoch) {
        guard self.token == token, phase == .stopping else { return }
        stopTask = nil
        phase = .stopped
    }
}

/// Thrown by a start on a resource that was stopped.
package enum LifecycleError: Error, Sendable, Equatable {
    case stopped
}

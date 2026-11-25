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
/// The task records its own end. `beginStart` and `beginStop` mint the token first and hand it to
/// `make`; the task calls `finishStart(token, succeeded:)` or `finishStop(token)` as its last
/// actor-isolated step, so the phase is written before the task's result is available to any
/// waiter (the shape of `SingleFlight`'s flights: the producer resolves, the waiters only
/// await). A runner and a joiner both just await the task; neither has a finish to forget, and
/// both see the phase the task wrote, if that start is still current: a stop that took over
/// before the start's task ended makes the start's finish a stale no-op.
///
/// `make` must create a plain `Task { ... }`, whose body is enqueued and starts after the calling
/// segment. Never `Task.immediate` (or anything else that runs the body inline): the body's
/// `finishStart` / `finishStop` could then run before `beginStart` / `beginStop` stored the
/// token and the phase, and the finish would be dropped as stale.
///
/// Usage, inside the owning actor:
/// ```swift
/// func start() async throws {
///     switch lifecycle.beginStart({ token in Task { try await self.runStart(token) } }) {
///     case .run(let task), .join(let task): try await task.value
///     case .alreadyRunning: return
///     case .stopped: throw LifecycleError.stopped
///     }
/// }
///
/// private func runStart(_ token: Epoch) async throws {
///     do { try await doStart() } catch {
///         lifecycle.finishStart(token, succeeded: false)
///         throw error
///     }
///     lifecycle.finishStart(token, succeeded: true)  // the task's last actor step
/// }
/// ```
package struct Lifecycle: Sendable {
    package enum Phase: Sendable, Equatable {
        case idle, starting, running, stopping, stopped
    }

    /// The outcome of `beginStart`.
    package enum StartDecision: Sendable {
        /// This call starts it: await `task`. The task finishes the start itself.
        case run(Task<Void, Error>)
        /// A start is in flight: await its `task`, as the runner does.
        case join(Task<Void, Error>)
        case alreadyRunning
        case stopped
    }

    /// The outcome of `beginStop`.
    package enum StopDecision: Sendable {
        /// This call stops it: await `task`. The task finishes the stop itself.
        case run(Task<Void, Never>)
        /// A stop is in flight: await its `task`, as the runner does.
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
    /// this call starts it, and gets the token the task passes to `finishStart` as its last
    /// actor-isolated step. `make` runs inside this call: it only creates the task, and doesn't
    /// touch the lifecycle itself.
    package mutating func beginStart(_ make: (_ token: Epoch) -> Task<Void, Error>) -> StartDecision {
        switch phase {
        case .idle:
            let token = counter.next()
            let task = make(token)
            self.token = token
            startTask = task
            phase = .starting
            return .run(task)
        case .starting:
            guard let startTask else { return .alreadyRunning }
            return .join(startTask)
        case .running:
            return .alreadyRunning
        case .stopping, .stopped:
            return .stopped
        }
    }

    /// Records the start's outcome; the start's task calls it, once, as its last actor step. A
    /// call is ignored unless `token` is the current start's and the phase is `.starting`: a stop
    /// that took over meanwhile (a newer token), a second call for the same start, and a late
    /// call of an earlier start after a retry (an older token) all leave the phase alone. A
    /// failed start returns to `.idle`, so it can be started again.
    package mutating func finishStart(_ token: Epoch, succeeded: Bool) {
        guard self.token == token, phase == .starting else { return }
        startTask = nil
        phase = succeeded ? .running : .idle
    }

    /// Decides a stop in this synchronous segment. `make` gets the in-flight start, if any, so
    /// the stop can await it first, and the token the task passes to `finishStop` as its last
    /// actor-isolated step; it is called only when this call stops it, and runs inside this call
    /// (it only creates the task).
    package mutating func beginStop(
        _ make: (_ inFlightStart: Task<Void, Error>?, _ token: Epoch) -> Task<Void, Never>
    ) -> StopDecision {
        switch phase {
        case .idle, .stopped:
            phase = .stopped
            return .nothingToStop
        case .stopping:
            guard let stopTask else { return .nothingToStop }
            return .join(stopTask)
        case .starting, .running:
            let token = counter.next()
            let task = make(phase == .starting ? startTask : nil, token)
            self.token = token
            startTask = nil
            stopTask = task
            phase = .stopping
            return .run(task)
        }
    }

    /// Records the end of the stop; the stop's task calls it as its last actor step. Only the
    /// current stop's token in `.stopping` writes `.stopped`: the phase guard is what keeps a
    /// start's token (the token isn't cleared by `finishStart`) from stopping the lifecycle.
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

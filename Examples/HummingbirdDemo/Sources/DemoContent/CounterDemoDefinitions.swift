import SwiftStateTree

// MARK: - Counter Demo State

/// Simple counter state for the minimal demo example.
@StateNodeBuilder
public struct CounterState: StateNodeProtocol {
    /// Current count value, broadcast to all clients.
    @Sync(.broadcast)
    var count: Int = 0

    public init() {}
}

// MARK: - Actions

/// Action to increment the counter.
@Payload
public struct IncrementAction: ActionPayload {
    public typealias Response = IncrementResponse

    public init() {}
}

@Payload
public struct IncrementResponse: ResponsePayload {
    public let newCount: Int

    public init(newCount: Int) {
        self.newCount = newCount
    }
}

// MARK: - Land Definition

public enum CounterDemo {
    public static func makeLand() -> LandDefinition<CounterState> {
        Land(
            "counter",
            using: CounterState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(10)
            }

            Lifetime {
                // Game logic updates (can modify state)
                Tick(every: .milliseconds(100)) { (state: inout CounterState, ctx: LandContext) in
                    // ctx.logger.info("LandId \(ctx.landID) is ticking...count: \(state.count)")
                }

                // Network synchronization (read-only callback will be called during sync)
                StateSync(every: .milliseconds(100)) { (state: CounterState, ctx: LandContext) in
                    // Read-only callback - will be called during sync
                    // Do NOT modify state here - use Tick for state mutations
                    // Use for logging, metrics, or other read-only operations
                }

                DestroyWhenEmpty(after: .seconds(5)) { (_: inout CounterState, ctx: LandContext) in
                    ctx.logger.info("Land is empty, destroying...")
                }
                OnFinalize { (state: inout CounterState, ctx: LandContext) in
                    ctx.logger.info("Land is finalizing...")
                }
                AfterFinalize { (state: CounterState, ctx: LandContext) async in
                    ctx.logger.info("Land is finalized with final count: \(state.count)")
                }
            }

            Rules {
                HandleAction(IncrementAction.self) { (state: inout CounterState, _: IncrementAction, _: LandContext) in
                    state.count += 1
                    return IncrementResponse(newCount: state.count)
                }
            }
        }
    }
}

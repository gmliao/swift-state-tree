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
                Tick(every: .milliseconds(100)) { (_: inout CounterState, _: LandContext) in
                    // Empty tick handler
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

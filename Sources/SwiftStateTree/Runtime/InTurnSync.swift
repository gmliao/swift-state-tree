import Foundation

/// The in-turn sync switch.
///
/// With in-turn sync, a land's transport adapter runs on its keeper's serial executor and the
/// keeper runs the sync phase synchronously inside its own turns (tick turns, sync-only turns and
/// input turns), with no suspension point between the state changes and the frames they produce.
/// Without it, the adapter keeps its own executor and syncs through `beginSync`/`endSync`, as
/// before.
///
/// The adapter decides once, at init, and is the single source of truth: the keeper follows it
/// through `LandKeeperTransport.runsSyncPhaseInTurn(of:)`. An explicit off anywhere wins: the
/// adapter's effective setting is its `inTurnSync` argument and `isEnabled()`.
///
/// Turn kinds:
/// - tick turn: ready inputs, the tick handler, the emitted events, and the sync phase when a
///   handler requested one or the sync loop folded into it (coincident-sync rule: a sync due
///   within min(5 ms, tick / 4, sync / 4) of the next tick runs in that tick turn);
/// - sync-only turn: the sync loop's own interval, so the legacy sync cadence is kept;
/// - input turn (tickless lands): at most `LandKeeper.inputTurnBatchLimit` ready inputs, their
///   events, and the sync phase when requested. The cap bounds how long continuous input can
///   delay the sync loop.
///
/// Stated limits:
/// - A joiner's first sync and the delivery of its OnJoin effects to the joiner stay outside
///   the turn (the joiner path still reads the state with an `await`).
/// - The debug freeze settle still runs a `beginSync` / `endSync` cycle. A turn that wants a
///   sync while such a cycle is in flight leaves it to a sync-only turn after `endSync`.
/// - Opcode 107 keeps emit order per frame kind only: per session the merged broadcast frame
///   comes first, then targeted event frames, then the per-player frame.
/// - A handler that throws keeps the legacy semantics: the pass is aborted and its inputs stay
///   pending; the state keeps what the handlers wrote before the throw.
/// - Re-evaluation keepers always use the legacy path.
public enum InTurnSync {
    /// Whether in-turn sync is enabled by the environment: `true` unless `IN_TURN_SYNC` is false.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(
            key: EnvKeys.Runtime.inTurnSync,
            defaultValue: true,
            environment: environment
        )
    }
}

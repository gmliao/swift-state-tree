// Sources/SwiftStateTree/Runtime/KeeperModel+Drivers.swift
//
// The drivers' synchronous glue as model segments (#700 K2-1, plan
// `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` §4.3). A driver (the tick loop's
// `runTick`, the tickless input drain) runs checks and counter writes around its turn bodies,
// between its awaits. They are model methods here so the keeper's driver and the core's steps
// call the same code (K2's condition 1). Each method is synchronous, and each one covers a
// stretch of a driver that has no await, so every segment boundary stays where an await is.
// No field changes home: every field these methods touch was already the model's.

import Foundation

/// Whether a tick may start: not while frozen.
enum KeeperTickAdmission: Equatable {
    case frozen
    /// Admitted: the tick counts as in-flight work (`debugInFlightWork`) until the driver's
    /// `debugEndWork`.
    case admitted
}

extension KeeperModel {
    // MARK: - The tick (`runTick`)

    /// A tick doesn't start while frozen (a body already running is drained by `debugFreeze`).
    /// Otherwise it begins one unit of in-flight work, which the caller ends with `debugEndWork`.
    mutating func tickAdmit() -> KeeperTickAdmission {
        guard !debugFrozen else { return .frozen }
        debugBeginWork()
        return .admitted
    }

    /// A tickless land's tick schedules the input drain: `true` when this call scheduled it,
    /// `false` when one is already scheduled. The drain clears the flag (`endInputDrain`).
    mutating func scheduleInputDrain() -> Bool {
        guard !inputDrainScheduled else { return false }
        inputDrainScheduled = true
        return true
    }

    /// Starts a tick: its ID, or nil when the land is draining or a forced shutdown waits for
    /// the tick in flight (#382). A started tick is in flight until `tickEnd`. Read in the same
    /// segment as the start, so no tick starts once the drain has (the drain waits for one in
    /// flight before it takes the pending inputs).
    mutating func tickStart(_ side: KeeperTurnSide) -> Int64? {
        guard !side.isDraining, !shutdownRequested else { return nil }
        ticksInFlight += 1
        defer { nextTickId += 1 }
        return nextTickId
    }

    /// Ends a started tick: `true` when no tick is in flight any more, and the caller wakes
    /// whoever waits for that.
    mutating func tickEnd() -> Bool {
        ticksInFlight -= 1
        return ticksInFlight == 0
    }

    // MARK: - The tickless input drain (`runInputDrain`)

    /// The next input turn's batch: at most `limit` ready inputs, in order.
    func nextInputTurnBatch(limit: Int) -> [PendingItem] {
        Array(readyPendingItemsInOrder().prefix(limit))
    }

    /// The drain found no ready input: a later tick schedules the next one.
    mutating func endInputDrain() {
        inputDrainScheduled = false
    }

    /// Resumes the callers of `batch` with their outcomes, after the turn was recorded: a
    /// response never leaves before its input is recorded.
    mutating func resumeInputTurnWaiters(_ behavior: KeeperBehavior<State>, _ side: inout KeeperTurnSide, for batch: [PendingItem]) {
        for item in batch {
            // The result, and its error, are taken before the branch.
            let result: Result<InputOutcome, any Error> = inputTurnResults.removeValue(forKey: item.sequence)
                .map { taken(behavior, &side, $0, path: .inputTurn, sequence: item.sequence) } ?? .success(.none)
            if ticklessJobTurns.remove(item.sequence) != nil {
                // No waiter on the slot yet: held under a fresh ID.
                fillActionSlot(behavior, &side, item.sequence, with: result)
            } else {
                side.inputTurnWaiters.removeValue(forKey: item.sequence)?.resume(with: result)
            }
        }
        checkActionTables(behavior, side, #function)
    }
}

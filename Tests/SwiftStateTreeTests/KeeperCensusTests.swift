// Tests/SwiftStateTreeTests/KeeperCensusTests.swift
//
// Every stored property of `LandKeeper` has exactly one home (#700 K1b-4): the model
// (`KeeperModel`, plain), the behavior (`KeeperBehavior`, fixed at init), the replay fields, a
// named group that stays on the actor, a later slice that replaces it, or a test hook. A new field
// fails this test until it has a row; a row whose field is gone fails it until it is removed.
// Rows are keyed by storage path (`model.players`, `behavior.config.mode`, `actor.transport`), so
// a field in the wrong container fails too.

import Testing
@testable import SwiftStateTree

enum KeeperFieldHome: Hashable, CustomStringConvertible {
    case model
    case behavior
    case replay
    /// On the actor, in a named group, until a later slice moves it.
    case outside(OutsideGroup)
    /// On the actor until the named slice replaces it (a task, a continuation table).
    case replaced(by: String)
    case testHook
    /// `model`, `behavior`, `behavior.config` and `replay` themselves: their fields have rows of
    /// their own.
    case container

    enum OutsideGroup: String {
        case bindingToken, recorder, drainFlag, loopDriver, resolverAbandonment, serverInputCap, playerServices, failureTable
    }

    var description: String {
        switch self {
        case .model: "model"
        case .behavior: "behavior"
        case .replay: "replay"
        case .outside(let group): "outside(\(group.rawValue))"
        case .replaced(let slice): "replaced(by: \(slice))"
        case .testHook: "testHook"
        case .container: "container"
        }
    }
}

/// Fields whose home breaks a rule of that home, until the named slice ends the exception.
struct KeeperCensusException {
    let fields: [String]
    let home: KeeperFieldHome
    let why: String
    let endsIn: String
}

enum KeeperCensus {
    /// The groups `censusLabelsForTesting()` reflects.
    static let groups: Set<String> = ["actor", "model", "behavior", "behavior.config"]

    /// Every stored property, by storage path, with its home.
    static let homes: [String: KeeperFieldHome] = {
        var homes: [String: KeeperFieldHome] = [
            "actor.abandonmentCounter": .outside(.resolverAbandonment),
            "actor.actionJobRemovalWaiters": .replaced(by: "K2"),
            "actor.actionJobTasks": .replaced(by: "K5"),
            "actor.actionJobs": .model,
            "actor.actionJobsStarted": .model,
            "actor.actionSlotWaiters": .replaced(by: "K2"),
            "actor.actionSlots": .model,
            "actor.actionTableAuditForTesting": .testHook,
            "actor.alignmentViolations": .model,
            "actor.appliedSyncPhaseOffset": .outside(.loopDriver),
            "actor.appliedTickPhaseOffset": .outside(.loopDriver),
            "actor.behavior": .container,
            "actor.boundSyncRequesterObject": .outside(.bindingToken),
            "actor.debugActiveGeneration": .model,
            "actor.debugDrainWaiters": .replaced(by: "K7"),
            "actor.debugFrozen": .model,
            "actor.debugHeldInputs": .replaced(by: "K7"),
            "actor.debugInFlightWork": .model,
            "actor.debugNextWaiterID": .model,
            "actor.debugReleasedGeneration": .model,
            "actor.destroyHandlersStarted": .model,
            "actor.destroyTask": .replaced(by: "K7"),
            "actor.destructionFinished": .model,
            "actor.didInitialize": .model,
            "actor.drainFlag": .outside(.drainFlag),
            "actor.drainStartedWaitersForTesting": .replaced(by: "K2"),
            "actor.drainTask": .replaced(by: "K7"),
            "actor.entryGenerations": .model,
            "actor.failureIDs": .model,
            "actor.failureTableMisses": .model,
            "actor.failureWaitersForTesting": .replaced(by: "K2"),
            "actor.failures": .outside(.failureTable),
            "actor.foldedSyncs": .model,
            "actor.forceShutdownFlight": .replaced(by: "K7"),
            "actor.freezeWaitWatchersForTesting": .replaced(by: "K2"),
            "actor.hasHeldTransport": .model,
            "actor.holds": .testHook,
            "actor.inTurnDeferredTurns": .model,
            "actor.inTurnDrainRetryBinding": .model,
            "actor.inTurnProbeForTesting": .testHook,
            "actor.inTurnSyncDue": .model,
            "actor.inTurnSyncTurnKind": .model,
            "actor.inTurnYieldForTesting": .testHook,
            "actor.initializationFailure": .model,
            "actor.initializationTask": .replaced(by: "K5"),
            "actor.initializationWaitWatchers": .replaced(by: "K2"),
            "actor.initializationWaits": .replaced(by: "K2"),
            "actor.inputDrainIdleWaitersForTesting": .replaced(by: "K2"),
            "actor.inputDrainScheduled": .model,
            "actor.inputTurnResults": .model,
            "actor.inputTurnWaiters": .replaced(by: "K2"),
            "actor.inputsSkippedAfterDestroy": .model,
            "actor.joinSyncRequestTurnsForTesting": .model,
            "actor.joinSyncTicks": .model,
            "actor.joinSyncTurnBinding": .model,
            "actor.joinSyncTurnsForTesting": .model,
            "actor.joinSyncWaitsForCommit": .model,
            "actor.landRandom": .model,
            "actor.lastCommittedTickId": .model,
            "actor.lateFoldedSyncs": .model,
            "actor.model": .container,
            "actor.nextDrainStartedWaiterForTesting": .replaced(by: "K2"),
            "actor.nextFailureWaiterForTesting": .replaced(by: "K2"),
            "actor.nextRequestedSyncWorkWaiterForTesting": .replaced(by: "K2"),
            "actor.nextTickDeadline": .outside(.loopDriver),
            "actor.nextTickId": .model,
            "actor.outputCollector": .replaced(by: "K2"),
            "actor.overdueFoldedSyncs": .model,
            "actor.passInProgress": .model,
            "actor.passOrdinal": .model,
            "actor.pendingFold": .outside(.loopDriver),
            "actor.pendingItemScans": .model,
            "actor.pendingItems": .model,
            "actor.pendingSyncTurnAfterTurn": .outside(.bindingToken),
            "actor.pendingTransportFailure": .replaced(by: "K4"),
            "actor.players": .model,
            "actor.recordedPassMismatches": .replay,
            "actor.recorderSubmissionCount": .model,
            "actor.recorderSubmissions": .outside(.recorder),
            "actor.reevaluationRecorder": .outside(.recorder),
            "actor.reevaluationSink": .replay,
            "actor.reevaluationSource": .replay,
            "actor.rejoinReservationEpochs": .model,
            "actor.rejoinReservations": .model,
            "actor.releasedTransport": .outside(.bindingToken),
            "actor.replayFailureEnd": .replay,
            "actor.replayHeaderPayloadEncoding": .replay,
            "actor.replayPassObserver": .replay,
            "actor.replayRecordsPassOrdinals": .replay,
            "actor.replayRecordsRejected": .replay,
            "actor.replayRejected": .replay,
            "actor.replayedInitializeBeforeTickZero": .replay,
            "actor.replayedInitializeRefusal": .replay,
            "actor.requestedSyncTurnsForTesting": .model,
            "actor.requestedSyncWork": .model,
            "actor.requestedSyncWorkWaitersForTesting": .replaced(by: "K2"),
            "actor.serverInputCapRejections": .model,
            "actor.serverInputMaxInFlight": .outside(.serverInputCap),
            "actor.serverInputsHeldWhileFrozen": .model,
            "actor.serverInputsInFlight": .model,
            "actor.shutdownRequested": .model,
            "actor.shutdownTurnApplied": .model,
            "actor.shutdownTurnWaiters": .replaced(by: "K2"),
            "actor.slotWatchersForTesting": .replaced(by: "K2"),
            "actor.state": .model,
            "actor.stateHashUnavailableTotal": .model,
            "actor.supersededSenderRejections": .model,
            "actor.syncBinding": .model,
            "actor.syncClockForTesting": .testHook,
            "actor.syncOutputIndexCursor": .model,
            "actor.syncStreamCounter": .model,
            "actor.syncTask": .replaced(by: "K2"),
            "actor.tickClockForTesting": .testHook,
            "actor.tickIdleWaiters": .replaced(by: "K2"),
            "actor.tickLoopClock": .outside(.loopDriver),
            "actor.tickLoopConfiguredAt": .outside(.loopDriver),
            "actor.tickTask": .replaced(by: "K2"),
            "actor.ticklessJobTurns": .model,
            "actor.ticklessJobWork": .model,
            "actor.ticksInFlight": .model,
            "actor.transport": .outside(.bindingToken),
            "actor.transportRecordsFolds": .model,
            "behavior.config": .container,
            "behavior.config.actualLandID": .behavior,
            "behavior.config.autoStartLoops": .behavior,
            "behavior.config.enableLiveStateHashRecording": .behavior,
            "behavior.config.enableLoopPhaseOffset": .behavior,
            "behavior.config.landRandomSeed": .behavior,
            "behavior.config.mode": .behavior,
            "behavior.config.reevaluationOutputMode": .behavior,
            "behavior.config.systemClientID": .behavior,
            "behavior.config.systemPlayerID": .behavior,
            "behavior.config.systemSessionID": .behavior,
            "behavior.definition": .behavior,
            "behavior.logger": .behavior,
            "behavior.payloadDecoders": .behavior,
            "behavior.resolverServices": .behavior,
            "behavior.services": .behavior,
        ]
        // The filled-slot ring exists in debug builds only; a release run expects it absent.
        #if DEBUG
        homes["actor.filledActionSlotsForAssert"] = .model
        homes["actor.filledActionSlotsNextForAssert"] = .model
        homes["actor.filledActionSlotsOrderForAssert"] = .model
        #endif
        return homes
    }()

    static let exceptions: [KeeperCensusException] = [
        // F4: `ContinuousClock.Instant` isn't plain. K2 passes the time in as the turn's input.
        .init(
            fields: ["actor.nextTickDeadline", "actor.pendingFold", "actor.tickLoopConfiguredAt", "actor.tickLoopClock"],
            home: .outside(.loopDriver), why: "F4: instants", endsIn: "K2"
        ),
        // S3 (F8): `runSync` writes these outside a turn, until K2's `.syncDue` step.
        .init(
            fields: ["actor.foldedSyncs", "actor.overdueFoldedSyncs", "actor.inTurnSyncDue"],
            home: .model, why: "S3: written by runSync outside a turn", endsIn: "K2"
        ),
    ]
}

@StateNodeBuilder
struct CensusState: StateNodeProtocol {
    @Sync(.broadcast)
    var n: Int = 0

    public init() {}
}

@Suite("The keeper's census: every stored field has one home (#700 K1b-4)")
struct KeeperCensusTests {
    private func keeper() -> LandKeeper<CensusState> {
        let land = Land("census", using: CensusState.self) {
            Rules {}
        }
        return LandKeeper(definition: land, initialState: CensusState(), autoStartLoops: false)
    }

    @Test("Every stored label has exactly one row, by storage path")
    func everyStoredFieldHasOneHome() async throws {
        let keeper = keeper()
        // Read inside the keeper's isolation: a Mirror's children load their fields lazily.
        let labelsByGroup = await keeper.censusLabelsForTesting()
        #expect(Set(labelsByGroup.keys) == KeeperCensus.groups)
        var stored: [String] = []
        for (group, labels) in labelsByGroup {
            for label in labels where !(group == "actor" && label == "$defaultActor") {
                stored.append("\(group).\(label)")
            }
        }
        let duplicates = Dictionary(grouping: stored, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "labels stored twice: \(duplicates.sorted())")
        #expect(!stored.contains { $0.hasSuffix(".?") }, "an unnamed stored label")
        #expect(!stored.contains { $0.contains(".$") }, "a synthetic label other than the actor's $defaultActor")

        let storedSet = Set(stored)
        let rows = Set(KeeperCensus.homes.keys)
        #expect(storedSet.subtracting(rows).isEmpty, "unplaced: \(storedSet.subtracting(rows).sorted())")
        #expect(rows.subtracting(storedSet).isEmpty, "stale rows: \(rows.subtracting(storedSet).sorted())")
    }

    @Test("Each known exception names fields that are still stored in its home")
    func exceptionsAreCurrent() {
        for exception in KeeperCensus.exceptions {
            for field in exception.fields {
                #expect(KeeperCensus.homes[field] == exception.home, "\(field) (\(exception.why), until \(exception.endsIn))")
            }
        }
    }
}

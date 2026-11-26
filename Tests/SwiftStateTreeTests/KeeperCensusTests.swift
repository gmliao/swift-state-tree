// Tests/SwiftStateTreeTests/KeeperCensusTests.swift
//
// Every stored property of `LandKeeper` has exactly one home (#700 K1b-4): the model
// (`KeeperModel`, plain), the behavior (`KeeperBehavior`, fixed at init), the replay fields, a
// named group that stays on the actor, a later slice that replaces it, or a test hook. A new field
// fails this test until it has a row; a row whose field is gone fails it until it is removed.
// Rows are keyed by storage path (`model.players`, `behavior.config.mode`, `actor.transport`), so
// a field in the wrong container fails too. A lazy field (label `$__lazy_storage_$_x`) fails even
// with a row: stricter than the plan's table, on purpose; the keeper has none, and a new one
// should be placed by hand. A property-wrapped field's label is `_x`, and its row names it so.

import SwiftStateTurns
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
        case bindingToken, recorder, drainFlag, loopDriver, resolverAbandonment, serverInputCap, playerServices, failureTable, turnSide, stepScope
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
    static let groups: Set<String> = ["actor", "model", "behavior", "behavior.config", "replay"]

    /// Every stored property, by storage path, with its home.
    static let homes: [String: KeeperFieldHome] = {
        var homes: [String: KeeperFieldHome] = [
            "actor.abandonmentCounter": .outside(.resolverAbandonment),
            "actor.actionJobRemovalWaiters": .replaced(by: "K2"),
            "actor.actionJobTasks": .replaced(by: "K5"),
            "actor.actionSlotWaiters": .replaced(by: "K2"),
            "actor.actionTableAuditForTesting": .testHook,
            "actor.appliedSyncPhaseOffset": .outside(.loopDriver),
            "actor.appliedTickPhaseOffset": .outside(.loopDriver),
            "actor.behavior": .container,
            "actor.boundSyncRequesterObject": .outside(.bindingToken),
            "actor.debugDrainWaiters": .replaced(by: "K7"),
            "actor.debugHeldInputs": .replaced(by: "K7"),
            "actor.destroyTask": .replaced(by: "K7"),
            "actor.drainFlag": .outside(.drainFlag),
            "actor.drainStartedWaitersForTesting": .replaced(by: "K2"),
            "actor.drainTask": .replaced(by: "K7"),
            "actor.failureWaitersForTesting": .replaced(by: "K2"),
            "actor.failures": .outside(.failureTable),
            "actor.forceShutdownFlight": .replaced(by: "K7"),
            "actor.freezeWaitWatchersForTesting": .replaced(by: "K2"),
            "actor.holds": .testHook,
            "actor.inTurnProbeForTesting": .testHook,
            "actor.inTurnYieldForTesting": .testHook,
            "actor.initializationTask": .replaced(by: "K5"),
            "actor.initializationWaitWatchers": .replaced(by: "K2"),
            "actor.initializationWaits": .replaced(by: "K2"),
            "actor.inputDrainIdleWaitersForTesting": .replaced(by: "K2"),
            "actor.inputTurnWaiters": .replaced(by: "K2"),
            "actor.lateStepOutputAssertsForTesting": .testHook,
            "actor.lateStepOutputs": .outside(.stepScope),
            "actor.destroyHandlerOutputsDropped": .outside(.stepScope),
            "actor.model": .container,
            "actor.nextDrainStartedWaiterForTesting": .replaced(by: "K2"),
            "actor.nextFailureWaiterForTesting": .replaced(by: "K2"),
            "actor.nextRequestedSyncWorkWaiterForTesting": .replaced(by: "K2"),
            "actor.nextTickDeadline": .outside(.loopDriver),
            "actor.outputCollector": .replaced(by: "K2"),
            "actor.pendingFold": .outside(.loopDriver),
            "actor.pendingSyncTurnAfterTurn": .outside(.bindingToken),
            "actor.pendingTransportFailure": .replaced(by: "K4"),
            "actor.playerServices": .outside(.playerServices),
            "actor.recorderSubmissions": .outside(.recorder),
            "actor.releasedTransport": .outside(.bindingToken),
            "actor.replay": .container,
            "actor.requestedSyncWorkWaitersForTesting": .replaced(by: "K2"),
            "actor.serverInputMaxInFlight": .outside(.serverInputCap),
            "actor.shutdownTurnWaiters": .replaced(by: "K2"),
            "actor.slotWatchersForTesting": .replaced(by: "K2"),
            "actor.syncClockForTesting": .testHook,
            "actor.syncTask": .replaced(by: "K2"),
            "actor.tickClockForTesting": .testHook,
            "actor.tickIdleWaiters": .replaced(by: "K2"),
            "actor.tickLoopClock": .outside(.loopDriver),
            "actor.tickLoopConfiguredAt": .outside(.loopDriver),
            "actor.tickTask": .replaced(by: "K2"),
            "actor.transport": .outside(.bindingToken),
            "actor.turnSide": .outside(.turnSide),
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
            // The sentinel's fields live in the class it references (#700 K1b-5 rev 2.3 D13).
            "behavior.reentrySentinel": .behavior,
            "behavior.reevaluationRecorder": .behavior,
            "model.actionJobs": .model,
            "model.actionJobsStarted": .model,
            "model.actionSlots": .model,
            "model.alignmentViolations": .model,
            "model.debugActiveGeneration": .model,
            "model.debugFrozen": .model,
            "model.debugInFlightWork": .model,
            "model.debugNextWaiterID": .model,
            "model.debugReleasedGeneration": .model,
            "model.destroyHandlersStarted": .model,
            "model.destructionFinished": .model,
            "model.didInitialize": .model,
            "model.entryGenerations": .model,
            "model.failureIDs": .model,
            "model.failureTableMisses": .model,
            "model.foldedSyncs": .model,
            "model.hasHeldTransport": .model,
            "model.inTurnDeferredTurns": .model,
            "model.inTurnDrainRetryBinding": .model,
            "model.inTurnSyncDue": .model,
            "model.inTurnSyncTurnKind": .model,
            "model.initializationFailure": .model,
            "model.inputDrainScheduled": .model,
            "model.inputTurnResults": .model,
            "model.inputsSkippedAfterDestroy": .model,
            "model.joinSyncRequestTurnsForTesting": .model,
            "model.joinSyncTicks": .model,
            "model.joinSyncTurnBinding": .model,
            "model.joinSyncTurnsForTesting": .model,
            "model.joinSyncTurnsScheduledForTesting": .model,
            "model.joinSyncWaitsForCommit": .model,
            "model.landRandom": .model,
            "model.lastCommittedTickId": .model,
            "model.lateFoldedSyncs": .model,
            "model.nextTickId": .model,
            "model.overdueFoldedSyncs": .model,
            "model.passInProgress": .model,
            "model.passOrdinal": .model,
            "model.pendingItemScans": .model,
            "model.pendingItems": .model,
            "model.players": .model,
            "model.recorderSubmissionCount": .model,
            "model.rejoinReservationEpochs": .model,
            "model.rejoinReservations": .model,
            "model.requestedSyncTurnsForTesting": .model,
            "model.requestedSyncWork": .model,
            "model.serverInputCapRejections": .model,
            "model.serverInputsHeldWhileFrozen": .model,
            "model.serverInputsInFlight": .model,
            "model.shutdownRequested": .model,
            "model.shutdownTurnApplied": .model,
            "model.state": .model,
            "model.stateHashUnavailableTotal": .model,
            "model.supersededSenderRejections": .model,
            "model.syncBinding": .model,
            "model.syncOutputIndexCursor": .model,
            "model.syncStreamCounter": .model,
            "model.ticklessJobTurns": .model,
            "model.ticklessJobWork": .model,
            "model.ticksInFlight": .model,
            "model.transportRecordsFolds": .model,
            "replay.recordedPassMismatches": .replay,
            "replay.reevaluationSink": .replay,
            "replay.reevaluationSource": .replay,
            "replay.replayFailureEnd": .replay,
            "replay.replayHeaderPayloadEncoding": .replay,
            "replay.replayPassObserver": .replay,
            "replay.replayRecordsPassOrdinals": .replay,
            "replay.replayRecordsRejected": .replay,
            "replay.replayRejected": .replay,
            "replay.replayedInitializeBeforeTickZero": .replay,
            "replay.replayedInitializeRefusal": .replay,
        ]
        // The filled-slot ring exists in debug builds only; a release run expects it absent.
        #if DEBUG
        homes["model.filledActionSlotsForAssert"] = .model
        homes["model.filledActionSlotsNextForAssert"] = .model
        homes["model.filledActionSlotsOrderForAssert"] = .model
        #endif
        return homes
    }()

    static let exceptions: [KeeperCensusException] = [
        // F4: `ContinuousClock.Instant` isn't plain. K2 passes the time in as the turn's input.
        .init(
            fields: ["actor.nextTickDeadline", "actor.pendingFold", "actor.tickLoopConfiguredAt", "actor.tickLoopClock"],
            home: .outside(.loopDriver), why: "F4: instants", endsIn: "K2"
        ),
        // D13: the behavior holds one reference with mutable state, the re-entry sentinel, used on
        // the keeper's executor only. K2 draft 7 keeps it there; #773's behavior lint allows it.
        .init(
            fields: ["behavior.reentrySentinel"],
            home: .behavior, why: "D13: the re-entry sentinel, a reference", endsIn: "#773"
        ),
        // S3 (F8): `runSync` writes these outside a turn, until K2's `.syncDue` step.
        .init(
            fields: ["model.foldedSyncs", "model.overdueFoldedSyncs", "model.inTurnSyncDue"],
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
        // A label stored in two places (`actor.x` beside `model.x`) is one field with two homes.
        let bareLabel = { (path: String) in String(path.split(separator: ".").last!) }
        let duplicates = Dictionary(grouping: stored, by: bareLabel).filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty, "labels stored twice: \(duplicates.values.map { $0.sorted() })")
        #expect(!stored.contains { $0.hasSuffix(".?") }, "an unnamed stored label")
        #expect(!stored.contains { $0.contains(".$") }, "a synthetic label other than the actor's $defaultActor")

        let storedSet = Set(stored)
        let rows = Set(KeeperCensus.homes.keys)
        #expect(storedSet.subtracting(rows).isEmpty, "unplaced: \(storedSet.subtracting(rows).sorted())")
        #expect(rows.subtracting(storedSet).isEmpty, "stale rows: \(rows.subtracting(storedSet).sorted())")
    }

    @Test("Each row's home matches the container its path names")
    func homesMatchPaths() {
        for (path, home) in KeeperCensus.homes {
            let container = path.hasPrefix("behavior.config.") ? "behavior.config" : String(path.prefix { $0 != "." })
            switch (container, home) {
            case ("model", .model), ("behavior", .behavior), ("behavior.config", .behavior), ("replay", .replay):
                continue
            case ("behavior", .container) where path == "behavior.config":
                continue
            case ("actor", .model), ("actor", .behavior), ("actor", .replay):
                Issue.record("\(path): a \(home) field still on the actor")
            case ("actor", _):
                continue
            default:
                Issue.record("\(path): home \(home) doesn't match its container")
            }
        }
    }

    @Test("Each known exception names fields that are still stored in its home")
    func exceptionsAreCurrent() {
        for exception in KeeperCensus.exceptions {
            for field in exception.fields {
                #expect(KeeperCensus.homes[field] == exception.home, "\(field) (\(exception.why), until \(exception.endsIn))")
            }
        }
    }

    @Test("The model is plain at compile time")
    func modelIsPlain() {
        // Compiles only while `KeeperModel` is `@PlainData` and every field it holds is plain.
        requirePlain(KeeperModel<CensusState>.self)
    }
}

/// Compiles only when `T` is `PlainData`.
private func requirePlain<T: PlainData>(_: T.Type) {}

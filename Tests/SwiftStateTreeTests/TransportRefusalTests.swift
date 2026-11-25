// Tests/SwiftStateTreeTests/TransportRefusalTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

/// Doesn't opt in: `runsSyncPhaseInTurn` answers false (it has no default since #546 L2d-3).
private actor NonOptingPort: LandKeeperTransport {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    nonisolated func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { false }
    nonisolated func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S, events: [InTurnServerEvent], includeSync: Bool, recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(.unsupported)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

/// Opts in for one keeper only, as the adapter does (identity): attached to any other keeper it
/// answers false. The adapter's own twin is in TransportAdapterInTurnSyncTests.
private final class OneKeeperPort: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private weak var ownerObject: AnyObject?
    var owner: AnyObject? {
        get { lock.withLock { ownerObject } }
        set { lock.withLock { ownerObject = newValue } }
    }
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { keeper === owner }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S, events: [InTurnServerEvent], includeSync: Bool, recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private let refusalMessage = "a live keeper's transport must run its sync phase in turn"

private func standardError(_ result: ExitTest.Result?) -> String {
    guard let result else { return "" }
    return String(decoding: result.standardErrorContent, as: UTF8.self)
}

/// Each case runs in a child process (an exit test), as RuntimeStopTests does: a refused one must
/// fail with the keeper's message on its standard error; an exempt one must exit normally.
@Suite("A live keeper refuses a transport that can't run its sync phase in turn (#546 L2d)", .timeLimit(.minutes(1)))
struct TransportRefusalTests {
    // Refused: the child stops with the message, in every build (`fatalError`).

    @Test("init(transport:) with a transport that doesn't opt in stops the process")
    func initRefusesNonOpting() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: false),
                initialState: RoutingPinState(),
                autoStartLoops: false,
                transport: NonOptingPort()
            )
        }
        #expect(standardError(result).contains(refusalMessage))
        #expect(standardError(result).contains("NonOptingPort"))
    }

    // An exit test's body can't capture a test argument (Swift 6.2), so each land kind has its own.

    @Test("setTransport with a transport that doesn't opt in stops the process: tickless land")
    func setTransportRefusesNonOptingTickless() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: false), initialState: RoutingPinState(), autoStartLoops: false
            )
            await keeper.setTransport(NonOptingPort())
        }
        #expect(standardError(result).contains(refusalMessage))
    }

    @Test("setTransport with a transport that doesn't opt in stops the process: tick land")
    func setTransportRefusesNonOptingTick() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: true), initialState: RoutingPinState(), autoStartLoops: false
            )
            await keeper.setTransport(NonOptingPort())
        }
        #expect(standardError(result).contains(refusalMessage))
    }

    @Test("setTransport with a port that opts in only for another keeper stops the process")
    func setTransportRefusesOtherKeepersPort() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let definition = makeRoutingPinLand(tick: false)
            let a = LandKeeper<RoutingPinState>(definition: definition, initialState: RoutingPinState(), autoStartLoops: false)
            let b = LandKeeper<RoutingPinState>(definition: definition, initialState: RoutingPinState(), autoStartLoops: false)
            let port = OneKeeperPort()
            port.owner = a
            await a.setTransport(port)      // its own keeper: accepted
            FileHandle.standardError.write(Data("OWN-KEEPER-ACCEPTED\n".utf8))
            await b.setTransport(port)      // another keeper: refused
        }
        #expect(standardError(result).contains("OWN-KEEPER-ACCEPTED"))
        #expect(standardError(result).contains(refusalMessage))
    }

    @Test("A transport refused at init stops the process before OnInitialize runs")
    func initRefusalBeforeInitialization() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let land = Land("refusal-marker", using: RoutingPinState.self) {
                Lifetime {
                    OnInitialize { _, _ in
                        FileHandle.standardError.write(Data("ON-INITIALIZE-RAN\n".utf8))
                    }
                }
            }
            let keeper = LandKeeper<RoutingPinState>(definition: land, initialState: RoutingPinState(), transport: NonOptingPort())
            await keeper.awaitInitialization()
        }
        #expect(standardError(result).contains(refusalMessage))
        #expect(!standardError(result).contains("ON-INITIALIZE-RAN"))
    }

    // Exempt and accepted: the child exits normally. Exit tests too, so a wrong stop fails one
    // test instead of the run.

    @Test("Exempt: no transport, at init and through setTransport, on a live keeper")
    func nilIsExempt() async {
        await #expect(processExitsWith: .success) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: true), initialState: RoutingPinState(), autoStartLoops: false, transport: nil
            )
            await keeper.setTransport(nil)
            await keeper.stepTickOnce()
        }
    }

    @Test("Exempt: a re-evaluation keeper takes a transport that doesn't opt in, at init and later")
    func reevaluationIsExempt() async {
        await #expect(processExitsWith: .success) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: true), initialState: RoutingPinState(),
                mode: .reevaluation, autoStartLoops: false, transport: NonOptingPort()
            )
            await keeper.setTransport(NonOptingPort())
        }
    }

    @Test("Exempt: after the destruction, setTransport keeps the released placeholder and isn't checked")
    func afterDestructionIsExempt() async {
        await #expect(processExitsWith: .success) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: false), initialState: RoutingPinState(), autoStartLoops: false
            )
            await keeper.forceShutdown()
            await keeper.waitUntilDrained()
            // A late attach (#346's half-wired instance) is not checked and doesn't replace the
            // placeholder the destruction installed.
            await keeper.setTransport(NonOptingPort())
            guard await keeper.transportForTesting is ReleasedLandTransport else { exit(3) }
        }
    }

    @Test("Accepted: a port that opts in for this keeper, at init and through setTransport")
    func optingInIsAccepted() async {
        await #expect(processExitsWith: .success) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: false), initialState: RoutingPinState(),
                autoStartLoops: false, transport: RoutingPinPort()
            )
            await keeper.setTransport(RoutingPinPort())
            guard await keeper.isUsingInTurnSync() else { exit(3) }
        }
    }
}

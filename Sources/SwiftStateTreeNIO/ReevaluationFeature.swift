import Foundation
import SwiftStateTree
import SwiftStateTreeReevaluationMonitor
import SwiftStateTreeTransport

public struct ReevaluationFeatureConfiguration: Sendable {
    public var enabled: Bool
    public var replayEventPolicy: ReevaluationReplayEventPolicy
    public var replayLandSuffix: String
    public var monitorLandType: String
    public var monitorWebSocketPath: String
    public var replayWebSocketPathResolver: @Sendable (String) -> String
    /// The run length limit the admin replay start checks a record against (#728). Set it to the
    /// `maxReplayTicks` of the `ReevaluationRunnerService` that `runnerServiceFactory` makes (and
    /// of the runners its factory builds): a record the admin start accepts is then one the run
    /// accepts. A mismatch is safe, not silent: a limit below the service's refuses a record the
    /// run would take, and a limit above it lets the run fail with `replayTooLong`.
    ///
    /// The reevaluation monitor land is registered once, by the first `registerWithGenericReplay`
    /// call, with that call's configuration, so its runs use that registration's service and
    /// limit. `/admin/reevaluation/start` checks a record against the limit of the land type in
    /// the request: with lands at different limits, a record accepted for the higher one can still
    /// fail in the monitor with `replayTooLong` (typed, not silent). Lands that share a monitor
    /// should share a limit when the monitor route has to honor it.
    ///
    /// `NIOAdminRoutes` takes a snapshot of these limits when `registerAdminRoutes()` runs
    /// (`NIOLandHost.run` does so after the registrations): a land registered after that keeps
    /// the default limit for the admin start.
    public var maxReplayTicks: Int64
    public var runnerServiceFactory: @Sendable () -> ReevaluationRunnerService

    public init(
        enabled: Bool,
        replayEventPolicy: ReevaluationReplayEventPolicy = .projectedOnly,
        replayLandSuffix: String = "-replay",
        monitorLandType: String = "reevaluation-monitor",
        monitorWebSocketPath: String = "/reevaluation-monitor",
        replayWebSocketPathResolver: @escaping @Sendable (String) -> String = { replayLandType in
            "/game/\(replayLandType)"
        },
        maxReplayTicks: Int64 = ReevaluationRecordFile.defaultMaxReplayTicks,
        runnerServiceFactory: @escaping @Sendable () -> ReevaluationRunnerService
    ) {
        precondition(maxReplayTicks >= 1, "maxReplayTicks must be at least 1")
        self.maxReplayTicks = maxReplayTicks
        self.enabled = enabled
        self.replayEventPolicy = replayEventPolicy
        self.replayLandSuffix = replayLandSuffix
        self.monitorLandType = monitorLandType
        self.monitorWebSocketPath = monitorWebSocketPath
        self.replayWebSocketPathResolver = replayWebSocketPathResolver
        self.runnerServiceFactory = runnerServiceFactory
    }
}

// MARK: - Generic Replay Registration

public extension NIOLandHost {
    /// Registers a live land and a corresponding generic replay land.
    ///
    /// The replay land is `GenericReplayLand<State>.makeLand(basedOn:)`, a live land.
    /// The replay land decodes each tick's state from the `ReevaluationRunnerService`
    /// result queue via `State.init(fromBroadcastSnapshot:)` — no manual `Decodable`
    /// conformance is required for game state types.
    ///
    /// The replay land type is `"\(landType)\(reevaluation.replayLandSuffix)"`
    /// (default: `"\(landType)-replay"`).
    ///
    /// - Parameters:
    ///   - landType: Base land type (e.g. "hero-defense"); replay will be
    ///     `"\(landType)\(reevaluation.replayLandSuffix)"`.
    ///   - liveLand: The live land definition.  The same definition is passed to
    ///     `GenericReplayLand.makeLand(basedOn:)` to build the replay land.
    ///   - liveInitialState: Initial state for live sessions.
    ///   - liveWebSocketPath: WebSocket path for live connections.
    ///   - configuration: Server configuration shared by live and replay lands.
    ///   - reevaluation: Reevaluation feature configuration (runner factory, suffix, …).
    func registerWithGenericReplay<State: StateFromSnapshotDecodable>(
        landType: String,
        liveLand: LandDefinition<State>,
        liveInitialState: @autoclosure @escaping @Sendable () -> State,
        liveWebSocketPath: String,
        configuration: NIOLandServerConfiguration,
        reevaluation: ReevaluationFeatureConfiguration
    ) async throws {
        let effectiveConfiguration: NIOLandServerConfiguration
        if reevaluation.enabled {
            effectiveConfiguration = configuration.injectingReevaluationServices(
                runnerServiceFactory: reevaluation.runnerServiceFactory,
                replayEventPolicy: reevaluation.replayEventPolicy
            )
            // The definition is replayed, so it must have a record schema fingerprint (#521 D15);
            // its other rows are checked in the same throw.
            try liveLand.validateForRegistration(context: effectiveConfiguration.replayedDefinitionContext)
        } else {
            effectiveConfiguration = configuration
        }

        let replay: (
            landType: String, webSocketPath: String, configuration: NIOLandServerConfiguration,
            land: LandDefinition<State>
        )?
        if reevaluation.enabled {
            let replayLandType = "\(landType)\(reevaluation.replayLandSuffix)"
            let recordsDir = NIOEnvConfig.fromEnvironment().reevaluationRecordsDir
            var replayConfig = effectiveConfiguration
                .injectingGenericReplayRunnerBootstrap(
                    replayLandType: replayLandType,
                    liveLandType: landType,
                    recordsDir: recordsDir,
                    replayLandState: State.self
                )
                .injectingGenericReplayKeeperModeResolver(
                    replayLandType: replayLandType,
                    recordsDir: recordsDir
                )
            replayConfig.replayLandSuffix = reevaluation.replayLandSuffix
            // Built once, from the live definition alone, and checked before the live land
            // registers with the context its own registration uses: a refusal then publishes no
            // route (#521 PR 1b-2b). The alias drops the server inputs. Its fingerprint walk used to
            // find a wire-key collision that a same-named server input hid in the base's walk;
            // since #602 the base refuses the two types under one name itself, and no row is known
            // to fail for the alias where the base passes. The check stays as the alias's own
            // registration, run before any route is published.
            let replayLand = GenericReplayLand<State>.makeLand(basedOn: liveLand)
            try replayLand.validateForRegistration(context: replayConfig.registrationContext)
            replay = (replayLandType, reevaluation.replayWebSocketPathResolver(replayLandType), replayConfig, replayLand)
        } else {
            replay = nil
        }

        try await register(
            landType: landType,
            land: liveLand,
            initialState: liveInitialState(),
            webSocketPath: liveWebSocketPath,
            configuration: effectiveConfiguration
        )

        guard let replay else {
            return
        }

        replayLandSuffix = reevaluation.replayLandSuffix
        maxReplayTicksByLandType[landType] = reevaluation.maxReplayTicks

        try await register(
            landType: replay.landType,
            land: replay.land,
            initialState: liveInitialState(),
            webSocketPath: replay.webSocketPath,
            configuration: replay.configuration
        )

        if await realm.isRegistered(landType: reevaluation.monitorLandType) == false {
            try await register(
                landType: reevaluation.monitorLandType,
                land: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                webSocketPath: reevaluation.monitorWebSocketPath,
                configuration: try effectiveConfiguration.monitorLandConfiguration(
                    monitorLandType: reevaluation.monitorLandType,
                    recordsDir: NIOEnvConfig.fromEnvironment().reevaluationRecordsDir
                )
            )
        }
    }
}

/// The record path a replay land may be created for: its instance ID must be a ticket from
/// `ticketSigner` (#366), unexpired when `requireUnexpired`, and the path it names must be inside
/// `recordsDir`. `nil` for anything else; a refusal is counted in `ReplayTicketRejections`.
///
/// The expiry is decided once per creation, by the keeper-mode resolver (`LandManager` asks it
/// before it builds the land's services). The runner bootstrap, which runs only after the
/// resolver accepted the land, checks the MAC and the path only.
func verifiedReplayDescriptor(
    landID: LandID,
    replayLandType: String,
    recordsDir: String,
    ticketSigner: ReplayTicketSigner,
    requireUnexpired: Bool
) -> ReevaluationReplaySessionDescriptor? {
    switch ticketSigner.verify(instanceId: landID.instanceId, replayLandType: replayLandType) {
    case .valid:
        break
    case .expired where !requireUnexpired:
        break
    case let verdict:
        ReplayTicketRejections.shared.record(verdict, landID: landID)
        return nil
    }
    // The containment check stays, as a second line behind the ticket.
    return ReevaluationReplaySessionDescriptor.decode(
        instanceId: landID.instanceId,
        landType: replayLandType,
        recordsDir: recordsDir
    )
}

func resolveGenericReplayKeeperMode(
    landID: LandID,
    replayLandType: String,
    recordsDir: String,
    ticketSigner: ReplayTicketSigner = .process
) -> LandKeeperModeConfig? {
    guard landID.landType == replayLandType else { return nil }
    guard verifiedReplayDescriptor(
        landID: landID,
        replayLandType: replayLandType,
        recordsDir: recordsDir,
        ticketSigner: ticketSigner,
        requireUnexpired: true
    ) != nil else {
        return .invalidReplaySession(message: "Invalid replay session descriptor for instanceId")
    }
    return .live
}

/// A keeper-mode resolver that checks the replay ticket before anything else answers for the
/// replay land type (#366): an invalid or expired ticket is refused even when `previous` would
/// have given a mode, so no earlier resolver lets a land around the ticket. For an accepted
/// replay land, `previous` still decides first, then `accepted`. Other land types go to
/// `previous` only. This is the one expiry decision of a creation; the runner bootstrap,
/// which runs after it, checks the MAC and the path only.
func replayTicketGatedResolver(
    previous: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)?,
    replayLandType: String,
    recordsDir: String,
    ticketSigner: ReplayTicketSigner,
    accepted: @escaping @Sendable (ReevaluationReplaySessionDescriptor) -> LandKeeperModeConfig?
) -> @Sendable (LandID, [String: String]) -> LandKeeperModeConfig? {
    { landID, metadata in
        guard landID.landType == replayLandType else {
            return previous?(landID, metadata)
        }
        guard let descriptor = verifiedReplayDescriptor(
            landID: landID,
            replayLandType: replayLandType,
            recordsDir: recordsDir,
            ticketSigner: ticketSigner,
            requireUnexpired: true
        ) else {
            return .invalidReplaySession(message: "Invalid replay session descriptor for instanceId")
        }
        if let mode = previous?(landID, metadata) {
            return mode
        }
        return accepted(descriptor)
    }
}

/// The run a reevaluation monitor land may be created for: its instance ID must be a monitor
/// ticket from `ticketSigner` for `monitorLandType` (#366), unexpired when `requireUnexpired`,
/// and the record path it binds must be within `recordsDir`. `nil` for anything else; a refusal
/// is counted in `ReplayTicketRejections`.
func verifiedMonitorRun(
    landID: LandID,
    monitorLandType: String,
    recordsDir: String,
    ticketSigner: ReplayTicketSigner,
    requireUnexpired: Bool
) -> ReevaluationMonitorRun? {
    let inspection = ticketSigner.inspect(instanceId: landID.instanceId, kind: .monitor, landType: monitorLandType)
    switch inspection {
    case .valid:
        break
    case .expired where !requireUnexpired:
        break
    default:
        ReplayTicketRejections.shared.record(inspection.verdict, landID: landID)
        return nil
    }
    // The containment check stays, as a second line behind the ticket.
    guard let fields = inspection.fields,
          let liveLandType = fields.liveLandType,
          let path = decodeBase64URLString(fields.pathToken),
          let resolved = resolveReevaluationRecordPath(rawPath: path, recordsDir: recordsDir)
    else { return nil }
    return ReevaluationMonitorRun(landType: liveLandType, recordFilePath: resolved.path)
}

private func decodeBase64URLString(_ token: String) -> String? {
    let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    let padded = remainder > 0 ? base64 + String(repeating: "=", count: 4 - remainder) : base64
    guard let data = Data(base64Encoded: padded), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
        return nil
    }
    return text
}

extension NIOLandServerConfiguration {
    /// The configuration the reevaluation monitor land is registered with: this (the live
    /// land's) configuration, with the monitor's own path and event hashes in place of the live
    /// land's (the monitor's state and events differ, so with the live land's every patch would
    /// be dropped as outside the schema), gated on a monitor ticket (`injectingMonitorTicket`).
    /// The monitor land is never recorded: its tick reads the runner service, so a record of it
    /// couldn't replay, and it isn't a game to verify.
    func monitorLandConfiguration(
        monitorLandType: String,
        recordsDir: String,
        ticketSigner: ReplayTicketSigner = .process
    ) throws -> NIOLandServerConfiguration {
        var updated = injectingMonitorTicket(
            monitorLandType: monitorLandType, recordsDir: recordsDir, ticketSigner: ticketSigner
        )
        updated.enableLiveStateHashRecording = false
        if pathHashes != nil || eventHashes != nil || clientEventHashes != nil {
            let land = ReevaluationMonitor.makeLand()
            let schema = try SchemaExtractor.extract(from: land).lands[land.id]
            if pathHashes != nil { updated.pathHashes = schema?.pathHashes }
            if eventHashes != nil { updated.eventHashes = schema?.eventHashes }
            if clientEventHashes != nil { updated.clientEventHashes = schema?.clientEventHashes }
        }
        return updated
    }

    /// Gates the reevaluation monitor land type on a monitor ticket and starts its run (#366).
    /// - The keeper-mode resolver refuses a monitor land whose ID isn't a valid, unexpired monitor
    ///   ticket, before any service is built (the one expiry decision of a creation); an
    ///   accepted land keeps its mode.
    /// - The services factory, which then runs once for the land, puts the ticket's run in the
    ///   services (`ReevaluationMonitorRun`), after the ticket and containment checks, and starts
    ///   the runner service's driver. It checks the MAC and the path only. The monitor land
    ///   requests the run in its first join's turn (`ReevaluationMonitor`), so the run's tick
    ///   events have a viewer from the first tick.
    func injectingMonitorTicket(
        monitorLandType: String,
        recordsDir: String,
        ticketSigner: ReplayTicketSigner = .process
    ) -> NIOLandServerConfiguration {
        var updated = self
        let previousResolver = self.keeperModeResolver
        updated.keeperModeResolver = { landID, metadata in
            guard landID.landType == monitorLandType else {
                return previousResolver?(landID, metadata)
            }
            guard verifiedMonitorRun(
                landID: landID,
                monitorLandType: monitorLandType,
                recordsDir: recordsDir,
                ticketSigner: ticketSigner,
                requireUnexpired: true
            ) != nil else {
                return .invalidReplaySession(message: "Invalid reevaluation monitor ticket for instanceId")
            }
            return previousResolver?(landID, metadata)
        }
        let baseFactory = self.servicesFactory
        updated.servicesFactory = { landID, metadata in
            var services = baseFactory(landID, metadata)
            guard landID.landType == monitorLandType,
                  let run = verifiedMonitorRun(
                      landID: landID,
                      monitorLandType: monitorLandType,
                      recordsDir: recordsDir,
                      ticketSigner: ticketSigner,
                      requireUnexpired: false
                  )
            else { return services }
            services.register(run, as: ReevaluationMonitorRun.self)
            // The driver runs the verifications the land's turns request; land creation is
            // outside any turn, so it starts here.
            services.get(ReevaluationRunnerService.self)?.startDriver()
            return services
        }
        return updated
    }

    func injectingReevaluationServices(
        runnerServiceFactory: @escaping @Sendable () -> ReevaluationRunnerService,
        replayEventPolicy: ReevaluationReplayEventPolicy
    ) -> NIOLandServerConfiguration {
        var updated = self
        let baseFactory = self.servicesFactory
        updated.servicesFactory = { landID, metadata in
            var services = baseFactory(landID, metadata)
            if services.get(ReevaluationRunnerService.self) == nil {
                services.register(runnerServiceFactory(), as: ReevaluationRunnerService.self)
            }
            if services.get(ReevaluationReplayPolicyService.self) == nil {
                services.register(
                    ReevaluationReplayPolicyService(eventPolicy: replayEventPolicy),
                    as: ReevaluationReplayPolicyService.self
                )
            }
            return services
        }
        return updated
    }

    func injectingGenericReplayKeeperModeResolver(
        replayLandType: String,
        recordsDir: String,
        ticketSigner: ReplayTicketSigner = .process
    ) -> NIOLandServerConfiguration {
        var updated = self
        updated.keeperModeResolver = replayTicketGatedResolver(
            previous: self.keeperModeResolver,
            replayLandType: replayLandType,
            recordsDir: recordsDir,
            ticketSigner: ticketSigner,
            accepted: { _ in .live }
        )
        return updated
    }

    /// - Parameter replayLandState: the state type of a replay land that shows the runner's
    ///   results (`GenericReplayLand`): the service then queues only results resolved for it.
    ///   Nil when nothing reads the results (tests of the ticket gate).
    func injectingGenericReplayRunnerBootstrap(
        replayLandType: String,
        liveLandType: String,
        recordsDir: String,
        replayLandState: (any StateNodeProtocol.Type)? = nil,
        ticketSigner: ReplayTicketSigner = .process
    ) -> NIOLandServerConfiguration {
        var updated = self
        let baseFactory = self.servicesFactory
        let captureReplayLandType = replayLandType
        let captureLiveLandType = liveLandType
        let captureRecordsDir = recordsDir

        updated.servicesFactory = { landID, metadata in
            let services = baseFactory(landID, metadata)

            guard landID.landType == captureReplayLandType else {
                return services
            }

            // Called only when the land is created, after the keeper-mode resolver accepted it
            // (its expiry decision stands); a ticket whose MAC doesn't verify starts no runner.
            guard let descriptor = verifiedReplayDescriptor(
                landID: landID,
                replayLandType: captureReplayLandType,
                recordsDir: captureRecordsDir,
                ticketSigner: ticketSigner,
                requireUnexpired: false
            ) else {
                return services
            }

            guard let runnerService = services.get(ReevaluationRunnerService.self) else {
                return services
            }

            if let replayLandState {
                runnerService.expectReplayLandState(replayLandState)
            }
            if runnerService.getStatus().phase == .idle {
                runnerService.startVerification(
                    landType: captureLiveLandType,
                    recordFilePath: descriptor.recordFilePath
                )
            }

            return services
        }
        return updated
    }
}

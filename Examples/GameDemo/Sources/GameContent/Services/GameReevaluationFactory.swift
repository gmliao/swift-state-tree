import Foundation
import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

public struct GameReevaluationFactory: ReevaluationTargetFactory {
    public init() {}

    public func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        switch landType {
        case "hero-defense":
            // Create services with GameConfig
            var services = LandServices()
            services.register(
                GameConfigProviderService(provider: DefaultGameConfigProvider.fromEnvironment()),
                as: GameConfigProviderService.self
            )

            // Create runner for HeroDefense
            return try await ConcreteReevaluationRunner(
                definition: HeroDefense.makeLand(),
                initialState: HeroDefenseState(),
                recordFilePath: recordFilePath,
                services: services
            )
        case VisibilityTestConfig.landType:
            // The land's knobs come from this process's environment: refuse a record made with
            // other ones rather than report a mismatch that isn't one.
            let metadata = try await ReevaluationRecordFile.openSource(filePath: recordFilePath).getMetadata()
            if let mismatch = VisibilityTestSettings.current.recordMismatch(metadata.metadata) {
                throw VisibilityTestSettingsError(description: "Replay refused: \(mismatch)")
            }
            if VisibilityTestSettings.current.filter == .broadcast {
                return try await ConcreteReevaluationRunner(
                    definition: VisibilityTest.makeLand(VisibilityTestBroadcastState.self),
                    initialState: VisibilityTestBroadcastState(),
                    recordFilePath: recordFilePath,
                    services: LandServices()
                )
            }
            return try await ConcreteReevaluationRunner(
                definition: VisibilityTest.makeLand(),
                initialState: VisibilityTestState(),
                recordFilePath: recordFilePath,
                services: LandServices()
            )
        case ResolverTestConfig.landType:
            // Replay applies the recorded resolver outputs and never calls the service.
            return try await ConcreteReevaluationRunner(
                definition: ResolverTest.makeLand(),
                initialState: ResolverTestState(),
                recordFilePath: recordFilePath,
                services: LandServices()
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}

public enum ReevaluationError: Error {
    case unknownLandType(String)
}

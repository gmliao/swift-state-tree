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
                GameConfigProviderService(provider: DefaultGameConfigProvider()),
                as: GameConfigProviderService.self
            )

            // Create runner for HeroDefense
            return try await ConcreteReevaluationRunner(
                definition: HeroDefense.makeLand(),
                initialState: HeroDefenseState(),
                recordFilePath: recordFilePath,
                services: services
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}

public enum ReevaluationError: Error {
    case unknownLandType(String)
}

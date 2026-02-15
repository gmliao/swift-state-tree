import Foundation
import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
public struct HeroDefenseReplayState: StateNodeProtocol {
    @Sync(.broadcast)
    var status: String = "idle"

    @Sync(.broadcast)
    var currentTickId: Int64 = 0

    @Sync(.broadcast)
    var totalTicks: Int = 0

    @Sync(.broadcast)
    var currentStateJSON: String = ""

    @Sync(.broadcast)
    var players: [String: AnyCodable] = [:]

    @Sync(.broadcast)
    var monsters: [String: AnyCodable] = [:]

    @Sync(.broadcast)
    var turrets: [String: AnyCodable] = [:]

    @Sync(.broadcast)
    var base: [String: AnyCodable] = [:]

    @Sync(.broadcast)
    var score: Int = 0

    @Sync(.broadcast)
    var errorMessage: String = ""

    public init() {}
}

@Payload
public struct HeroDefenseReplayTickEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

public enum HeroDefenseReplay {
    public static func makeLand() -> LandDefinition<HeroDefenseReplayState> {
        Land("hero-defense-replay", using: HeroDefenseReplayState.self) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(64)
            }

            Lifetime {
                Tick(every: .milliseconds(50)) { (state: inout HeroDefenseReplayState, ctx: LandContext) in
                    guard let service = ctx.services.get(ReevaluationRunnerService.self) else {
                        return
                    }

                    let status = service.getStatus()
                    state.totalTicks = Int(status.totalTicks)
                    state.errorMessage = status.errorMessage

                    if status.phase == .idle {
                        guard let recordFilePath = resolveReplayRecordPath(from: ctx.landID) else {
                            service.startVerification(
                                landType: "hero-defense",
                                recordFilePath: "__invalid_replay_record_path__"
                            )
                            return
                        }

                        service.startVerification(
                            landType: "hero-defense",
                            recordFilePath: recordFilePath
                        )
                        return
                    }

                    if let result = service.consumeNextResult() {
                        if status.phase == .failed {
                            state.status = ReevaluationStatus.Phase.failed.rawValue
                        } else {
                            state.status = ReevaluationStatus.Phase.verifying.rawValue
                        }
                        state.currentTickId = result.tickId

                        if let projectedFrame = result.projectedFrame {
                            applyProjectedState(projectedFrame.stateObject, to: &state)
                        }

                        if state.currentStateJSON.isEmpty,
                           let jsonText = result.actualState?.base as? String {
                            state.currentStateJSON = jsonText
                        }

                        let event = HeroDefenseReplayTickEvent(
                            tickId: result.tickId,
                            isMatch: result.isMatch,
                            expectedHash: result.recordedHash ?? "?",
                            actualHash: result.stateHash
                        )
                        ctx.emitEvent(event, to: .all)
                    } else {
                        state.status = status.phase.rawValue
                        state.currentTickId = status.currentTick
                    }
                }
            }

            ServerEvents {
                Register(HeroDefenseReplayTickEvent.self)
            }
        }
    }
}

private func applyProjectedState(
    _ projectedState: [String: AnyCodable],
    to state: inout HeroDefenseReplayState
) {
    if let players = projectedState["players"] {
        state.players = dictionaryValue(from: players)
    }
    if let monsters = projectedState["monsters"] {
        state.monsters = dictionaryValue(from: monsters)
    }
    if let turrets = projectedState["turrets"] {
        state.turrets = dictionaryValue(from: turrets)
    }
    if let base = projectedState["base"] {
        state.base = dictionaryValue(from: base)
    }
    if let scoreValue = projectedState["score"]?.base as? Int {
        state.score = scoreValue
    } else if let scoreValue = projectedState["score"]?.base as? Double {
        state.score = Int(scoreValue)
    } else if let scoreValue = projectedState["score"]?.base as? NSNumber {
        state.score = scoreValue.intValue
    } else if let scoreValue = projectedState["score"]?.base as? String,
              let parsed = Int(scoreValue) {
        state.score = parsed
    } else if projectedState["score"] != nil {
        // Keep current score when projected value cannot be parsed.
    }
}

private func dictionaryValue(from value: AnyCodable) -> [String: AnyCodable] {
    guard let dictionary = value.base as? [String: Any] else {
        return [:]
    }
    return dictionary.mapValues(AnyCodable.init)
}

private func resolveReplayRecordPath(from landIDString: String) -> String? {
    let landID = LandID(landIDString)
    let parts = landID.instanceId.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else {
        return nil
    }

    let token = String(parts[1])
    guard let rawPathData = decodeBase64URL(token),
          let rawPath = String(data: rawPathData, encoding: .utf8)
    else {
        return nil
    }

    let currentDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let recordsDir = ReevaluationEnvConfig.fromEnvironment().recordsDir
    let recordsDirURL = URL(fileURLWithPath: recordsDir, relativeTo: currentDirURL).standardizedFileURL
    let candidateURL = URL(fileURLWithPath: rawPath).standardizedFileURL

    guard isWithinDirectory(candidateURL, directoryURL: recordsDirURL) else {
        return nil
    }

    guard FileManager.default.fileExists(atPath: candidateURL.path) else {
        return nil
    }

    return candidateURL.path
}

private func decodeBase64URL(_ token: String) -> Data? {
    var base64 = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    let remainder = base64.count % 4
    if remainder != 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }

    return Data(base64Encoded: base64)
}

private func isWithinDirectory(_ fileURL: URL, directoryURL: URL) -> Bool {
    if fileURL.path == directoryURL.path {
        return true
    }

    let directoryPath = directoryURL.path.hasSuffix("/") ? directoryURL.path : "\(directoryURL.path)/"
    return fileURL.path.hasPrefix(directoryPath)
}

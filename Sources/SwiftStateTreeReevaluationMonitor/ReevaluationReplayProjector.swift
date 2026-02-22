import Foundation
import SwiftStateTree

public enum ReevaluationReplayProjectorRegistry {
    public static func defaultResolver(for landType: String) -> (any ReevaluationReplayProjecting)? {
        return nil
    }
}

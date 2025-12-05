import SwiftStateTree
import HummingbirdDemoContent

// MARK: - Land Definition

// Re-export the demo game from HummingbirdDemoContent
public enum DemoGame {
    public static func makeLand() -> LandDefinition<DemoGameState> {
        HummingbirdDemoContent.DemoGame.makeLand()
    }
}

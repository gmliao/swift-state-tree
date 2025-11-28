import SwiftStateTreeHummingbirdDemoContent
import SwiftStateTreeHummingbirdHosting

@main
struct HummingbirdDemo {
    static func main() async throws {
        typealias DemoAppContainer = AppContainer<DemoGameState, DemoClientEvents, DemoServerEvents>
        let container = try await DemoAppContainer.makeServer(
            land: DemoGame.makeLand(),
            initialState: DemoGameState()
        )
        try await container.run()
    }
}


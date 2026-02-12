import Foundation

let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
let server = StubServer()
try await server.run(port: port)

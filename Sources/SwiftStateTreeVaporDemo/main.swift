// Sources/SwiftStateTreeVaporDemo/main.swift

import Vapor
import SwiftStateTree

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)

try configure(app)
try await app.execute()


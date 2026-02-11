// Sources/SwiftStateTreeNIO/NIOEnvKeys.swift
//
// Environment variable keys for NIO module (JWT, reevaluation).

import Foundation

enum NIOEnvKeys {
    enum JWT {
        static let secretKey = "JWT_SECRET_KEY"
        static let algorithm = "JWT_ALGORITHM"
        static let issuer = "JWT_ISSUER"
        static let audience = "JWT_AUDIENCE"
    }
}

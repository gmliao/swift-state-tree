import Foundation

/// Errors that can occur when working with LandRealm.
public enum LandRealmError: Error, Sendable {
    /// Attempted to register a land type that is already registered.
    case duplicateLandType(String)
    
    /// Attempted to register with an invalid land type (e.g., empty string).
    case invalidLandType(String)
    
    /// A server failed during operation.
    case serverFailure(landType: String, underlying: Error)
    
    public var localizedDescription: String {
        switch self {
        case .duplicateLandType(let landType):
            return "Land type '\(landType)' is already registered"
        case .invalidLandType(let landType):
            return "Invalid land type: '\(landType)'"
        case .serverFailure(let landType, let underlying):
            return "Server for land type '\(landType)' failed: \(underlying.localizedDescription)"
        }
    }
}

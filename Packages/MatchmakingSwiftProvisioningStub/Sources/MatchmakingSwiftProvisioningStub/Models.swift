import Foundation

/// Allocation Response
struct AllocationResponse: Codable, Sendable {
    let serverId: String
    let landId: String
    let connectUrl: String
}

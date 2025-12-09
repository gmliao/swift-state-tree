import Foundation

/// Protocol for distributed actor system abstraction.
///
/// This protocol provides a placeholder for future distributed actor support.
/// Currently, all actors are local (single process), but this protocol defines
/// the interface that would be needed for distributed actors across multiple
/// processes or machines.
///
/// Future implementation would use Swift's Distributed Actors framework:
/// - ActorSystem for actor location and serialization
/// - ActorIdentity for unique actor identification
/// - Serialization for cross-process communication
///
/// Note: This is a placeholder protocol. Actual distributed actor support
/// will be implemented when Swift's Distributed Actors framework is ready.
public protocol DistributedActorSystemProtocol: Sendable {
    // Placeholder for future distributed actor system interface
    // Actual methods will be defined when implementing distributed actors
}


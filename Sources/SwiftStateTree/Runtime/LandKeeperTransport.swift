import Foundation

/// Protocol defining transport operations that LandKeeper needs.
///
/// This protocol allows LandKeeper to communicate with the transport layer
/// without directly depending on transport implementations. This maintains
/// the architectural separation where Core (LandKeeper) doesn't depend on
/// Transport layer, while Transport layer depends on Core.
///
/// Example usage:
/// ```swift
/// extension TransportAdapter: LandKeeperTransport {
///     public func sendEvent(_ event: AnyServerEvent, to target: EventTarget) async {
///         await self.sendEvent(event, to: target)
///     }
///     
///     public func syncNow() async {
///         await self.syncNow()
///     }
///     
///     public func syncBroadcastOnly() async {
///         await self.syncBroadcastOnly()
///     }
/// }
/// ```
public protocol LandKeeperTransport: Sendable {
    /// Send a server event to clients.
    ///
    /// - Parameters:
    ///   - event: The server event to send.
    ///   - target: The target recipients (session, player, broadcast, etc.).
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async
    
    /// Trigger immediate state synchronization to all connected players.
    ///
    /// This should extract the current state, compute diffs, and send updates
    /// to all connected players.
    func syncNowFromTransport() async
    
    /// Sync only broadcast changes (optimized for player leaving).
    ///
    /// This is an optimization for cases where only broadcast fields have changed
    /// (e.g., a player leaving). It should only extract and compare broadcast fields,
    /// avoiding per-player snapshot extraction.
    ///
    /// If not implemented, should fall back to `syncNowFromTransport()`.
    func syncBroadcastOnlyFromTransport() async
}


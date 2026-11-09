import Foundation
import SwiftStateTree

extension TransportAdapter {
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        await _onMessageImpl(message, from: sessionID)
    }

    /// A message the router has already checked for a sync ack (#332): not parsed for one again.
    package func onRoutedMessage(_ message: Data, from sessionID: SessionID) async {
        await _onMessageImpl(message, from: sessionID, ackChecked: true)
    }
}

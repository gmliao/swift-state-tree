import Foundation
import SwiftStateTree

extension TransportAdapter {
    public func onMessage(_ message: Data, from sessionID: SessionID) async {
        await _onMessageImpl(message, from: sessionID)
    }
}

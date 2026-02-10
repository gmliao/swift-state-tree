import Foundation

extension TransportAdapter {
    public func syncNow() async {
        await _syncNowImpl()
    }

    public func syncBroadcastOnly() async {
        await _syncBroadcastOnlyImpl()
    }
}

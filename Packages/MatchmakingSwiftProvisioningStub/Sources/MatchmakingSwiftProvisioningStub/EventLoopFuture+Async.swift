import NIOCore

extension EventLoopFuture {
    @inlinable
    public func get() async throws -> Value where Value: Sendable {
        return try await withCheckedThrowingContinuation { continuation in
            self.whenComplete { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

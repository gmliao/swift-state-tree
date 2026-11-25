// Tests/SwiftStateTreeTestSupport/RecordedPayloadTree.swift
//
// A recorded action's or client event's payload as a tree, for tests that read what a record
// holds (#700 K1a: from 3.7 the record keeps the bytes the live decoder read).

import Foundation
@testable import SwiftStateTree
import SwiftStateTreeMessagePack

package enum RecordedPayloadTree {
    /// The bytes decoded as a tree with the decoder of `encoding` (`json` when nil).
    package static func tree(_ bytes: Data, encoding: RecordPayloadEncoding?) throws -> AnyCodable {
        try RecordPayloadDecoders.standard.makeSource(bytes, encoding ?? .json).decode(AnyCodable.self)
    }

    package static func tree(of action: ReevaluationRecordedAction) throws -> AnyCodable {
        try tree(action.payload, encoding: action.payloadEncoding)
    }

    package static func tree(of event: ReevaluationRecordedClientEvent) throws -> AnyCodable {
        try tree(event.payload, encoding: event.payloadEncoding)
    }
}

extension RecordedPayloadTree {
    /// A frame's JSON with each action's and client event's 3.7 payload (its bytes in base64, and
    /// their encoding) replaced by its tree, the form a record before 3.7 holds, keys sorted. A
    /// payload that is already a tree is kept.
    package static func treeForm(frameJSON: Data) throws -> Data {
        guard var frame = try JSONSerialization.jsonObject(with: frameJSON) as? [String: Any] else { return frameJSON }
        for key in ["actions", "clientEvents", "serverInputs"] {
            guard let entries = frame[key] as? [[String: Any]] else { continue }
            frame[key] = try entries.map { entry -> [String: Any] in
                guard let base64 = entry["payload"] as? String, let bytes = Data(base64Encoded: base64) else { return entry }
                // A server input's bytes are MessagePack whatever the header says (K1-Q4 (a)).
                let encoding = key == "serverInputs"
                    ? .messagepack
                    : (entry["payloadEncoding"] as? String).flatMap(RecordPayloadEncoding.init(rawValue:))
                var treeEntry = entry
                treeEntry["payload"] = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(tree(bytes, encoding: encoding)), options: .fragmentsAllowed
                )
                treeEntry.removeValue(forKey: "payloadEncoding")
                return treeEntry
            }
        }
        return try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys, .fragmentsAllowed])
    }
}

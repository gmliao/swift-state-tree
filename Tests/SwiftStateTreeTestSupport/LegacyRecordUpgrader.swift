// Tests/SwiftStateTreeTestSupport/LegacyRecordUpgrader.swift
//
// Replays a committed record from before 3.7 whose point is a shape the current recorder never
// writes (a legacy-cycle settle, a record made before #546 L2d-2, hybrid event frames before D10).
// From 3.7 replay refuses a record whose payloads are trees (#700 K1a, K1-Q1 (a)), so a test
// replays an upgraded copy instead. The committed fixture is never touched.
//
// Premise: before 3.7, live decoded a JSON client payload by encoding its tree with `JSONEncoder`
// and decoding the bytes with `JSONDecoder` (the old live round trip). So a payload tree's
// canonical JSON (`RecordPayloadEncoding.canonicalJSON`) decodes, with `JSONDecoder`, to the value
// the tree decoded to. `premiseViolations` checks that on a fixture's every action and client
// event, by decoding each payload both ways: a fixture where it doesn't hold isn't upgraded
// faithfully, and its test must say so.

import Foundation
@testable import SwiftStateTree

package enum LegacyRecordUpgrader {
    /// A copy of the binary record at `path` as a 3.7 record, in the temporary directory: each
    /// action's and client event's payload tree becomes its canonical JSON bytes, and the header
    /// says version 3.7 with `json` payloads. Everything else is kept. The caller removes the copy.
    package static func upgradedCopy(ofRecordAt path: String) throws -> String {
        var records = try readRecords(Array(Data(contentsOf: URL(fileURLWithPath: path))))
        for index in records.indices {
            try upgrade(&records[index])
        }
        var bytes = ReevaluationRecordLog.preamble
        for record in records { bytes += try ReevaluationRecordLog.framed(record) }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("upgraded-\(UUID().uuidString).sstr").path
        try Data(bytes).write(to: URL(fileURLWithPath: copy))
        return copy
    }

    /// Every action and client event payload of the record at `path` that decodes to another value
    /// from its canonical JSON than from its tree, as "<type> #<sequence>: <reason>", and how many
    /// payloads were checked.
    package static func premiseViolations<State: StateNodeProtocol>(
        ofRecordAt path: String, definition: LandDefinition<State>
    ) throws -> (checked: Int, violations: [String]) {
        let records = try readRecords(Array(Data(contentsOf: URL(fileURLWithPath: path))))
        var checked = 0
        var violations: [String] = []
        func compare(_ label: String, _ tree: AnyCodable?, _ decode: (any PayloadDecodingSource) throws -> any Encodable) {
            checked += 1
            guard let tree else {
                violations.append("\(label): not a tree")
                return
            }
            do {
                let fromTree = try RecordPayloadEncoding.canonicalJSON(AnyEncodable(decode(RecordPayloadSource(tree))))
                let bytes = try RecordPayloadEncoding.canonicalJSON(tree)
                let fromBytes = try RecordPayloadEncoding.canonicalJSON(AnyEncodable(decode(JSONRecordBytesSource(validating: bytes))))
                if fromTree != fromBytes {
                    violations.append("\(label): \(String(decoding: fromTree, as: UTF8.self)) != \(String(decoding: fromBytes, as: UTF8.self))")
                }
            } catch {
                violations.append("\(label): \(error)")
            }
        }
        for record in records where record.kind == .turn {
            for action in record.actions ?? [] {
                let label = "\(action.typeIdentifier) #\(action.sequence)"
                guard let type = actionType(action.typeIdentifier, in: definition) else {
                    violations.append("\(label): no handler")
                    continue
                }
                compare(label, action.legacyPayload) { try $0.decodeAction(type) }
            }
            for event in record.clientEvents ?? [] {
                let label = "\(event.typeIdentifier) #\(event.sequence)"
                guard let decodeEvent = definition.clientEventRegistry.findDescriptor(for: event.typeIdentifier)?.decodeClientEvent else {
                    violations.append("\(label): no decoder")
                    continue
                }
                compare(label, event.legacyPayload) { try decodeEvent($0) }
            }
        }
        return (checked, violations)
    }

    /// The action type replay matches `typeIdentifier` to: the handler's type name, or its last
    /// component.
    private static func actionType<State>(_ typeIdentifier: String, in definition: LandDefinition<State>) -> (any ActionPayload.Type)? {
        for handler in definition.actionHandlers {
            guard let type = handler.getActionType() as? any ActionPayload.Type else { continue }
            let name = String(describing: type)
            if name == typeIdentifier || name.split(separator: ".").last == typeIdentifier.split(separator: ".").last {
                return type
            }
        }
        return nil
    }

    private static func upgrade(_ record: inout ReevaluationLogRecord) throws {
        switch record.kind {
        case .header:
            guard let metadata = record.metadata else { return }
            // Version 3.7; `payloadEncoding` stays absent, which is `json`.
            record.metadata = metadata.stampedWithCurrentVersion()
        case .turn:
            record.actions = try record.actions?.map { action in
                guard let tree = action.legacyPayload else { return action }
                return ReevaluationRecordedAction(
                    kind: action.kind, sequence: action.sequence, typeIdentifier: action.typeIdentifier,
                    payload: try RecordPayloadEncoding.canonicalJSON(tree), payloadEncoding: nil,
                    playerID: action.playerID, clientID: action.clientID, sessionID: action.sessionID,
                    resolverOutputs: action.resolverOutputs, resolvedAtTick: action.resolvedAtTick
                )
            }
            record.clientEvents = try record.clientEvents?.map { event in
                guard let tree = event.legacyPayload else { return event }
                return ReevaluationRecordedClientEvent(
                    kind: event.kind, sequence: event.sequence, typeIdentifier: event.typeIdentifier,
                    payload: try RecordPayloadEncoding.canonicalJSON(tree), payloadEncoding: nil,
                    playerID: event.playerID, clientID: event.clientID, sessionID: event.sessionID,
                    resolvedAtTick: event.resolvedAtTick
                )
            }
            // A server input's tree becomes its canonical MessagePack bytes, what 3.7 records
            // (K1-Q4 (a)), whatever the header says.
            record.serverInputs = try record.serverInputs?.map { input in
                guard let tree = input.legacyPayload else { return input }
                return ReevaluationRecordedServerInput(
                    sequence: input.sequence, typeIdentifier: input.typeIdentifier,
                    payload: Data(try CanonicalMessagePack.encode(tree)), resolvedAtTick: input.resolvedAtTick
                )
            }
        case .footer:
            return
        }
    }

    /// The actions of the binary record at `path` as written, before a reader fills in an entry's
    /// encoding from its header.
    package static func writtenActions(ofRecordAt path: String) throws -> [ReevaluationRecordedAction] {
        try readRecords(Array(Data(contentsOf: URL(fileURLWithPath: path))))
            .filter { $0.kind == .turn }.flatMap { $0.actions ?? [] }
    }

    private static func readRecords(_ bytes: [UInt8]) throws -> [ReevaluationLogRecord] {
        var records: [ReevaluationLogRecord] = []
        var offset = ReevaluationRecordLog.preamble.count
        while offset < bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            records.append(try CanonicalMessagePack.decode(ReevaluationLogRecord.self, from: Array(bytes[(offset + 4)..<(offset + 4 + length)])))
            offset += 4 + length
        }
        return records
    }
}

/// An `Encodable` existential, for canonical JSON of a decoded payload.
private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

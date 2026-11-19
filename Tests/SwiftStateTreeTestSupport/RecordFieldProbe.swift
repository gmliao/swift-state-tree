// Tests/SwiftStateTreeTestSupport/RecordFieldProbe.swift
//
// Names every field of a `Decodable` type by decoding it from a probe that answers every
// request, so a field that no recorded value fills (a nil optional, an empty collection, a case
// no fixture has) is still named (#555). The technique is a reflection decoder, as Fluent's
// `ReflectionDecoder` reads a model's schema from its Codable conformance.

import Foundation

/// The field paths of a probed type: `a.b` for a nested field, `a[]` for an element of an array
/// or a dictionary value. `opaque` names the paths whose type the probe couldn't decode (an enum
/// whose raw value it can't guess, a value that validates its input). A failed type stops its
/// parent's probe there, so a test requires `opaque` to be empty: give such a type a sample.
package struct RecordFieldProbeResult: Equatable {
    package var paths: Set<String> = []
    package var opaque: Set<String> = []

    package init(paths: Set<String> = [], opaque: Set<String> = []) {
        self.paths = paths
        self.opaque = opaque
    }
}

package enum RecordFieldProbe {
    /// - Parameters:
    ///   - samples: values returned for their types instead of probing them: enums whose raw
    ///     values the probe can't guess, and leaves that validate what they decode.
    ///   - cases: for a type that picks its fields by a string discriminator (a JSON Patch `op`),
    ///     every discriminator value. The type is probed once per value, with each string decoded
    ///     at its own level answered with that value, so every case's fields are named.
    package static func probe<T: Decodable>(
        _ type: T.Type,
        at path: String = "",
        samples: [any Decodable] = [],
        cases: [ObjectIdentifier: [String]] = [:]
    ) -> RecordFieldProbeResult {
        let state = ProbeState()
        for sample in samples { state.samples[ObjectIdentifier(Swift.type(of: sample))] = sample }
        state.cases = cases
        _ = try? state.decode(type, at: path)
        return RecordFieldProbeResult(paths: state.paths, opaque: state.opaque)
    }
}

private final class ProbeState {
    var paths = Set<String>()
    var opaque = Set<String>()
    /// Types being decoded on the current path, so a recursive type stops at its second visit.
    var active: [ObjectIdentifier] = []
    var samples: [ObjectIdentifier: Any] = [:]
    var cases: [ObjectIdentifier: [String]] = [:]
    /// The discriminator answer of the type being probed at this level; nil inside other types.
    var stringAnswers: [String?] = [nil]

    func decode<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
        if type == String.self, let answer = stringAnswers.last ?? nil { return answer as! T }
        if let value = Self.leaf(type) { return value }
        if let sample = samples[ObjectIdentifier(type)] as? T { return sample }
        if let value = Self.firstCase(type) { return value }
        let id = ObjectIdentifier(type)
        if active.contains(id) {
            throw ProbeStop.recursion
        }
        active.append(id)
        defer { active.removeLast() }
        do {
            guard let answers = cases[id] else {
                stringAnswers.append(nil)
                defer { stringAnswers.removeLast() }
                return try T(from: ProbeDecoder(state: self, path: path))
            }
            var last: T?
            for answer in answers {
                stringAnswers.append(answer)
                defer { stringAnswers.removeLast() }
                last = try T(from: ProbeDecoder(state: self, path: path))
            }
            guard let last else { throw ProbeStop.opaque }
            return last
        } catch let stop as ProbeStop {
            // A recursion, or a child already reported as opaque: pass it up unreported.
            throw stop
        } catch {
            opaque.insert(path)
            throw ProbeStop.opaque
        }
    }

    func field(_ path: String) { paths.insert(path) }

    static func leaf<T>(_ type: T.Type) -> T? {
        switch type {
        case is String.Type: return "" as? T
        case is Bool.Type: return false as? T
        case is Int.Type: return 0 as? T
        case is Int8.Type: return Int8(0) as? T
        case is Int16.Type: return Int16(0) as? T
        case is Int32.Type: return Int32(0) as? T
        case is Int64.Type: return Int64(0) as? T
        case is UInt.Type: return UInt(0) as? T
        case is UInt8.Type: return UInt8(0) as? T
        case is UInt16.Type: return UInt16(0) as? T
        case is UInt32.Type: return UInt32(0) as? T
        case is UInt64.Type: return UInt64(0) as? T
        case is Double.Type: return Double(0) as? T
        case is Float.Type: return Float(0) as? T
        case is Date.Type: return Date(timeIntervalSince1970: 0) as? T
        case is Data.Type: return Data() as? T
        case is UUID.Type: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) as? T
        default: return nil
        }
    }

    /// A `CaseIterable` enum is a leaf: its first case.
    static func firstCase<T>(_ type: T.Type) -> T? {
        guard let iterable = type as? any CaseIterable.Type else { return nil }
        return first(of: iterable) as? T
    }

    private static func first<C: CaseIterable>(of type: C.Type) -> Any? { type.allCases.first }
}

private enum ProbeStop: Error {
    case recursion
    case opaque
}

private struct ProbeDecoder: Decoder {
    let state: ProbeState
    let path: String
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(ProbeKeyed<Key>(state: state, path: path))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        ProbeUnkeyed(state: state, path: path + "[]")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ProbeSingle(state: state, path: path)
    }
}

private struct ProbeKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let state: ProbeState
    let path: String
    var codingPath: [any CodingKey] { [] }

    /// A dictionary's keys accept any string; a type's `CodingKeys` don't. One probe key stands
    /// for a dictionary's entries, so its value type is walked as `path[]`.
    private static var dictionaryKey: Key? { Key(stringValue: "\u{1}probe") }

    var allKeys: [Key] { Self.dictionaryKey.map { [$0] } ?? [] }

    private func childPath(_ key: Key) -> String {
        if Self.dictionaryKey != nil { return path + "[]" }
        return path.isEmpty ? key.stringValue : path + "." + key.stringValue
    }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let child = childPath(key)
        if Self.dictionaryKey == nil { state.field(child) }
        return try state.decode(type, at: child)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let child = childPath(key)
        state.field(child)
        return KeyedDecodingContainer(ProbeKeyed<NestedKey>(state: state, path: child))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let child = childPath(key)
        state.field(child)
        return ProbeUnkeyed(state: state, path: child + "[]")
    }

    func superDecoder() throws -> any Decoder { ProbeDecoder(state: state, path: path) }
    func superDecoder(forKey key: Key) throws -> any Decoder {
        let child = childPath(key)
        state.field(child)
        return ProbeDecoder(state: state, path: child)
    }
}

/// One element: enough to walk the element type.
private struct ProbeUnkeyed: UnkeyedDecodingContainer {
    let state: ProbeState
    let path: String
    var codingPath: [any CodingKey] { [] }
    var count: Int? { 1 }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= 1 }

    init(state: ProbeState, path: String) {
        self.state = state
        self.path = path
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        return try state.decode(type, at: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        currentIndex += 1
        return KeyedDecodingContainer(ProbeKeyed<NestedKey>(state: state, path: path))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        currentIndex += 1
        return ProbeUnkeyed(state: state, path: path + "[]")
    }

    mutating func superDecoder() throws -> any Decoder {
        currentIndex += 1
        return ProbeDecoder(state: state, path: path)
    }
}

private struct ProbeSingle: SingleValueDecodingContainer {
    let state: ProbeState
    let path: String
    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try state.decode(type, at: path)
    }
}

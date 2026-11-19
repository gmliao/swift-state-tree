// Tests/SwiftStateTreeTestSupport/RecordFieldProbe.swift
//
// Names every field of a `Decodable` type by decoding it from a probe that answers every
// request, so a field that no recorded value fills (a nil optional, an empty collection, a case
// no fixture has) is still named (#555).
//
// Prior art: a reflection decoder, as Fluent's `ReflectionDecoder` reads a model's schema from its
// Codable conformance, and its practice of decoding twice with different scalar answers to find
// fields that depend on a decoded value. The probe runs twice: once answering every scalar with
// one value (`""`, `0`, `false`) and once with another (`"\u{2}"`, `1`, `true`). A type whose
// fields or success differ between the two runs branches on a decoded value (a discriminator, a
// version gate) is reported in `branching`, so a branch the probe can't see is never skipped
// silently. A type with a string discriminator listed in `cases` is probed once per listed value
// in each run, with only the discriminator key fixed; its other scalars still differ between the
// runs, so a gate added beside the discriminator is still reported. In the second run a
// `CaseIterable` enum takes its last case, and a type with two samples takes the second.
//
// Limits, each reported rather than skipped, except the first:
// - A string discriminator with a silent default branch (an unknown value taken as one of the
//   cases) can't be found: no answer the probe picks is a case, so both runs take the default.
//   One that rejects an unknown value fails in both runs and is reported in `opaque`; list its
//   values in `cases`. Integer and Boolean gates are found by the second run.
// - A sample is checked to be a single-value leaf: a type that asks for a keyed or unkeyed
//   container, or decodes anything but a scalar from its single value, is in `nonLeafSamples`.
//   A single-value wrapper around a scalar (a hash read from hex) passes as a leaf by design:
//   its one value is the field.
// - An unkeyed container (an array) is probed with one element, so an array whose elements
//   differ by position names only the first element's fields.
// - A type the probe can't build (an enum whose raw value it can't guess, a value that validates
//   its input) is reported in `opaque` and stops its parent there: give it a sample.
// - A recursive type is reported in `recursive` at its second visit and stops its parent there.
// - A boundary is a type whose content is dynamic (a payload, a snapshot value): it is not
//   probed, and its paths are reported in `boundaries` so the caller declares them.

import Foundation

package struct RecordFieldProbeResult: Equatable {
    /// The field paths: `a.b` for a nested field, `a[]` for an array element or dictionary value.
    package var paths: Set<String> = []
    /// Paths whose type the probe couldn't build.
    package var opaque: Set<String> = []
    /// Paths where a type recurred inside itself.
    package var recursive: Set<String> = []
    /// Paths of types whose fields or success depend on a decoded value other than a listed
    /// discriminator.
    package var branching: Set<String> = []
    /// Paths where a boundary type was returned unprobed.
    package var boundaries: Set<String> = []
    /// Sample types that aren't single-value leaves (they ask for a keyed or unkeyed container),
    /// whose fields a sample would hide.
    package var nonLeafSamples: Set<String> = []

    package init(
        paths: Set<String> = [], opaque: Set<String> = [], recursive: Set<String> = [],
        branching: Set<String> = [], boundaries: Set<String> = [], nonLeafSamples: Set<String> = []
    ) {
        self.paths = paths
        self.opaque = opaque
        self.recursive = recursive
        self.branching = branching
        self.boundaries = boundaries
        self.nonLeafSamples = nonLeafSamples
    }
}

/// A type's string discriminator: the coding key that holds it and every value it takes.
package struct ProbeCases: Sendable {
    package let key: String
    package let values: [String]

    package init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}

package enum RecordFieldProbe {
    /// - Parameters:
    ///   - samples: values returned for their types instead of probing them: enums whose raw
    ///     values the probe can't guess, and leaves that validate what they decode. Each must be
    ///     a single-value leaf; a sample type that isn't is in `nonLeafSamples`. Give a second
    ///     sample of the same type for the second run, so a type that branches on it is found.
    ///   - boundaries: values returned for dynamic types (a payload, a snapshot value), whose
    ///     content isn't a fixed field set. Their paths are reported in `boundaries`.
    ///   - cases: for a type that picks its fields by a string discriminator (a JSON Patch `op`),
    ///     its key and every value. The type is probed once per value in each run, with only that
    ///     key answered with the value.
    package static func probe<T: Decodable>(
        _ type: T.Type,
        at path: String = "",
        samples: [any Decodable] = [],
        boundaries: [any Decodable] = [],
        cases: [ObjectIdentifier: ProbeCases] = [:]
    ) -> RecordFieldProbeResult {
        let runs = [0, 1].map { variant -> ProbeState in
            let state = ProbeState(variant: variant)
            var byType: [ObjectIdentifier: [Any]] = [:]
            for sample in samples { byType[ObjectIdentifier(Swift.type(of: sample)), default: []].append(sample) }
            for (id, values) in byType { state.samples[id] = values[min(variant, values.count - 1)] }
            for boundary in boundaries { state.boundaries[ObjectIdentifier(Swift.type(of: boundary))] = boundary }
            state.cases = cases
            _ = try? state.decode(type, at: path)
            return state
        }
        var result = RecordFieldProbeResult()
        for run in runs {
            result.paths.formUnion(run.paths)
            result.opaque.formUnion(run.opaque)
            result.recursive.formUnion(run.recursive)
            result.boundaries.formUnion(run.boundaryPaths)
        }
        result.branching = branching(runs[0], runs[1])
        result.nonLeafSamples = Set(samples.filter { !isSingleValueLeaf($0) }.map { "\(Swift.type(of: $0))" })
        return result
    }

    /// The composite paths whose subtree or success differs between the runs, deepest only (a
    /// parent of a branching type differs through it).
    private static func branching(_ a: ProbeState, _ b: ProbeState) -> Set<String> {
        func below(_ parent: String, _ path: String) -> Bool {
            parent.isEmpty ? !path.isEmpty : (path.hasPrefix(parent + ".") || path.hasPrefix(parent + "[]"))
        }
        var differing = Set<String>()
        for path in Set(a.composites.keys).union(b.composites.keys) {
            let subA = a.paths.filter { below(path, $0) }, subB = b.paths.filter { below(path, $0) }
            if subA != subB || a.composites[path]?.ok != b.composites[path]?.ok {
                differing.insert(path)
            }
        }
        // A listed type, case by case: its path branches when one case's fields or success
        // differ between the runs, even if the union over its cases doesn't.
        for key in Set(a.casePaths.keys).union(b.casePaths.keys).union(a.caseResults.keys).union(b.caseResults.keys) {
            guard a.casePaths[key] != b.casePaths[key] || a.caseResults[key] != b.caseResults[key],
                  let mark = key.lastIndex(of: "#") else { continue }
            differing.insert(String(key[..<mark]))
        }
        return differing.filter { parent in !differing.contains { below(parent, $0) } }
    }

    private static func isSingleValueLeaf<S: Decodable>(_ sample: S) -> Bool {
        let shape = ShapeDecoder()
        _ = try? S(from: shape)
        return !shape.askedForContainer
    }
}

private final class ProbeState {
    let variant: Int
    var paths = Set<String>()
    var opaque = Set<String>()
    var recursive = Set<String>()
    var boundaryPaths = Set<String>()
    /// Each composite type decoded, by path, and whether it built.
    var composites: [String: (type: ObjectIdentifier, ok: Bool)] = [:]
    /// Each listed case's fields and success, by `<path>#<value>`.
    var casePaths: [String: Set<String>] = [:]
    var caseResults: [String: Bool] = [:]
    private func noteCasePaths(_ key: String, _ found: Set<String>) { casePaths[key, default: []].formUnion(found) }
    /// Types being decoded on the current path, so a recursive type stops at its second visit.
    var active: [ObjectIdentifier] = []
    var samples: [ObjectIdentifier: Any] = [:]
    var boundaries: [ObjectIdentifier: Any] = [:]
    var cases: [ObjectIdentifier: ProbeCases] = [:]
    /// The discriminator key and answer of the type being probed at this level; nil inside other
    /// types.
    var discriminators: [(key: String, answer: String)?] = [nil]

    init(variant: Int) { self.variant = variant }

    func decode<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
        if let value = leaf(type, variant: variant) { return value }
        let id = ObjectIdentifier(type)
        if let sample = samples[id] as? T { return sample }
        if let boundary = boundaries[id] as? T {
            boundaryPaths.insert(path)
            return boundary
        }
        if let value = Self.enumCase(type, variant: variant) { return value }
        if active.contains(id) {
            recursive.insert(path)
            throw ProbeStop.recursion
        }
        active.append(id)
        defer { active.removeLast() }
        do {
            let value = try build(type, id: id, at: path)
            composites[path] = (id, true)
            return value
        } catch let stop as ProbeStop {
            // A recursion, or a child already reported: pass it up unreported.
            composites[path] = (id, false)
            throw stop
        } catch {
            composites[path] = (id, false)
            opaque.insert(path)
            throw ProbeStop.opaque
        }
    }

    private func build<T: Decodable>(_ type: T.Type, id: ObjectIdentifier, at path: String) throws -> T {
        guard let listed = cases[id] else {
            discriminators.append(nil)
            defer { discriminators.removeLast() }
            return try T(from: ProbeDecoder(state: self, path: path))
        }
        var last: T?
        for answer in listed.values {
            discriminators.append((listed.key, answer))
            defer { discriminators.removeLast() }
            // Each case's fields apart, so the runs are compared per case before the union: a
            // gate that moves a field from one case to another leaves the union unchanged.
            let outer = paths
            paths = []
            let key = "\(path)#\(answer)"
            defer {
                noteCasePaths(key, paths)
                paths.formUnion(outer)
            }
            do {
                last = try T(from: ProbeDecoder(state: self, path: path))
                caseResults[key] = true
            } catch {
                caseResults[key] = false
                throw error
            }
        }
        guard let last else { throw ProbeStop.opaque }
        return last
    }

    func field(_ path: String) { paths.insert(path) }

    /// A `CaseIterable` enum is a leaf: its first case in the first run, its last in the second.
    static func enumCase<T>(_ type: T.Type, variant: Int) -> T? {
        guard let iterable = type as? any CaseIterable.Type else { return nil }
        return pick(of: iterable, last: variant != 0) as? T
    }

    private static func pick<C: CaseIterable>(of type: C.Type, last: Bool) -> Any? {
        last ? Array(type.allCases).last : type.allCases.first
    }
}

/// The scalar answer of a run: `variant` 0 or 1 gives two different values for each type.
private func leaf<T>(_ type: T.Type, variant: Int) -> T? {
    let one = variant != 0
    switch type {
    case is String.Type: return (one ? "\u{2}" : "") as? T
    case is Bool.Type: return one as? T
    case is Int.Type: return Int(variant) as? T
    case is Int8.Type: return Int8(variant) as? T
    case is Int16.Type: return Int16(variant) as? T
    case is Int32.Type: return Int32(variant) as? T
    case is Int64.Type: return Int64(variant) as? T
    case is UInt.Type: return UInt(variant) as? T
    case is UInt8.Type: return UInt8(variant) as? T
    case is UInt16.Type: return UInt16(variant) as? T
    case is UInt32.Type: return UInt32(variant) as? T
    case is UInt64.Type: return UInt64(variant) as? T
    case is Double.Type: return Double(variant) as? T
    case is Float.Type: return Float(variant) as? T
    case is Date.Type: return Date(timeIntervalSince1970: Double(variant)) as? T
    case is Data.Type: return Data(one ? [1] : []) as? T
    case is UUID.Type: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(variant))) as? T
    default: return nil
    }
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
        if type == String.self, let listed = state.discriminators.last ?? nil, listed.key == key.stringValue {
            return listed.answer as! T
        }
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

/// One element: enough to walk the element type (see the file's limits).
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

/// Records whether a type asks for a keyed or unkeyed container, or decodes a non-scalar from its
/// single value; scalars get the first run's answers, anything else fails.
private final class ShapeDecoder: Decoder {
    var askedForContainer = false
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        askedForContainer = true
        throw ProbeStop.opaque
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        askedForContainer = true
        throw ProbeStop.opaque
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { ShapeSingle(shape: self) }
}

private struct ShapeSingle: SingleValueDecodingContainer {
    let shape: ShapeDecoder
    var codingPath: [any CodingKey] { [] }
    func decodeNil() -> Bool { false }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let value = leaf(type, variant: 0) else {
            // A composite inside the single value: its fields would be hidden.
            shape.askedForContainer = true
            throw ProbeStop.opaque
        }
        return value
    }
}

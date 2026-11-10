import Testing
import SwiftStateTree

// The compile-time check behind `@StateNodeBuilder`'s non-Equatable warning resolves on a field's
// static type. A warning doesn't fail a build, so these pin which side each shape resolves to:
// it must be the side `SyncTableField.make` takes for a non-generic field.

private struct CheckPlain: Sendable {
    var n = 0
}

private struct CheckValue: Sendable, Equatable {
    var n = 0
}

@StateNodeBuilder
struct CheckRow: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    init() {}
}

private struct CheckHolder<T> {
    var equatable: CheckValue? = nil
    var optionalEquatable: CheckValue?? = nil
    var list: [CheckValue]? = nil
    var map: [String: Int]? = nil
    var plain: CheckPlain? = nil
    var plainList: [CheckPlain]? = nil
    var plainMap: [String: CheckPlain]? = nil
    var node: CheckRow? = nil
    var optionalNode: CheckRow?? = nil
    var nodeMap: [String: CheckRow]? = nil
    var nodeMapByInt: [Int: CheckRow]? = nil
    var nodeList: [CheckRow]? = nil
    var generic: [String: T]? = nil
}

private func isTyped(_: _SyncTypedField) -> Bool { true }
private func isTyped(_: _SyncFallbackField) -> Bool { false }

@Suite("The compile-time check of a synced field's type")
struct SyncFieldCheckTests {
    private typealias Holder = CheckHolder<Int>

    @Test("An Equatable value, an optional one and Equatable collections are typed")
    func equatableValues() {
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.equatable }))
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.optionalEquatable }))
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.list }))
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.map }))
    }

    @Test("A node, an optional node and a node map are typed")
    func nodes() {
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.node }))
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.optionalNode }))
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.nodeMap }))
        #expect(isTyped(_syncFieldKind { (node: Holder) in node.nodeMapByInt }))
    }

    @Test("A value that isn't Equatable, alone or in a collection, is a fallback")
    func nonEquatable() {
        #expect(!isTyped(_syncFieldKind { (node: Holder) in node.plain }))
        #expect(!isTyped(_syncFieldKind { (node: Holder) in node.plainList }))
        #expect(!isTyped(_syncFieldKind { (node: Holder) in node.plainMap }))
        // A node isn't Equatable, so an array of nodes is a fallback here as it is at run time.
        #expect(!isTyped(_syncFieldKind { (node: Holder) in node.nodeList }))
    }

    @Test("A field of a generic parameter's type resolves as a fallback whatever it is bound to")
    func genericParameter() {
        // Why the macro leaves the check out for such a field: with `T` an `Int` the field is
        // typed at run time, and the static resolution can't see it.
        func resolved<T>(_: T.Type) -> Bool {
            isTyped(_syncFieldKind { (node: CheckHolder<T>) in node.generic })
        }
        #expect(!resolved(Int.self))
        #expect(isTyped(_syncFieldKind { (node: CheckHolder<Int>) in node.generic }))
    }
}

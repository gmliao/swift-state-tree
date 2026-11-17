// Tests for #566: `@SnapshotConvertible` lists a let-only struct's fields for the schema.
// The fixtures below are compiled: each property type form must expand to code swiftc accepts.

import Foundation
import Testing
@testable import SwiftStateTree

/// An existential behind a typealias: the macro can't see it (#535's documented gap), so the
/// field list still names its type. A field spelled `any P` is refused at expansion.
typealias SnapshotFieldListAnyConvertible = any SnapshotValueConvertible

/// One let-only struct per property type form the generated `(T).self` must parse for.
@SnapshotConvertible
struct SnapshotFieldListForms {
    let existential: SnapshotFieldListAnyConvertible
    let optional: Int?
    let optionalExistential: SnapshotFieldListAnyConvertible?
    let dictionary: [String: [Int]]
    let generic: Optional<String>
}

/// Implicitly unwrapped optionals: the generated `(T).self` lists are spelled `(Int?).self`, since
/// `(Int!).self` doesn't compile. A let-only one gets the schema field list too.
@SnapshotConvertible
struct SnapshotFieldListUnwrapped {
    let count: Int!
}

@SnapshotConvertible
struct SnapshotStoredFieldsUnwrapped {
    var count: Int! = nil
}

/// A type that declares its own field list keeps it: the macro generates none, so the two don't
/// clash.
@SnapshotConvertible
struct SnapshotFieldListDeclared: SnapshotFieldListProvider {
    let a: Int
    let b: String

    static var snapshotFieldMetadata: [FieldMetadata] {
        [FieldMetadata(name: "a", type: Int.self, policy: nil, nodeKind: .leaf, defaultValue: nil)]
    }
}

@Suite("SnapshotFieldListProvider (#566)")
struct SnapshotFieldListProviderTests {
    @Test("a let-only struct lists every property, with its type, whatever the type's form")
    func everyFormIsListed() {
        let fields = SnapshotFieldListForms.snapshotFieldMetadata
        #expect(fields.map(\.name) == ["existential", "optional", "optionalExistential", "dictionary", "generic"])
        #expect(ObjectIdentifier(fields[0].type) == ObjectIdentifier((any SnapshotValueConvertible).self))
        #expect(ObjectIdentifier(fields[1].type) == ObjectIdentifier(Int?.self))
        #expect(ObjectIdentifier(fields[2].type) == ObjectIdentifier((any SnapshotValueConvertible)?.self))
        #expect(ObjectIdentifier(fields[3].type) == ObjectIdentifier([String: [Int]].self))
        #expect(ObjectIdentifier(fields[4].type) == ObjectIdentifier(String?.self))
    }

    @Test("a type's own snapshotFieldMetadata is kept, not generated over")
    func declaredListIsKept() {
        #expect(SnapshotFieldListDeclared.snapshotFieldMetadata.map(\.name) == ["a"])
    }

    @Test("an implicitly unwrapped optional is listed as its optional type")
    func unwrappedIsOptional() {
        #expect(ObjectIdentifier(SnapshotFieldListUnwrapped.snapshotFieldMetadata[0].type) == ObjectIdentifier(Int?.self))
        #expect(ObjectIdentifier(SnapshotFieldListUnwrapped._snapshotStoredFields[0].type) == ObjectIdentifier(Int?.self))
        #expect(ObjectIdentifier(SnapshotStoredFieldsUnwrapped._snapshotStoredFields[0].type) == ObjectIdentifier(Int?.self))
    }
}

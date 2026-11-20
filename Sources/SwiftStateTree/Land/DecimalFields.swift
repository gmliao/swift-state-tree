import Foundation

/// Where a `Decimal` would reach the wire, refused at registration (#597).
///
/// `Decimal` has no wire form: its synced value would be its private stored fields, and a
/// payload's MessagePack form was a lossy `Double` on one path and a string on another. The
/// macros refuse a `Decimal` the declared syntax shows (`@Payload`, `@StateNodeBuilder`,
/// `@SnapshotConvertible`). Registration refuses what their metadata shows past the syntax (a
/// typealias): a synced field is a `SyncRegistrationError.Problem.decimalField`, a payload field
/// is in `LandRegistrationError.decimalFields`. What neither sees fails at the first send: the
/// JSON encodings and the MessagePack encoders refuse a `Decimal`. A `.serverOnly` or
/// `@Internal` state field, and a resolver output, which never reaches the wire, may hold one.
enum DecimalFields {
    /// What to use instead, in every refusal.
    static let advice = "Decimal has no wire form; store an integer of the smallest unit (cents) or a String"

    /// The paths under `type` (named `root`) that hold a `Decimal`, as a payload's fields reach
    /// the wire: a payload type's fields (`getFieldMetadata()`), a state node's synced fields, a
    /// `@SnapshotConvertible` type's stored fields, optionals, arrays, sets and dictionaries
    /// (keys and values). A nested plain `Codable` type lists no fields, so it isn't looked
    /// into: a `Decimal` in it fails at the first send.
    static func payloadPaths(in type: Any.Type, root: String) -> [String] {
        var walker = Walker()
        walker.visit(type, path: root)
        return walker.paths
    }

    private struct Walker {
        var paths: [String] = []
        /// The types on the current path: a type that holds itself is walked once per path.
        private var onPath: Set<ObjectIdentifier> = []

        mutating func visit(_ type: Any.Type, path: String) {
            if type == Decimal.self {
                paths.append(path)
                return
            }
            if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                visit(wrapped, path: path)
                return
            }
            if let value = SchemaHelper.dictionaryValueType(from: type) {
                if let key = SchemaHelper.dictionaryKeyType(from: type) {
                    visit(key, path: "\(path)[key]")
                }
                visit(value, path: "\(path)[*]")
                return
            }
            if let element = SchemaHelper.arrayElementType(from: type) ?? SyncSetHelper.elementType(of: type) {
                visit(element, path: "\(path)[*]")
                return
            }
            let id = ObjectIdentifier(type)
            guard !onPath.contains(id) else { return }
            onPath.insert(id)
            defer { onPath.remove(id) }
            if let node = type as? any StateNodeProtocol.Type {
                for field in node.getFieldMetadata() where field.policy != nil && field.policy != .serverOnly {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            } else if let provider = type as? any SchemaMetadataProvider.Type {
                for field in provider.getFieldMetadata() {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            } else if let stored = type as? any SnapshotConvertibleStoredFields.Type {
                // A field with no type annotation is `Any` here, and isn't followed.
                for field in stored._snapshotStoredFields where field.type != Any.self {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            }
        }
    }
}

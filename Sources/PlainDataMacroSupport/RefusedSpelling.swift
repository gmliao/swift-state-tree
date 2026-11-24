// The classifier SwiftStateTree's macros refuse field types by today: types that can hold a value
// of any type (#535 D8 (b)), and `Decimal`, which has no wire form (#597). It sits beside the
// Foundation list in `PlainDataDiagnostic`, so the two refusal lists live in one target.

import SwiftSyntax

/// Type names refused wherever they appear in a synced field's type (`@StateNodeBuilder`). `Any` and `AnyObject` are
/// existentials; `AnyHashable` and the library's `AnyCodable` are concrete structs that box a
/// value of any type, so they are refused by name, with the same effect.
private let refusedTypeNames: Set<String> = ["Any", "AnyObject", "AnyHashable", "AnyCodable"]

/// What a refused spelling is.
public enum RefusedKind: Sendable {
    /// It holds a value of any type (#535 D8 (b)).
    case existential
    /// `Decimal`, which has no wire form (#597).
    case decimal
}

/// A refused part of a declared type, as written.
public struct RefusedSpelling {
    public let spelling: String
    public let kind: RefusedKind
}

/// The first part of `type` a field can't have: `any P`, a protocol composition (`P & Q`), one
/// of the refused names, or `Decimal` (`Foundation.Decimal`), at any depth (a generic argument,
/// an optional, an array, a dictionary, a tuple). `kinds` limits what is looked for. A
/// protocol spelled bare (`P`) and a typealias aren't visible in the syntax: those are the
/// documented gap, which the runtime backstops cover (the land ends at the first conversion or
/// encode that throws).
public func refusedSpelling(in type: TypeSyntax, kinds: Set<RefusedKind> = [.existential, .decimal]) -> RefusedSpelling? {
    let finder = RefusedTypeFinder(kinds: kinds)
    finder.walk(type)
    return finder.found
}

private final class RefusedTypeFinder: SyntaxVisitor {
    let kinds: Set<RefusedKind>
    var found: RefusedSpelling?

    init(kinds: Set<RefusedKind>) {
        self.kinds = kinds
        super.init(viewMode: .sourceAccurate)
    }

    private func note(_ spelling: String, _ kind: RefusedKind) {
        if found == nil, kinds.contains(kind) { found = RefusedSpelling(spelling: spelling, kind: kind) }
    }

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.someOrAnySpecifier.tokenKind == .keyword(.any) { note(node.trimmedDescription, .existential) }
        return found == nil ? .visitChildren : .skipChildren
    }

    override func visit(_ node: CompositionTypeSyntax) -> SyntaxVisitorContinueKind {
        note(node.trimmedDescription, .existential)
        return found == nil ? .visitChildren : .skipChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if refusedTypeNames.contains(node.name.text) { note(node.name.text, .existential) }
        if node.name.text == "Decimal" { note(node.name.text, .decimal) }
        return found == nil ? .visitChildren : .skipChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // `Swift.AnyHashable`, `SwiftStateTree.AnyCodable`, `Foundation.Decimal`.
        if refusedTypeNames.contains(node.name.text) { note(node.trimmedDescription, .existential) }
        if node.name.text == "Decimal", node.baseType.trimmedDescription == "Foundation" {
            note(node.trimmedDescription, .decimal)
        }
        return found == nil ? .visitChildren : .skipChildren
    }
}

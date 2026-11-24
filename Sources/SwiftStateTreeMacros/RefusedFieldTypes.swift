// Sources/SwiftStateTreeMacros/RefusedFieldTypes.swift
//
// Field types refused where the declared syntax shows them: types that can hold a value of any
// type (#535 D8 (b)), and `Decimal`, which has no wire form (#597).

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Type names refused wherever they appear in a synced field's type. `Any` and `AnyObject` are
/// existentials; `AnyHashable` and the library's `AnyCodable` are concrete structs that box a
/// value of any type, so they are refused by name, with the same effect.
private let refusedTypeNames: Set<String> = ["Any", "AnyObject", "AnyHashable", "AnyCodable"]

/// What a refused spelling is.
enum RefusedKind {
    /// It holds a value of any type (#535 D8 (b)).
    case existential
    /// `Decimal`, which has no wire form (#597).
    case decimal
}

/// A refused part of a declared type, as written.
struct RefusedSpelling {
    let spelling: String
    let kind: RefusedKind
}

/// The first part of `type` a field can't have: `any P`, a protocol composition (`P & Q`), one
/// of the refused names, or `Decimal` (`Foundation.Decimal`), at any depth (a generic argument,
/// an optional, an array, a dictionary, a tuple). `kinds` limits what is looked for. A
/// protocol spelled bare (`P`) and a typealias aren't visible in the syntax: those are the
/// documented gap, which the runtime backstops cover (the land ends at the first conversion or
/// encode that throws).
func refusedSpelling(in type: TypeSyntax, kinds: Set<RefusedKind> = [.existential, .decimal]) -> RefusedSpelling? {
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

/// Reports every stored property of `structDecl` whose declared type `refusedSpelling` refuses,
/// and returns whether there was one. `onlySynced` limits the check to `@Sync` properties
/// (`@StateNodeBuilder`: `@Internal` fields aren't synced, and the compiler holds them to
/// `PlainData`), and a `@Sync(.serverOnly)` property isn't checked for `Decimal`, since it isn't
/// sent. `kinds` limits what is refused (`@Payload` refuses only `Decimal`: a payload may hold
/// an `AnyCodable`).
func diagnoseRefusedFieldTypes(
    in structDecl: StructDeclSyntax,
    onlySynced: Bool,
    kinds: Set<RefusedKind> = [.existential, .decimal],
    context: some MacroExpansionContext
) -> Bool {
    var refused = false
    for member in structDecl.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              !variable.modifiers.contains(where: { $0.name.text == "static" }),
              !variable.bindings.contains(where: { $0.accessorBlock != nil })
        else { continue }
        var fieldKinds = kinds
        if onlySynced {
            let sync = variable.attributes.lazy.compactMap { $0.as(AttributeSyntax.self) }.first { attribute in
                attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Sync"
            }
            guard let sync else { continue }
            if StateNodeBuilderMacro.isServerOnlySync(sync) { fieldKinds.remove(.decimal) }
        }
        for binding in variable.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type,
                  let found = refusedSpelling(in: type, kinds: fieldKinds)
            else { continue }
            refused = true
            let message: any DiagnosticMessage = switch found.kind {
            case .existential: RefusedFieldTypeDiagnostic(propertyName: name, spelling: found.spelling)
            case .decimal: DecimalFieldTypeDiagnostic(propertyName: name, spelling: found.spelling)
            }
            context.diagnose(Diagnostic(node: Syntax(type), message: message))
        }
    }
    return refused
}

/// The error thrown after `diagnoseRefusedFieldTypes` reported a field.
struct RefusedFieldTypeError: Error {}

private struct RefusedFieldTypeDiagnostic: DiagnosticMessage {
    let propertyName: String
    let spelling: String

    var message: String {
        "synced property '\(propertyName)' can't have '\(spelling)' in its type: it holds a value of any type, which "
            + "registration can't check and the sync may fail to convert; use a concrete type, or an enum with a case "
            + "for each kind of value it holds"
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftStateTreeMacros", id: "refusedSyncFieldType") }
    var severity: DiagnosticSeverity { .error }
}

private struct DecimalFieldTypeDiagnostic: DiagnosticMessage {
    let propertyName: String
    let spelling: String

    var message: String {
        "property '\(propertyName)' can't have '\(spelling)' in its type: Decimal has no wire form (a JSON encoding "
            + "writes a Decimal NaN as a bare NaN, which isn't JSON, and the MessagePack encoders refuse it); store an "
            + "integer of the smallest unit (cents) or a String (#597). A type of your own named Decimal: "
            + "qualify it with its module"
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftStateTreeMacros", id: "refusedDecimalFieldType") }
    var severity: DiagnosticSeverity { .error }
}

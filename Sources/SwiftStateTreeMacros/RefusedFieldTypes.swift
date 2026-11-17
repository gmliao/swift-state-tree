// Sources/SwiftStateTreeMacros/RefusedFieldTypes.swift
//
// Synced field types that can hold a value of any type (#535 D8 (b)): refused where the declared
// syntax shows them.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Type names refused wherever they appear in a synced field's type. `Any` and `AnyObject` are
/// existentials; `AnyHashable` and the library's `AnyCodable` are concrete structs that box a
/// value of any type, so they are refused by name, with the same effect.
private let refusedTypeNames: Set<String> = ["Any", "AnyObject", "AnyHashable", "AnyCodable"]

/// The first part of `type` a synced field can't have: `any P`, a protocol composition
/// (`P & Q`), or one of the refused names, at any depth (a generic argument, an optional, an
/// array, a dictionary, a tuple). A protocol spelled bare (`P`) and a typealias that names an
/// existential aren't visible in the syntax: those are the documented gap, which the runtime
/// backstop covers (the land ends at the first conversion that throws).
func refusedSpelling(in type: TypeSyntax) -> String? {
    let finder = RefusedTypeFinder(viewMode: .sourceAccurate)
    finder.walk(type)
    return finder.found
}

private final class RefusedTypeFinder: SyntaxVisitor {
    var found: String?

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, node.someOrAnySpecifier.tokenKind == .keyword(.any) {
            found = node.trimmedDescription
        }
        return found == nil ? .visitChildren : .skipChildren
    }

    override func visit(_ node: CompositionTypeSyntax) -> SyntaxVisitorContinueKind {
        if found == nil { found = node.trimmedDescription }
        return .skipChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, refusedTypeNames.contains(node.name.text) {
            found = node.name.text
        }
        return found == nil ? .visitChildren : .skipChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // `Swift.AnyHashable`, `SwiftStateTree.AnyCodable`.
        if found == nil, refusedTypeNames.contains(node.name.text) {
            found = node.trimmedDescription
        }
        return found == nil ? .visitChildren : .skipChildren
    }
}

/// Reports every stored property of `structDecl` whose declared type `refusedSpelling` refuses,
/// and returns whether there was one. `onlySynced` limits the check to `@Sync` properties
/// (`@StateNodeBuilder`: `@Internal` fields aren't synced and may hold anything).
func diagnoseRefusedFieldTypes(
    in structDecl: StructDeclSyntax,
    onlySynced: Bool,
    context: some MacroExpansionContext
) -> Bool {
    var refused = false
    for member in structDecl.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              !variable.modifiers.contains(where: { $0.name.text == "static" }),
              !variable.bindings.contains(where: { $0.accessorBlock != nil })
        else { continue }
        if onlySynced {
            let isSynced = variable.attributes.contains { attribute in
                attribute.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Sync"
            }
            guard isSynced else { continue }
        }
        for binding in variable.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type,
                  let spelling = refusedSpelling(in: type)
            else { continue }
            refused = true
            context.diagnose(Diagnostic(node: Syntax(type), message: RefusedFieldTypeDiagnostic(propertyName: name, spelling: spelling)))
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

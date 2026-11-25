// Sources/SwiftStateTreeMacros/RefusedFieldDiagnostics.swift
//
// `@StateNodeBuilder`'s and `@Payload`'s field refusals, over the shared classifier in
// PlainDataMacroSupport: the open types in synced fields for `@StateNodeBuilder` (its PlainData
// walk refuses `Decimal` in every field), `Decimal` only for `@Payload`.

import PlainDataMacroSupport
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Reports every stored property of `structDecl` whose declared type `refusedSpelling` refuses,
/// and returns whether there was one. `onlySynced` limits the check to `@Sync` properties
/// (`@StateNodeBuilder`: `@Internal` fields aren't synced, and the compiler holds them to
/// `PlainData`). `kinds` limits what is refused (`@StateNodeBuilder` refuses only the open
/// types: its PlainData walk refuses `Decimal` in every field).
func diagnoseRefusedFieldTypes(
    in structDecl: StructDeclSyntax,
    onlySynced: Bool,
    kinds: Set<RefusedKind> = [.existential, .decimal],
    context: some MacroExpansionContext
) -> Bool {
    var refused = false
    for member in structDecl.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              PlainDataWalk.isStoredInstance(variable)
        else { continue }
        if onlySynced {
            let isSynced = PlainDataWalk.hasAttribute(named: "Sync", in: variable.attributes)
            guard isSynced else { continue }
        }
        for binding in variable.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type,
                  let found = refusedSpelling(in: type, kinds: kinds)
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

    /// `@PlainData`'s Foundation message, the one copy of what to store instead, and #597's
    /// reason, which holds here even for a field that isn't checked for `PlainData`.
    var message: String {
        let plain = PlainDataDiagnostic.foundation("Decimal", PlainDataDiagnostic.foundationReplacement("Decimal") ?? "").message
        return "property '\(propertyName)' can't have '\(spelling)' in its type: \(plain). It has no wire form either: a "
            + "JSON encoding writes a Decimal NaN as a bare NaN, which isn't JSON, and the MessagePack encoders refuse it (#597)"
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftStateTreeMacros", id: "refusedDecimalFieldType") }
    var severity: DiagnosticSeverity { .error }
}

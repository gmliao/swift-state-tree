// The attributes a state type may carry (#100). An attached macro this project doesn't know can
// add members `@StateNodeBuilder` and the PlainData check never see: no marker check, no
// PlainData check and no field metadata. So a state type takes only this project's macros that
// belong there and built-in attributes that add no members.

import PlainDataMacroSupport
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

enum StateTypeAttributes {
    /// Beside `@StateNodeBuilder`. `@PlainData` is listed so that its own refusal, which says
    /// what to do, is the one reported.
    static let besideStateNodeBuilder: Set<String> = ["StateNodeBuilder", "SnapshotConvertible", "PlainData"]

    /// Beside `@SnapshotConvertible` (without `@StateNodeBuilder`): it yields its witness to
    /// `@PlainData` and `@Payload`, and `@Payload` refuses the pair on its own.
    static let besideSnapshotConvertible: Set<String> = ["SnapshotConvertible", "StateNodeBuilder", "PlainData", "Payload"]

    /// The names a refusal lists as allowed: those that are legitimate on the type. A name kept in
    /// an allowed set only so that another macro's own refusal is reported isn't listed.
    static let advertisedBesideStateNodeBuilder: Set<String> = ["StateNodeBuilder", "SnapshotConvertible"]
    static let advertisedBesideSnapshotConvertible: Set<String> = ["SnapshotConvertible", "StateNodeBuilder", "PlainData"]

    /// Built-in attributes that add no members.
    static let builtins: Set<String> = [
        "available", "usableFromInline", "frozen", "propertyWrapper", "resultBuilder",
        "dynamicMemberLookup", "dynamicCallable", "preconcurrency", "_spi", "_documentation",
    ]

    /// Diagnoses every attribute on a state type that isn't in `allowed` or `builtins`.
    ///
    /// The syntax shows only spellings. A bare `@SnapshotConvertible` is taken as this
    /// project's, so a macro of the user's own with that name passes; a qualified spelling passes
    /// only with a module that declares or re-exports the macro (`PlainDataWalk.modules`). An attribute inside `#if` is refused, since its condition can't be read here.
    static func diagnoseUnknown(
        _ attributes: AttributeListSyntax,
        allowed: Set<String>,
        advertised: Set<String>,
        in context: some MacroExpansionContext
    ) {
        for element in attributes {
            switch element {
            case .attribute(let attribute):
                if !isAllowed(attribute, allowed: allowed) {
                    context.diagnose(Diagnostic(
                        node: attribute,
                        message: StateTypeAttributeDiagnostic(name: "@" + attribute.attributeName.trimmedDescription, allowed: advertised)
                    ))
                }
            case .ifConfigDecl(let ifConfig):
                context.diagnose(Diagnostic(node: ifConfig, message: StateTypeAttributeDiagnostic(name: "an attribute inside #if", allowed: advertised)))
            }
        }
    }

    private static func isAllowed(_ attribute: AttributeSyntax, allowed: Set<String>) -> Bool {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self), builtins.contains(identifier.name.text) {
            return true
        }
        return allowed.contains { PlainDataWalk.isProjectAttribute(attribute, named: $0) }
    }
}

struct StateTypeAttributeDiagnostic: DiagnosticMessage {
    let name: String
    let allowed: Set<String>

    var message: String {
        let macros = allowed.sorted().map { "@" + $0 }.joined(separator: ", ")
        return "\(name) can't be on a state type: a macro there can add members the PlainData check doesn't see; this type takes only \(macros) and attributes that add no members"
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftStateTreeMacros", id: "unknownStateTypeAttribute") }
    var severity: DiagnosticSeverity { .error }
}

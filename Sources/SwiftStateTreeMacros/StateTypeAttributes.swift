// The attributes a state type may carry (#100). An attached macro this project doesn't know can
// add members `@StateNodeBuilder` and the PlainData check never see: no marker check, no
// PlainData check and no field metadata. So a state type takes only this project's macros that
// belong there and built-in attributes that add no members.

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

    /// Built-in attributes that add no members.
    static let builtins: Set<String> = ["available", "usableFromInline", "frozen", "propertyWrapper", "preconcurrency", "_spi", "_documentation"]

    /// The modules a qualified spelling of an allowed macro may name.
    static let modules: Set<String> = ["SwiftStateTree", "SwiftStateTurns"]

    /// Diagnoses every attribute on a state type that isn't in `allowed` or `builtins`.
    ///
    /// The syntax shows only spellings. A bare `@SnapshotConvertible` is taken as this
    /// project's, so a macro of the user's own with that name passes; `@Other.SnapshotConvertible`
    /// is refused. An attribute inside `#if` is refused, since its condition can't be read here.
    static func diagnoseUnknown(
        _ attributes: AttributeListSyntax,
        allowed: Set<String>,
        in context: some MacroExpansionContext
    ) {
        for element in attributes {
            switch element {
            case .attribute(let attribute):
                if !isAllowed(attribute, allowed: allowed) {
                    context.diagnose(Diagnostic(
                        node: attribute,
                        message: StateTypeAttributeDiagnostic(name: "@" + attribute.attributeName.trimmedDescription)
                    ))
                }
            case .ifConfigDecl(let ifConfig):
                context.diagnose(Diagnostic(node: ifConfig, message: StateTypeAttributeDiagnostic(name: "an attribute inside #if")))
            }
        }
    }

    private static func isAllowed(_ attribute: AttributeSyntax, allowed: Set<String>) -> Bool {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            return allowed.contains(name) || builtins.contains(name)
        }
        if let member = attribute.attributeName.as(MemberTypeSyntax.self),
           let base = member.baseType.as(IdentifierTypeSyntax.self) {
            return modules.contains(base.name.text) && allowed.contains(member.name.text)
        }
        return false
    }
}

struct StateTypeAttributeDiagnostic: DiagnosticMessage {
    let name: String

    var message: String {
        "\(name) can't be on a state type: a macro there can add members the PlainData check doesn't see; a state type takes only @StateNodeBuilder, @SnapshotConvertible, @PlainData, @Payload and attributes that add no members"
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftStateTreeMacros", id: "unknownStateTypeAttribute") }
    var severity: DiagnosticSeverity { .error }
}

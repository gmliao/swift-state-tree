// The attributes a type that writes the PlainData witness may carry (#100, #837). An attached
// macro this project doesn't know can add members that the witness, the marker check and the
// field metadata never see. So such a type takes only this project's macros that belong there and
// built-in attributes that add no members.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Which of this project's macros checks a type's attributes. Exactly one per type, so a type
/// with two of them gets one set of diagnostics: `@StateNodeBuilder`, else `@SnapshotConvertible`,
/// else `@Payload`, else `@PlainData`.
public enum PlainDataAttributes {
    /// One macro's rule: the names it allows beside itself, the ones a refusal lists, and the
    /// noun the refusal uses for the type.
    public struct Rule: Sendable {
        /// Every project macro allowed beside this one. A name kept here only so that another
        /// macro's own refusal, which says what to do, is the one reported isn't advertised.
        public let allowed: Set<String>
        /// The names a refusal lists as allowed: those that are legitimate on the type.
        public let advertised: Set<String>
        /// "state type", "payload type", "PlainData type".
        public let noun: String
    }

    public static let stateNodeBuilder = Rule(
        allowed: ["StateNodeBuilder", "SnapshotConvertible", "PlainData"],
        advertised: ["StateNodeBuilder", "SnapshotConvertible"],
        noun: "state type"
    )

    /// Without `@StateNodeBuilder`: it yields its witness to `@PlainData` and `@Payload`, and
    /// `@Payload` refuses the pair on its own.
    public static let snapshotConvertible = Rule(
        allowed: ["SnapshotConvertible", "StateNodeBuilder", "PlainData", "Payload"],
        advertised: ["SnapshotConvertible", "StateNodeBuilder", "PlainData"],
        noun: "state type"
    )

    /// `@Payload` refuses `@PlainData` and `@SnapshotConvertible` beside it with its own message,
    /// and `@StateNodeBuilder` refuses `@Payload`.
    public static let payload = Rule(
        allowed: ["Payload", "PlainData", "SnapshotConvertible", "StateNodeBuilder"],
        advertised: ["Payload"],
        noun: "payload type"
    )

    /// `@SnapshotConvertible` beside it checks the type instead; `@Payload` and
    /// `@StateNodeBuilder` refuse `@PlainData` with their own messages.
    public static let plainData = Rule(
        allowed: ["PlainData", "SnapshotConvertible", "Payload", "StateNodeBuilder"],
        advertised: ["PlainData", "SnapshotConvertible"],
        noun: "PlainData type"
    )

    /// The project macros that check before `macro`, in the order above.
    private static let precedence = ["StateNodeBuilder", "SnapshotConvertible", "Payload", "PlainData"]

    /// Whether `macro` is the one that checks this type: no project macro that comes before it is
    /// on the type.
    public static func checks(_ macro: String, on attributes: AttributeListSyntax) -> Bool {
        guard let index = precedence.firstIndex(of: macro) else { return true }
        return !precedence[..<index].contains { PlainDataWalk.hasAttribute(named: $0, in: attributes) }
    }

    /// Built-in attributes that add no members.
    public static let builtins: Set<String> = [
        "available", "usableFromInline", "frozen", "propertyWrapper", "resultBuilder",
        "dynamicMemberLookup", "dynamicCallable", "preconcurrency", "_spi", "_documentation",
    ]

    /// Diagnoses every attribute on the type that isn't in `rule.allowed` or `builtins`.
    ///
    /// The syntax shows only spellings. A bare `@SnapshotConvertible` is taken as this
    /// project's, so a macro of the user's own with that name passes; a qualified spelling passes
    /// only with a module that declares or re-exports the macro (`PlainDataWalk.modules`). An
    /// attribute inside `#if` is refused, since its condition can't be read here.
    public static func diagnoseType(
        _ attributes: AttributeListSyntax,
        rule: Rule,
        in context: some MacroExpansionContext
    ) {
        for element in attributes {
            switch element {
            case .attribute(let attribute):
                if !isAllowed(attribute, allowed: rule.allowed) {
                    context.diagnose(Diagnostic(
                        node: attribute,
                        message: TypeAttributeDiagnostic(name: "@" + attribute.attributeName.trimmedDescription, rule: rule)
                    ))
                }
            case .ifConfigDecl(let ifConfig):
                context.diagnose(Diagnostic(node: ifConfig, message: TypeAttributeDiagnostic(name: "an attribute inside #if", rule: rule)))
            }
        }
    }

    /// Built-in attributes a member other than a stored property may carry: none adds a
    /// declaration. `TaskLocal` is a property wrapper, and on a `static` property its storage is
    /// static too.
    public static let memberBuiltins: Set<String> = [
        "available", "inlinable", "inline", "usableFromInline", "discardableResult", "_spi",
        "preconcurrency", "backDeployed", "_alwaysEmitIntoClient", "_disfavoredOverload", "_documentation",
        "_effects", "_transparent", "_optimize", "_semantics", "_specialize", "warn_unqualified_access",
        "nonobjc", "objc", "MainActor", "TaskLocal", "concurrent", "Sendable",
    ]

    /// The project macros a nested type may carry: each writes the nested type's own members and
    /// extensions, never a peer of the outer type's.
    static let nestedTypeMacros = ["StateNodeBuilder", "SnapshotConvertible", "Payload", "PlainData"]

    /// Diagnoses every attribute on a member that could add declarations to the type: on a
    /// function, an initializer, a subscript, a computed or `static` property, an enum case, a
    /// typealias or a nested type, in `#if` clauses too. A peer macro there can add a stored
    /// property that nothing checks. Stored instance properties are left to the PlainData walk,
    /// which refuses every attribute on them that isn't storage-neutral or read through, and
    /// freestanding expansions too, which it refuses.
    public static func diagnoseMembers(
        _ members: MemberBlockItemListSyntax,
        rule: Rule,
        in context: some MacroExpansionContext
    ) {
        for member in members {
            let decl = member.decl
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if case .decls(let nested) = clause.elements { diagnoseMembers(nested, rule: rule, in: context) }
                }
                continue
            }
            if let variable = decl.as(VariableDeclSyntax.self), PlainDataWalk.isStoredInstance(variable) { continue }
            guard let attributes = decl.asProtocol(WithAttributesSyntax.self)?.attributes else { continue }
            let isType = decl.is(StructDeclSyntax.self) || decl.is(EnumDeclSyntax.self)
                || decl.is(ClassDeclSyntax.self) || decl.is(ActorDeclSyntax.self) || decl.is(ProtocolDeclSyntax.self)
            for element in attributes {
                switch element {
                case .attribute(let attribute):
                    if isAllowedOnMember(attribute, isType: isType) { continue }
                    context.diagnose(Diagnostic(
                        node: attribute,
                        message: MemberAttributeDiagnostic(name: "@" + attribute.attributeName.trimmedDescription, member: memberName(decl), noun: rule.noun, isNestedType: isType)
                    ))
                case .ifConfigDecl(let ifConfig):
                    context.diagnose(Diagnostic(
                        node: ifConfig,
                        message: MemberAttributeDiagnostic(name: "an attribute inside #if", member: memberName(decl), noun: rule.noun, isNestedType: isType)
                    ))
                }
            }
        }
    }

    private static func isAllowedOnMember(_ attribute: AttributeSyntax, isType: Bool) -> Bool {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            if memberBuiltins.contains(name) || (isType && builtins.contains(name)) { return true }
        }
        return isType && nestedTypeMacros.contains { PlainDataWalk.isProjectAttribute(attribute, named: $0) }
    }

    /// The member as a diagnostic names it: `cost()`, `init(...)`, `subscript(...)`, `view`,
    /// `case a`, `Inner`.
    private static func memberName(_ decl: DeclSyntax) -> String {
        if let function = decl.as(FunctionDeclSyntax.self) { return function.name.text + "()" }
        if decl.is(InitializerDeclSyntax.self) { return "init(...)" }
        if decl.is(SubscriptDeclSyntax.self) { return "subscript(...)" }
        if let variable = decl.as(VariableDeclSyntax.self) {
            return variable.bindings.map { $0.pattern.trimmedDescription }.joined(separator: ", ")
        }
        if let cases = decl.as(EnumCaseDeclSyntax.self) {
            return "case " + cases.elements.map { $0.name.text }.joined(separator: ", ")
        }
        if let alias = decl.as(TypeAliasDeclSyntax.self) { return alias.name.text }
        if let named = decl.asProtocol(NamedDeclSyntax.self) { return named.name.text }
        return "member"
    }

    private static func isAllowed(_ attribute: AttributeSyntax, allowed: Set<String>) -> Bool {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self), builtins.contains(identifier.name.text) {
            return true
        }
        return allowed.contains { PlainDataWalk.isProjectAttribute(attribute, named: $0) }
    }
}

struct TypeAttributeDiagnostic: DiagnosticMessage {
    let name: String
    let rule: PlainDataAttributes.Rule

    var message: String {
        let macros = rule.advertised.sorted().map { "@" + $0 }.joined(separator: ", ")
        return "\(name) can't be on a \(rule.noun): a macro there can add members the PlainData check doesn't see; this type takes only \(macros) and attributes that add no members"
    }

    var diagnosticID: MessageID { MessageID(domain: "PlainDataMacroSupport", id: "unknownTypeAttribute") }
    var severity: DiagnosticSeverity { .error }
}

struct MemberAttributeDiagnostic: DiagnosticMessage {
    let name: String
    let member: String
    let noun: String
    /// A nested type also takes the project's own macros (`nestedTypeMacros`), so its message
    /// names them.
    let isNestedType: Bool

    var message: String {
        let base = "\(name) on '\(member)' can't be in a \(noun): a macro attached to a member can add stored members the PlainData check doesn't see; members take only built-in attributes that add none, such as @available and @inlinable"
        guard isNestedType else { return base }
        let macros = PlainDataAttributes.nestedTypeMacros.sorted().map { "@" + $0 }.joined(separator: ", ")
        return base + "; a nested type also takes \(macros)"
    }

    var diagnosticID: MessageID { MessageID(domain: "PlainDataMacroSupport", id: "unknownMemberAttribute") }
    var severity: DiagnosticSeverity { .error }
}

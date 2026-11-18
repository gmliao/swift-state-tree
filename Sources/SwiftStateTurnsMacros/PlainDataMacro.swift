// `@PlainData`: the conformance, and one compile-time check per stored property or associated
// value. A syntactic macro can't see types, so what it can't check it refuses with a diagnostic.

import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct PlainDataMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let generics: GenericParameterClauseSyntax?
        var checked: [TypeSyntax] = []
        var failed = false

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            generics = structDecl.genericParameterClause
            for member in structDecl.memberBlock.members {
                guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
                if variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
                if let weak = variable.modifiers.first(where: {
                    $0.name.tokenKind == .keyword(.weak) || $0.name.tokenKind == .keyword(.unowned)
                }) {
                    context.diagnose(Diagnostic(node: weak, message: PlainDataDiagnostic.reference))
                    failed = true
                    continue
                }
                if let wrapper = variable.attributes.first {
                    context.diagnose(Diagnostic(node: wrapper, message: PlainDataDiagnostic.wrapper))
                    failed = true
                    continue
                }
                for binding in variable.bindings {
                    if isComputed(binding) { continue }
                    guard binding.pattern.is(IdentifierPatternSyntax.self) else {
                        context.diagnose(Diagnostic(node: binding.pattern, message: PlainDataDiagnostic.pattern))
                        failed = true
                        continue
                    }
                    guard let annotation = binding.typeAnnotation?.type ?? typeOfNextBinding(binding, in: variable) else {
                        context.diagnose(Diagnostic(node: binding.pattern, message: PlainDataDiagnostic.annotation(binding.pattern.trimmedDescription)))
                        failed = true
                        continue
                    }
                    if !accept(annotation, context) { failed = true; continue }
                    checked.append(annotation.trimmed)
                }
            }
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            generics = enumDecl.genericParameterClause
            for member in enumDecl.memberBlock.members {
                guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in cases.elements {
                    for parameter in element.parameterClause?.parameters ?? [] {
                        if !accept(parameter.type, context) { failed = true; continue }
                        checked.append(parameter.type.trimmed)
                    }
                }
            }
        } else {
            context.diagnose(Diagnostic(node: node, message: PlainDataDiagnostic.notValue))
            return []
        }
        if failed { return [] }

        let constraints = (generics?.parameters ?? []).map { "\($0.name.text): PlainData" }
        let whereClause = constraints.isEmpty ? "" : " where " + constraints.joined(separator: ", ")
        let conformance = protocols.isEmpty ? "" : ": PlainData"
        let checks = checked.map { "PlainDataCheck.field((\($0)).self)" }.joined(separator: "\n")
        let decl: DeclSyntax = """
            extension \(type.trimmed)\(raw: conformance)\(raw: whereClause) {
                /// Compiled, never called: each line fails to compile unless its type is PlainData.
                static func _plainDataCheck() {
                    \(raw: checks)
                }
            }
            """
        guard let ext = decl.as(ExtensionDeclSyntax.self) else { return [] }
        return [ext]
    }

    /// `var a, b: Int` gives `a` the type of the next annotated binding.
    private static func typeOfNextBinding(_ binding: PatternBindingSyntax, in variable: VariableDeclSyntax) -> TypeSyntax? {
        guard binding.initializer == nil else { return nil }
        var seen = false
        for other in variable.bindings {
            if other.id == binding.id { seen = true; continue }
            if seen, let type = other.typeAnnotation?.type { return type }
            if seen, other.initializer != nil { return nil }
        }
        return nil
    }

    private static func isComputed(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock?.accessors else { return false }
        switch accessors {
        case .getter:
            return true
        case .accessors(let list):
            // Observers (`willSet`/`didSet`) keep the property stored.
            return list.contains {
                [.keyword(.get), .keyword(.set), .keyword(._read), .keyword(._modify)].contains($0.accessorSpecifier.tokenKind)
            }
        }
    }

    /// Refuses what can call through or change behind its holder, which a conformance check
    /// can't refuse by itself: function types, existentials and opaque types, and tuples
    /// (which can't conform to a protocol at all).
    private static func accept(_ type: TypeSyntax, _ context: some MacroExpansionContext) -> Bool {
        let visitor = RefusedTypeVisitor(viewMode: .sourceAccurate)
        visitor.walk(type)
        for (node, message) in visitor.refused {
            context.diagnose(Diagnostic(node: node, message: message))
        }
        return visitor.refused.isEmpty
    }
}

private final class RefusedTypeVisitor: SyntaxVisitor {
    var refused: [(Syntax, PlainDataDiagnostic)] = []

    override func visit(_ node: FunctionTypeSyntax) -> SyntaxVisitorContinueKind {
        refused.append((Syntax(node), .closure))
        return .skipChildren
    }

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        refused.append((Syntax(node), .existential))
        return .skipChildren
    }

    override func visit(_ node: TupleTypeSyntax) -> SyntaxVisitorContinueKind {
        // `(T)` is a parenthesized type, not a tuple.
        if node.elements.count == 1, node.elements.first?.firstName == nil { return .visitChildren }
        refused.append((Syntax(node), .tuple))
        return .skipChildren
    }
}

enum PlainDataDiagnostic: DiagnosticMessage {
    case notValue
    case annotation(String)
    case pattern
    case reference
    case wrapper
    case closure
    case existential
    case tuple

    var message: String {
        switch self {
        case .notValue: "@PlainData applies to a struct or an enum; a class, an actor or a protocol isn't plain data"
        case .annotation(let name): "stored property '\(name)' needs a type annotation for @PlainData to check it"
        case .pattern: "@PlainData checks one stored property per binding; split the tuple pattern"
        case .reference: "a weak or unowned property holds a reference, which isn't plain data"
        case .wrapper: "@PlainData can't check a property wrapper's storage; store the value itself"
        case .closure: "a function type isn't plain data: it can call through to anything"
        case .existential: "an existential or opaque type isn't plain data: its value can be a class"
        case .tuple: "a tuple can't conform to PlainData; use PlainPair or a @PlainData struct"
        }
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftStateTurnsMacros", id: "\(self)") }
    var severity: DiagnosticSeverity { .error }
}

@main
struct SwiftStateTurnsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PlainDataMacro.self]
}

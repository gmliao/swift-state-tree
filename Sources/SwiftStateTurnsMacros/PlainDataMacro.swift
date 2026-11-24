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
        var failed = false
        let checks: String

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            generics = structDecl.genericParameterClause
            checks = checkLines(structDecl.memberBlock.members, isEnum: false, failed: &failed, context)
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            generics = enumDecl.genericParameterClause
            checks = checkLines(enumDecl.memberBlock.members, isEnum: true, failed: &failed, context)
        } else {
            context.diagnose(Diagnostic(node: node, message: PlainDataDiagnostic.notValue))
            return []
        }
        if failed { return [] }

        // The expansion names the core's module, so a namesake type in the user's module can't
        // stand in for `PlainData` or `PlainDataCheck`.
        let constraints = (generics?.parameters ?? []).map { "\($0.name.text): SwiftStateTurns.PlainData" }
        let whereClause = constraints.isEmpty ? "" : " where " + constraints.joined(separator: ", ")
        let conformance = protocols.isEmpty ? "" : ": SwiftStateTurns.PlainData"
        let access = witnessAccess(of: declaration, in: context)
        let decl: DeclSyntax = """
            extension \(type.trimmed)\(raw: conformance)\(raw: whereClause) {
                /// Compiled, never called: each line fails to compile unless its type is PlainData.
                \(raw: access)static func _plainDataCheck() {
                    \(raw: checks)
                }
            }
            """
        guard let ext = decl.as(ExtensionDeclSyntax.self) else { return [] }
        return [ext]
    }

    /// The witness is as visible as the type: a public type's conformance needs a public one, and
    /// an internal type's can't have one when the extension carries internal requirements. A
    /// type with no access modifier of its own that is a member of an extension takes the
    /// extension's (`public extension Outer { struct Inner }` makes `Inner` public), and a
    /// `@usableFromInline` type's witness is `@usableFromInline` too.
    private static func witnessAccess(of declaration: some DeclGroupSyntax, in context: some MacroExpansionContext) -> String {
        let inlinable = declaration.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "usableFromInline"
        }
        let prefix = inlinable ? "@usableFromInline " : ""
        if let own = explicitAccess(declaration.modifiers) { return prefix + own }
        if let parent = context.lexicalContext.first?.as(ExtensionDeclSyntax.self),
           let inherited = explicitAccess(parent.modifiers) {
            return prefix + inherited
        }
        return prefix
    }

    /// The witness's modifier for an access modifier in `modifiers`, or nil if there is none.
    private static func explicitAccess(_ modifiers: DeclModifierListSyntax) -> String? {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            case .keyword(.internal), .keyword(.fileprivate), .keyword(.private): return ""
            default: continue
            }
        }
        return nil
    }

    /// One check per stored property (or associated value), in member order. A member inside an
    /// `#if` block is checked under the same conditions: every clause is read, so a member that
    /// only one configuration compiles is still checked there, and a type that only exists in
    /// that configuration is named only under its condition.
    private static func checkLines(
        _ members: MemberBlockItemListSyntax,
        isEnum: Bool,
        failed: inout Bool,
        _ context: some MacroExpansionContext
    ) -> String {
        var lines: [String] = []
        for member in members {
            if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                var block: [String] = []
                for clause in ifConfig.clauses {
                    let keyword = clause.poundKeyword.text
                    block.append(clause.condition.map { "\(keyword) \($0.trimmedDescription)" } ?? keyword)
                    if case .decls(let nested) = clause.elements {
                        let inner = checkLines(nested, isEnum: isEnum, failed: &failed, context)
                        if !inner.isEmpty { block.append(inner) }
                    }
                }
                block.append("#endif")
                lines.append(block.joined(separator: "\n"))
                continue
            }
            if isEnum {
                guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in cases.elements {
                    for parameter in element.parameterClause?.parameters ?? [] {
                        guard let found = checks(parameter.type, context) else { failed = true; continue }
                        lines.append(contentsOf: found)
                    }
                }
                continue
            }
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
                guard let found = checks(annotation, context) else { failed = true; continue }
                lines.append(contentsOf: found)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func check(_ type: TypeSyntax) -> String {
        "SwiftStateTurns.PlainDataCheck.field((\(type.trimmed)).self)"
    }

    /// The checks for one field's type, or nil after a diagnostic. A type with no `any` gets one
    /// `field` check. An `any P` gets an `existential` check, which compiles only when `P`
    /// refines `PlainData`; inside `Optional`, `Array`, `ContiguousArray` or a `Dictionary`'s
    /// value the element is checked instead of the wrapper, which can't conform. Anywhere else,
    /// the macro can't see what holds it, so it is refused.
    private static func checks(_ type: TypeSyntax, _ context: some MacroExpansionContext) -> [String]? {
        guard containsAny(type) else { return accept(type, context) ? [check(type)] : nil }
        if let paren = type.as(TupleTypeSyntax.self), paren.elements.count == 1,
           let only = paren.elements.first, only.firstName == nil {
            return checks(only.type, context)
        }
        if let existential = type.as(SomeOrAnyTypeSyntax.self), existential.someOrAnySpecifier.tokenKind == .keyword(.any) {
            if existential.constraint.is(MetatypeTypeSyntax.self) {
                context.diagnose(Diagnostic(node: existential, message: PlainDataDiagnostic.metatype))
                return nil
            }
            guard accept(existential.constraint, context) else { return nil }
            // The type goes in the closure's parameter: `(any (P & Q)).self` doesn't parse as an
            // expression, and the parameter takes every spelling.
            return ["SwiftStateTurns.PlainDataCheck.existential { (value: \(existential.trimmed)) in value }"]
        }
        // A closure or a tuple holding an existential is refused as a closure or a tuple.
        var bare = type
        while let attributed = bare.as(AttributedTypeSyntax.self) { bare = attributed.baseType }
        if bare.is(FunctionTypeSyntax.self) {
            context.diagnose(Diagnostic(node: type, message: PlainDataDiagnostic.closure))
            return nil
        }
        if bare.is(TupleTypeSyntax.self) {
            context.diagnose(Diagnostic(node: type, message: PlainDataDiagnostic.tuple))
            return nil
        }
        if let optional = type.as(OptionalTypeSyntax.self) { return checks(optional.wrappedType, context) }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return checks(optional.wrappedType, context) }
        if let array = type.as(ArrayTypeSyntax.self) { return checks(array.element, context) }
        if let dictionary = type.as(DictionaryTypeSyntax.self) { return pair(dictionary.key, dictionary.value, context) }
        if let found = standardWrapper(type) {
            guard let inner = wrapperChecks(found, context) else { return nil }
            // The name, bare or `Swift.`-qualified, can be the module's own type (a namesake, a
            // typealias, or a module-level `enum Swift`). The helper's parameter is the standard
            // library's type, spelled inside SwiftStateTurns, so only that type compiles.
            return inner + ["SwiftStateTurns.PlainDataCheck.\(found.helper)((\(type.trimmed)).self)"]
        }
        context.diagnose(Diagnostic(node: type, message: PlainDataDiagnostic.existentialInGeneric))
        return nil
    }

    /// `Optional<…>`, `Array<…>`, `ContiguousArray<…>` or `Dictionary<…, …>` spelled out, bare or
    /// as `Swift.…`: its name, its arguments, and the `PlainDataCheck` helper that pins it.
    private static func standardWrapper(_ type: TypeSyntax) -> (name: String, arguments: [TypeSyntax], helper: String)? {
        let name: String
        let clause: GenericArgumentClauseSyntax?
        if let named = type.as(IdentifierTypeSyntax.self) {
            (name, clause) = (named.name.text, named.genericArgumentClause)
        } else if let member = type.as(MemberTypeSyntax.self), member.baseType.trimmedDescription == "Swift" {
            (name, clause) = (member.name.text, member.genericArgumentClause)
        } else {
            return nil
        }
        guard let clause else { return nil }
        let arguments: [TypeSyntax] = clause.arguments.compactMap {
            if case .type(let argument) = $0.argument { return argument }
            return nil
        }
        switch (name, arguments.count) {
        case ("Optional", 1): return (name, arguments, "optional")
        case ("Array", 1): return (name, arguments, "array")
        case ("ContiguousArray", 1): return (name, arguments, "contiguousArray")
        case ("Dictionary", 2): return (name, arguments, "dictionary")
        default: return nil
        }
    }

    private static func wrapperChecks(
        _ wrapper: (name: String, arguments: [TypeSyntax], helper: String),
        _ context: some MacroExpansionContext
    ) -> [String]? {
        wrapper.name == "Dictionary"
            ? pair(wrapper.arguments[0], wrapper.arguments[1], context)
            : checks(wrapper.arguments[0], context)
    }

    /// A dictionary's checks: its key as a whole, which can't hold an existential (an existential
    /// key isn't `Hashable`), and its value as above.
    private static func pair(_ key: TypeSyntax, _ value: TypeSyntax, _ context: some MacroExpansionContext) -> [String]? {
        if containsAny(key) {
            context.diagnose(Diagnostic(node: key, message: PlainDataDiagnostic.existentialInGeneric))
            return nil
        }
        guard accept(key, context), let valueChecks = checks(value, context) else { return nil }
        return [check(key)] + valueChecks
    }

    private static func containsAny(_ type: TypeSyntax) -> Bool {
        let finder = AnyFinder(viewMode: .sourceAccurate)
        finder.walk(type)
        return finder.found
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

    // Foundation's value types aren't plain data here: the diagnostic names what to store instead.
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.genericArgumentClause == nil, let name = PlainDataDiagnostic.foundationReplacement(node.name.text) {
            refused.append((Syntax(node), .foundation(node.name.text, name)))
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.baseType.trimmedDescription == "Foundation", let name = PlainDataDiagnostic.foundationReplacement(node.name.text) {
            refused.append((Syntax(node), .foundation(node.name.text, name)))
            return .skipChildren
        }
        // The base names where the type is declared, not a type stored here: `Date.Part` in the
        // module's own `enum Date` isn't Foundation's `Date`. Only generic arguments are stored.
        walkArguments(of: node.baseType)
        if let clause = node.genericArgumentClause { walk(clause) }
        return .skipChildren
    }

    private func walkArguments(of base: TypeSyntax) {
        if let member = base.as(MemberTypeSyntax.self) {
            walkArguments(of: member.baseType)
            if let clause = member.genericArgumentClause { walk(clause) }
        } else if let named = base.as(IdentifierTypeSyntax.self) {
            if let clause = named.genericArgumentClause { walk(clause) }
        } else {
            walk(base)
        }
    }

    override func visit(_ node: TupleTypeSyntax) -> SyntaxVisitorContinueKind {
        // `(T)` is a parenthesized type, not a tuple.
        if node.elements.count == 1, node.elements.first?.firstName == nil { return .visitChildren }
        refused.append((Syntax(node), .tuple))
        return .skipChildren
    }
}

/// Finds an `any` existential anywhere in a type.
private final class AnyFinder: SyntaxVisitor {
    var found = false

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.someOrAnySpecifier.tokenKind == .keyword(.any) { found = true }
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
    case metatype
    case existentialInGeneric
    case foundation(String, String)

    /// What to store instead of a Foundation value type, or nil for any other name.
    static func foundationReplacement(_ name: String) -> String? {
        switch name {
        case "Date": "an Int64 of milliseconds, or read the turn's `now`"
        case "UUID": "a String, or a project ID type"
        case "URL": "a String"
        case "Decimal": "an integer in the smallest unit, or a String"
        default: nil
        }
    }

    var message: String {
        switch self {
        case .notValue: "@PlainData applies to a struct or an enum; a class, an actor or a protocol isn't plain data"
        case .annotation(let name): "stored property '\(name)' needs a type annotation for @PlainData to check it"
        case .pattern: "@PlainData checks one stored property per binding; split the tuple pattern"
        case .reference: "a weak or unowned property holds a reference, which isn't plain data"
        case .wrapper: "@PlainData can't check a property wrapper's storage; store the value itself"
        case .closure: "a function type isn't plain data: it can call through to anything"
        case .existential: "an opaque type isn't plain data, and neither is an existential nested in it: its value can be a class"
        case .metatype: "a metatype isn't plain data; store a name or an id that a lookup turns into the type"
        case .existentialInGeneric: "@PlainData checks an existential only as a field, or inside Optional, Array, ContiguousArray or a Dictionary's value; it can't see what this type does with it"
        case .foundation(let type, let replacement): "\(type) isn't plain data; store \(replacement) (for your own type of that name, qualify it with its module)"
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

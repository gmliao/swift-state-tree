// The field walk `@PlainData` uses, shared with SwiftStateTree's macros: the members of a struct
// or enum in, the statements of its `check(_ value: inout Self)` out, or a diagnostic for what a
// syntactic macro can't check. `@Payload` and `@StateNodeBuilder` call it.

@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// The member and type walks behind `@PlainData`'s `_plainDataCheck`.
public enum PlainDataWalk {
    /// One check per stored property (or associated value), in member order. A member inside an
    /// `#if` block is checked under the same conditions: every clause is read, so a member that
    /// only one configuration compiles is still checked there, and a type that only exists in
    /// that configuration is named only under its condition.
    ///
    /// - Parameter readThrough: property wrappers whose wrapped value is checked, spelled bare or
    ///   qualified by a module that exports them (`isProjectAttribute`: `Sync` matches `@Sync`
    ///   and `@SwiftStateTree.Sync`, not `@Other.Sync`). The name is only a spelling, so a
    ///   read-through field is checked twice: `value._name`, the wrapper's storage, which compiles
    ///   only when the wrapper is `PlainData` (the library's `Sync` and `Internal` are, and a
    ///   namesake that holds a class isn't), and `value.name`, the wrapped value, annotated or
    ///   not. Any other wrapper is refused. Empty for `@PlainData` and `@Payload`, which refuse
    ///   every wrapper.
    ///
    /// A freestanding macro expansion among the members is refused: the storage it expands to
    /// isn't in the syntax this walk reads. `#warning` and `#error` are compiler directives and
    /// pass.
    public static func checkLines(
        _ members: MemberBlockItemListSyntax,
        isEnum: Bool,
        readThrough: Set<String> = [],
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
                        let inner = checkLines(nested, isEnum: isEnum, readThrough: readThrough, failed: &failed, context)
                        if !inner.isEmpty { block.append(inner) }
                    }
                }
                block.append("#endif")
                lines.append(block.joined(separator: "\n"))
                continue
            }
            if let expansion = member.decl.as(MacroExpansionDeclSyntax.self) {
                // `#warning` and `#error` are compiler directives that parse as expansions; they
                // add no member, and an `#error` in an inactive `#if` branch is honest code.
                if compilerDirectives.contains(expansion.macroName.text) { continue }
                context.diagnose(Diagnostic(node: expansion, message: PlainDataDiagnostic.macroExpansion))
                failed = true
                continue
            }
            if isEnum {
                guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in cases.elements {
                    let parameters = Array(element.parameterClause?.parameters ?? [])
                    if parameters.isEmpty { continue }
                    var inner: [String] = []
                    for (index, parameter) in parameters.enumerated() {
                        guard let found = checks(parameter.type, "v\(index)", context) else { failed = true; continue }
                        inner.append(contentsOf: found)
                    }
                    let bindings = parameters.indices.map { "v\($0)" }.joined(separator: ", ")
                    lines.append("if case let .\(element.name.trimmed)(\(bindings)) = value {\n\(inner.joined(separator: "\n"))\n}")
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
            // A computed property has no storage, whatever its attributes (`@inlinable`).
            if variable.bindings.allSatisfy(isComputed) { continue }
            // Any other attribute (a property wrapper, an attached macro) can change the storage.
            // A wrapper in `readThrough` is read through: its wrapped value is checked.
            if let wrapper = variable.attributes.first(where: { !isStorageNeutral($0) && !isReadThrough($0, readThrough) }) {
                let message = readThrough.isEmpty
                    ? PlainDataDiagnostic.wrapper
                    : PlainDataDiagnostic.wrapperNotRead(readThrough.sorted())
                context.diagnose(Diagnostic(node: wrapper, message: message))
                failed = true
                continue
            }
            let isWrapped = variable.attributes.contains { isReadThrough($0, readThrough) }
            for binding in variable.bindings {
                if isComputed(binding) { continue }
                guard binding.pattern.is(IdentifierPatternSyntax.self) else {
                    context.diagnose(Diagnostic(node: binding.pattern, message: PlainDataDiagnostic.pattern))
                    failed = true
                    continue
                }
                if isWrapped, let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                    // The wrapper's storage: the attribute's name doesn't say which wrapper it is.
                    lines.append(check("value._\(storageName(pattern.identifier))"))
                }
                guard let annotation = binding.typeAnnotation?.type ?? typeOfNextBinding(binding, in: variable) else {
                    // With no annotation the walk can't choose a check by type, so it reads the
                    // value as it is: the storage line above covers the wrapper, and this line
                    // covers what its `wrappedValue` returns.
                    if isWrapped, let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                        lines.append(check("value.\(pattern.identifier.trimmed)"))
                        continue
                    }
                    context.diagnose(Diagnostic(node: binding.pattern, message: PlainDataDiagnostic.annotation(binding.pattern.trimmedDescription)))
                    failed = true
                    continue
                }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      let found = checks(annotation, "value.\(pattern.identifier.trimmed)", context)
                else { failed = true; continue }
                lines.append(contentsOf: found)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Built-in attributes that leave a stored property's storage as declared.
    private static let storageNeutralAttributes: Set<String> = ["usableFromInline", "available", "_spi", "_documentation"]

    private static func isStorageNeutral(_ element: AttributeListSyntax.Element) -> Bool {
        guard case .attribute(let attribute) = element else { return false }
        return storageNeutralAttributes.contains(attribute.attributeName.trimmedDescription)
    }

    /// The freestanding expansions that are compiler directives, not macros that add members.
    private static let compilerDirectives: Set<String> = ["warning", "error"]

    private static func isReadThrough(_ element: AttributeListSyntax.Element, _ names: Set<String>) -> Bool {
        guard !names.isEmpty, case .attribute(let attribute) = element else { return false }
        return names.contains { isProjectAttribute(attribute, named: $0) }
    }

    /// The modules that declare or re-export SwiftStateTree's attributes.
    private static let stateTreeModules: Set<String> = ["SwiftStateTree", "SwiftStateTreeNIO"]

    /// The modules a qualified spelling of this project's attribute `name` may name: the module
    /// that declares it and the modules that re-export it.
    public static func modules(declaring name: String) -> Set<String> {
        name == "PlainData" ? stateTreeModules.union(["SwiftStateTurns"]) : stateTreeModules
    }

    /// Whether `attribute` spells this project's attribute `name`: bare, or qualified by a module
    /// that declares or re-exports it (`@SwiftStateTree.Sync`, `@SwiftStateTurns.PlainData`).
    /// `@Other.Sync` isn't. The syntax shows only spellings, so a bare namesake passes.
    public static func isProjectAttribute(_ attribute: AttributeSyntax, named name: String) -> Bool {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
            return identifier.name.text == name
        }
        if let member = attribute.attributeName.as(MemberTypeSyntax.self),
           let base = member.baseType.as(IdentifierTypeSyntax.self) {
            return member.name.text == name && modules(declaring: name).contains(base.name.text)
        }
        return false
    }

    /// Whether `attributes` holds this project's attribute `name`, as `isProjectAttribute` spells it.
    public static func hasAttribute(named name: String, in attributes: AttributeListSyntax) -> Bool {
        attributes.contains {
            guard case .attribute(let attribute) = $0 else { return false }
            return isProjectAttribute(attribute, named: name)
        }
    }

    /// A wrapped property's storage name, `_name`, without the backticks of an escaped name.
    private static func storageName(_ identifier: TokenSyntax) -> String {
        String(identifier.text.filter { $0 != "`" })
    }

    private static func check(_ value: String) -> String {
        "SwiftStateTurns.PlainDataCheck.field(\(value))"
    }

    /// The checks for one stored value, read by the expression `value`, or nil after a
    /// diagnostic. The spelled type only chooses the checks; each check reads the value, so the
    /// compiler checks the type the value really has. A type with no `any` gets one `field` check.
    /// An `any P` gets an `existential` check, which compiles only when `P` refines `PlainData`;
    /// inside `Optional`, `Array`, `ContiguousArray` or a `Dictionary`'s value the elements are
    /// checked instead of the wrapper, which can't conform. Anywhere else, the macro can't see
    /// what holds it, so it is refused.
    public static func checks(_ type: TypeSyntax, _ value: String, _ context: some MacroExpansionContext) -> [String]? {
        guard containsAny(type) else { return accept(type, context) ? [check(value)] : nil }
        if let paren = type.as(TupleTypeSyntax.self), paren.elements.count == 1,
           let only = paren.elements.first, only.firstName == nil {
            return checks(only.type, value, context)
        }
        if let existential = type.as(SomeOrAnyTypeSyntax.self), existential.someOrAnySpecifier.tokenKind == .keyword(.any) {
            if existential.constraint.is(MetatypeTypeSyntax.self) {
                context.diagnose(Diagnostic(node: existential, message: PlainDataDiagnostic.metatype))
                return nil
            }
            guard accept(existential.constraint, context) else { return nil }
            return ["SwiftStateTurns.PlainDataCheck.existential(\(value))"]
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
        // A wrapper's helper takes the standard library's type, spelled inside SwiftStateTurns,
        // so a value of the module's own namesake (or of an alias to another type) doesn't
        // compile, and passes each element to the closure, whose checks read it as `$0` (a
        // dictionary's key as `$0`, its value as `$1`).
        if let optional = type.as(OptionalTypeSyntax.self) { return wrap("optional", [optional.wrappedType], value, context) }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return wrap("optional", [optional.wrappedType], value, context) }
        if let array = type.as(ArrayTypeSyntax.self) { return wrap("array", [array.element], value, context) }
        if let dictionary = type.as(DictionaryTypeSyntax.self) { return wrap("dictionary", [dictionary.key, dictionary.value], value, context) }
        if let found = standardWrapper(type) { return wrap(found.helper, found.arguments, value, context) }
        context.diagnose(Diagnostic(node: type, message: PlainDataDiagnostic.existentialInGeneric))
        return nil
    }

    /// `PlainDataCheck.<helper>(value) { … }` with the element checks inside. A dictionary's key
    /// is checked as a whole: it can't hold an existential (an existential key isn't `Hashable`).
    private static func wrap(_ helper: String, _ arguments: [TypeSyntax], _ value: String, _ context: some MacroExpansionContext) -> [String]? {
        var inner: [String] = []
        if arguments.count == 2 {
            let key = arguments[0]
            if containsAny(key) {
                context.diagnose(Diagnostic(node: key, message: PlainDataDiagnostic.existentialInGeneric))
                return nil
            }
            guard accept(key, context), let valueChecks = checks(arguments[1], "$1", context) else { return nil }
            inner = [check("$0")] + valueChecks
        } else {
            guard let elementChecks = checks(arguments[0], "$0", context) else { return nil }
            inner = elementChecks
        }
        return ["SwiftStateTurns.PlainDataCheck.\(helper)(\(value)) { \(inner.joined(separator: "; ")) }"]
    }

    /// `Optional<…>`, `Array<…>`, `ContiguousArray<…>` or `Dictionary<…, …>` spelled out, bare or
    /// as `Swift.…`: its name, its arguments, and the `PlainDataCheck` helper for it. The name can
    /// be the module's own type (a namesake, a typealias, a module-level `enum Swift`); the
    /// helper then doesn't compile.
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

    /// Whether a binding has no storage: a getter, or `get`/`set`/`_read`/`_modify` accessors.
    /// Observers (`willSet`/`didSet`) keep it stored.
    public static func isComputed(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock?.accessors else { return false }
        switch accessors {
        case .getter:
            return true
        case .accessors(let list):
            // Stored only when every accessor is an observer (`willSet`/`didSet`). Any other
            // accessor (`get`, `set`, `_read`, `_modify`, or a newer one) makes it computed.
            return !list.allSatisfy {
                [.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind)
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

public enum PlainDataDiagnostic: DiagnosticMessage {
    case notValue
    case annotation(String)
    case pattern
    case reference
    case wrapper
    /// A property wrapper other than the ones a macro reads through (`@StateNodeBuilder`: `Sync`,
    /// `Internal`).
    case wrapperNotRead([String])
    case closure
    case existential
    case tuple
    case metatype
    case existentialInGeneric
    case foundation(String, String)
    case sharedCaseName(String)
    /// A freestanding macro expansion among a checked type's members.
    case macroExpansion

    /// What to store instead of a Foundation value type, or nil for any other name.
    public static func foundationReplacement(_ name: String) -> String? {
        switch name {
        case "Date": "an Int64 of milliseconds, or read the turn's `now`"
        case "UUID": "a String, or a project ID type"
        case "URL": "a String"
        case "Decimal": "an integer in the smallest unit, or a String"
        default: nil
        }
    }

    public var message: String {
        switch self {
        case .notValue: "@PlainData applies to a struct or an enum; a class, an actor or a protocol isn't plain data"
        case .annotation(let name): "stored property '\(name)' needs a type annotation for @PlainData to check it"
        case .pattern: "@PlainData checks one stored property per binding; split the tuple pattern"
        case .reference: "a weak or unowned property holds a reference, which isn't plain data"
        case .wrapper: "@PlainData can't check a property wrapper's storage; store the value itself"
        case .wrapperNotRead(let names): "the PlainData check reads only \(names.map { "@" + $0 }.joined(separator: " and ")) fields; another property wrapper's storage can't be checked"
        case .closure: "a function type isn't plain data: it can call through to anything"
        case .existential: "an opaque type isn't plain data, and neither is an existential nested in it: its value can be a class"
        case .metatype: "a metatype isn't plain data; store a name or an id that a lookup turns into the type"
        case .existentialInGeneric: "@PlainData checks an existential only as a field, or inside Optional, Array, ContiguousArray or a Dictionary's value; it can't see what this type does with it"
        case .foundation(let type, let replacement): "\(type) isn't plain data; store \(replacement) (for your own type of that name, qualify it with its module)"
        case .tuple: "a tuple can't conform to PlainData; use PlainPair or a @PlainData struct"
        case .sharedCaseName(let name): "@PlainData can't check enum cases that share the base name '\(name)'; give each case its own name"
        case .macroExpansion: "the PlainData check can't see the storage a macro expansion adds; declare the stored properties in the type"
        }
    }

    public var diagnosticID: MessageID { MessageID(domain: "SwiftStateTurnsMacros", id: "\(self)") }
    public var severity: DiagnosticSeverity { .error }
}


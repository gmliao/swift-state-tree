@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct LandMacro: MemberMacro, MemberAttributeMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(declaration), message: LandMacroDiagnostics.onlyStructs)
            ])
        }

        guard structDecl.memberBlock.members.contains(where: { member in
            member.decl.as(VariableDeclSyntax.self).map(isStaticBody) ?? false
        }) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(structDecl),
                    message: LandMacroDiagnostics.missingBody
                )
            ])
        }

        let args = try LandAttributeArguments.parse(from: attribute)
        let structName = structDecl.name.text
        let inferredID = inferLandID(from: structName)
        let idExpr = args.idExpr ?? ExprSyntax(StringLiteralExprSyntax(content: inferredID))

        let definitionDecl: DeclSyntax =
            """
            public static var definition: LandDefinition<\(args.stateType)> {
                Land(\(idExpr), using: \(args.stateType).self) {
                    Self.body
                }
            }
            """

        return [definitionDecl]
    }

    /// Puts a computed `static var body` under the land's builder (#771 D-Q5). A body with any
    /// attribute other than `@available` is left as written: that attribute may be a hand-written
    /// `@LandDSL<…>` or an alias of it, which the macro can't tell from another attribute. A
    /// stored body gets nothing, since Swift refuses a builder attribute on a stored property.
    public static func expansion(
        of attribute: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard declaration.is(StructDeclSyntax.self),
              let variable = member.as(VariableDeclSyntax.self),
              isStaticBody(variable),
              isComputed(variable),
              variable.attributes.allSatisfy(isAvailability)
        else { return [] }
        // A missing state type is the member expansion's diagnostic; this one adds nothing.
        guard let args = try? LandAttributeArguments.parse(from: attribute) else { return [] }
        return ["@LandDSL<\(args.stateType), NoServices>"]
    }
}

/// `static var body`, the declaration the macro builds the land from.
private func isStaticBody(_ variable: VariableDeclSyntax) -> Bool {
    guard variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else { return false }
    return variable.bindings.contains { binding in
        binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body"
    }
}

/// A `var` whose binding has accessors and no initializer.
private func isComputed(_ variable: VariableDeclSyntax) -> Bool {
    guard variable.bindingSpecifier.tokenKind == .keyword(.var) else { return false }
    return variable.bindings.allSatisfy { $0.accessorBlock != nil && $0.initializer == nil }
}

/// `@available(…)`, which says nothing about the body's builder.
private func isAvailability(_ element: AttributeListSyntax.Element) -> Bool {
    element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "available"
}

private struct LandAttributeArguments {
    let stateType: TypeSyntax
    let idExpr: ExprSyntax?

    static func parse(from attribute: AttributeSyntax) throws -> LandAttributeArguments {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(attribute), message: LandMacroDiagnostics.missingArguments)
            ])
        }

        var stateType: TypeSyntax?
        var idExpr: ExprSyntax?

        for (index, argument) in arguments.enumerated() {
            let label = argument.label?.text
            if label == nil && index == 0 {
                stateType = try TypeSyntax.make(from: argument.expression)
                continue
            }

            switch label {
            case "id":
                idExpr = ExprSyntax(argument.expression)
            default:
                break
            }
        }

        guard let stateType else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(attribute), message: LandMacroDiagnostics.missingArguments)
            ])
        }

        return LandAttributeArguments(
            stateType: stateType,
            idExpr: idExpr
        )
    }
}

private func inferLandID(from structName: String) -> String {
    var base = structName
    if base.hasSuffix("Land") {
        base = String(base.dropLast(4))
    }
    if base.isEmpty {
        base = structName
    }

    var result = ""
    for (index, character) in base.enumerated() {
        if character.isUppercase {
            if index != 0 && !result.hasSuffix("-") {
                result.append("-")
            }
            result.append(contentsOf: character.lowercased())
        } else {
            result.append(character)
        }
    }

    let sanitized = result.isEmpty ? structName.lowercased() : result.lowercased()
    return sanitized.replacingOccurrences(of: "--", with: "-")
}

private enum LandMacroDiagnostics: DiagnosticMessage {
    case onlyStructs
    case missingBody
    case missingArguments

    var message: String {
        switch self {
        case .onlyStructs:
            return "@Land can only be applied to struct declarations"
        case .missingBody:
            return "@Land struct must declare `static var body: LandRules<State, NoServices>`"
        case .missingArguments:
            return "@Land requires state type"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftStateTree.LandMacro", id: "\(self)")
    }

    var severity: DiagnosticSeverity { .error }
}

private extension TypeSyntax {
    static func make(from expression: ExprSyntax) throws -> TypeSyntax {
        if let typeExpr = expression.as(TypeExprSyntax.self) {
            return typeExpr.type
        }

        let trimmed = expression.trimmed.description
        let sanitized = trimmed.hasSuffix(".self")
            ? String(trimmed.dropLast(5))
            : trimmed
        guard !sanitized.isEmpty else {
            throw DiagnosticsError(
                diagnostics: [
                    Diagnostic(node: Syntax(expression), message: LandMacroDiagnostics.missingArguments)
                ]
            )
        }
        return TypeSyntax(stringLiteral: sanitized)
    }
}


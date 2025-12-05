@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct LandMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(declaration), message: LandMacroDiagnostics.onlyStructs)
            ])
        }

        guard structDecl.memberBlock.members.contains(where: { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
            guard variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else { return false }
            return variable.bindings.contains { binding in
                binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body"
            }
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
            return "@Land struct must declare `static var body: some LandDSL`"
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


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
            public static var definition: LandDefinition<\(args.stateType), \(args.clientType), \(args.serverType)> {
                Land(\(idExpr), using: \(args.stateType).self, clientEvents: \(args.clientType).self, serverEvents: \(args.serverType).self) {
                    Self.body
                }
            }
            """

        return [definitionDecl]
    }
}

private struct LandAttributeArguments {
    let stateType: TypeSyntax
    let clientType: TypeSyntax
    let serverType: TypeSyntax
    let idExpr: ExprSyntax?

    static func parse(from attribute: AttributeSyntax) throws -> LandAttributeArguments {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(attribute), message: LandMacroDiagnostics.missingArguments)
            ])
        }

        var stateType: TypeSyntax?
        var clientType: TypeSyntax?
        var serverType: TypeSyntax?
        var idExpr: ExprSyntax?

        for (index, argument) in arguments.enumerated() {
            let label = argument.label?.text
            if label == nil && index == 0 {
                stateType = try TypeSyntax.make(from: argument.expression)
                continue
            }

            switch label {
            case "client":
                clientType = try TypeSyntax.make(from: argument.expression)
            case "server":
                serverType = try TypeSyntax.make(from: argument.expression)
            case "id":
                idExpr = ExprSyntax(argument.expression)
            default:
                break
            }
        }

        guard let stateType, let clientType, let serverType else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(attribute), message: LandMacroDiagnostics.missingArguments)
            ])
        }

        return LandAttributeArguments(
            stateType: stateType,
            clientType: clientType,
            serverType: serverType,
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
            return "@Land requires state, client, and server types"
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

// MARK: - GenerateLandEventHandlers Macro

public struct GenerateLandEventHandlersMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            throw DiagnosticsError(
                diagnostics: [
                    Diagnostic(node: Syntax(declaration), message: EventMacroDiagnostics.onlyEnums)
                ]
            )
        }

        let enumName = enumDecl.name.text
        var generated: [DeclSyntax] = []

        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let function = try generateHandler(for: element, enumName: enumName)
                generated.append(function)
            }
        }

        return generated
    }

    private static func generateHandler(
        for element: EnumCaseElementSyntax,
        enumName: String
    ) throws -> DeclSyntax {
        let caseName = element.name.text
        let handlerName = "On" + caseName.prefix(1).uppercased() + caseName.dropFirst()

        let associatedValues = element.parameterClause?.parameters.enumerated().map { index, param -> AssociatedValueInfo in
            let label = param.firstName?.text
            let type = param.type.trimmed.description
            let variableName = label ?? "value\(index)"
            return AssociatedValueInfo(label: label, type: type, variableName: variableName)
        } ?? []

        let closureTypeTail: String
        if associatedValues.isEmpty {
            closureTypeTail = ", LandContext"
        } else {
            let params = associatedValues.map { ", \($0.type)" }.joined()
            closureTypeTail = "\(params), LandContext"
        }

        let pattern: String
        if associatedValues.isEmpty {
            pattern = ".\(caseName)"
        } else {
            let bindings = associatedValues.map { info -> String in
                if let label = info.label {
                    return "\(label): let \(info.variableName)"
                } else {
                    return "let \(info.variableName)"
                }
            }.joined(separator: ", ")
            pattern = ".\(caseName)(\(bindings))"
        }

        let handlerCall: String
        if associatedValues.isEmpty {
            handlerCall = "await body(&state, ctx)"
        } else {
            let values = associatedValues.map { $0.variableName }.joined(separator: ", ")
            handlerCall = "await body(&state, \(values), ctx)"
        }

        let functionDecl: DeclSyntax =
            """
            public func \(raw: handlerName)<State: StateNodeProtocol>(
                _ body: @escaping @Sendable (inout State\(raw: closureTypeTail)) async -> Void
            ) -> AnyClientEventHandler<State, \(raw: enumName)> {
                On(\(raw: enumName).self) { state, event, ctx in
                    guard case \(raw: pattern) = event else {
                        return
                    }
                    \(raw: handlerCall)
                }
            }
            """

        return functionDecl
    }
}

private struct AssociatedValueInfo {
    let label: String?
    let type: String
    let variableName: String
}

private enum EventMacroDiagnostics: DiagnosticMessage {
    case onlyEnums

    var message: String {
        switch self {
        case .onlyEnums:
            return "@GenerateLandEventHandlers can only be applied to enum declarations"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftStateTree.EventMacro", id: "\(self)")
    }

    var severity: DiagnosticSeverity { .error }
}


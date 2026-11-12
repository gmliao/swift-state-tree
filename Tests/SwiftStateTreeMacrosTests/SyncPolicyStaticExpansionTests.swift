// Tests/SwiftStateTreeMacrosTests/SyncPolicyStaticExpansionTests.swift
//
// `@StateNodeBuilder` emits each `@Sync` field's policy as a static of the node type, and the
// generated readers filter through it (#520). A static stored property only where the type is
// provably not generic; a static computed one anywhere else.

import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

private let macros: [String: Macro.Type] = ["StateNodeBuilder": StateNodeBuilderMacro.self]

private func expand(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    let (expanded, context) = expandCollectingDiagnostics(source, macros: macros, sourceLocation: sourceLocation)
    #expect(context.diagnostics.isEmpty, "\(context.diagnostics.map(\.message))", sourceLocation: sourceLocation)
    return expanded
}

/// Every generated read of `field`'s policy goes through `Self._syncPolicy_<field>`, and none
/// through the wrapper.
private func expectReadsThroughStatic(_ expanded: String, field: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!expanded.contains("_\(field).policy"), sourceLocation: sourceLocation)
    #expect(expanded.contains("Self._syncPolicy_\(field).filteredValue(self._\(field).wrappedValue, for: playerID)"), sourceLocation: sourceLocation)
    #expect(expanded.contains("read: { Self._syncPolicy_\(field).filteredValue($0._\(field).wrappedValue, for: nil) }"), sourceLocation: sourceLocation)
}

@Suite("StateNodeBuilder policy statics")
struct SyncPolicyStaticExpansionTests {
    @Test("A non-generic node stores each policy once, written as the attribute's argument")
    func nonGeneric() {
        let expanded = expand(
            """
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var score: Int = 0
                @Sync(.perPlayer({ (v: [String: Int], p: PlayerID) in v.filter { $0.key == p.rawValue } })) var mine: [String: Int] = [:]
                @Sync(nestingUnknownIntPolicy) var other: Int = 0
            }
            """
        )
        #expect(expanded.contains("private static let _syncPolicy_score: SyncPolicy<Int> = .broadcast"))
        #expect(expanded.contains("private static let _syncPolicy_mine: SyncPolicy<[String: Int]> = .perPlayer({ (v: [String: Int], p: PlayerID) in v.filter { $0.key == p.rawValue } })"))
        #expect(expanded.contains("private static let _syncPolicy_other: SyncPolicy<Int> = nestingUnknownIntPolicy"))
        #expect(expanded.contains("private static let _hasPlayerDependentSyncFields"))
        for field in ["score", "mine", "other"] {
            expectReadsThroughStatic(expanded, field: field)
        }
    }

    @Test("A generic node computes each policy on every read")
    func generic() {
        let expanded = expand(
            """
            @StateNodeBuilder
            struct Box<T: Sendable>: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }
            """
        )
        #expect(expanded.contains("private static var _syncPolicy_count: SyncPolicy<Int> { .broadcast }"))
        #expect(!expanded.contains("static let"))
        expectReadsThroughStatic(expanded, field: "count")
    }

    @Test("A node in a generic type, an extension or a function gets no static stored property", arguments: [
        """
        struct Outer<T> {
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }
        }
        """,
        """
        extension Outer {
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }
        }
        """,
        """
        func make() {
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }
        }
        """,
    ])
    func noStoredStatics(source: String) {
        let expanded = expand(source)
        #expect(expanded.contains("private static var _syncPolicy_count: SyncPolicy<Int> { .broadcast }"))
        #expect(!expanded.contains("static let"))
    }

    @Test("A node nested in non-generic types stores its policies")
    func nestedInNonGeneric() {
        let expanded = expand(
            """
            enum Namespace {
                struct Outer {
                    @StateNodeBuilder
                    struct Node: StateNodeProtocol {
                        @Sync(.broadcast) var count: Int = 0
                    }
                }
            }
            """
        )
        #expect(expanded.contains("private static let _syncPolicy_count: SyncPolicy<Int> = .broadcast"))
        #expect(expanded.contains("private static let _hasPlayerDependentSyncFields"))
    }

    @Test("@Sync without a policy is an error that names the field")
    func missingPolicy() {
        let (_, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync var count: Int = 0
            }
            """,
            macros: macros
        )
        #expect(context.diagnostics.map(\.message) == ["@Sync property 'count' needs a policy, for example '@Sync(.broadcast)'"])
    }
}

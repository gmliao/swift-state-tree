// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderContainerTypeTests.swift
//
// @StateNodeBuilder classifies a field's container type (dictionary, array, set) to emit its
// helper methods. A field whose element type has its own `:` or `,` (a nested literal
// dictionary, a labeled tuple, a generic argument with two parameters) was split at the first
// separator, so the helpers got broken key and element types and the expansion didn't parse
// (#582). Each spelling here must expand to valid Swift with the helpers typed as written.

import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

struct StateNodeBuilderContainerTypeTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let fieldType: String
        /// Helper signatures the expansion must contain, as the macro prints them.
        let helpers: [String]
        /// Helper names the expansion must not contain (a wrong container kind).
        let absentHelpers: [String]

        var testDescription: String { fieldType }
    }

    static let cases: [Case] = [
        Case(
            fieldType: "[[String: Int]]",
            helpers: [
                "public mutating func appendItems(_ element: [String: Int])",
                "public mutating func insertItems(_ element: [String: Int], at index: Int)",
            ],
            absentHelpers: ["func updateItems", "func setItems"]
        ),
        Case(
            fieldType: "Array<[String: Int]>",
            helpers: ["public mutating func appendItems(_ element: [String: Int])"],
            absentHelpers: ["func updateItems"]
        ),
        Case(
            fieldType: "[(a: Int, b: Int)]",
            helpers: ["public mutating func appendItems(_ element: (a: Int, b: Int))"],
            absentHelpers: ["func updateItems"]
        ),
        Case(
            fieldType: "[String: [Int: Int]]",
            helpers: [
                "public mutating func updateItems(_ value: [Int: Int], forKey key: String)",
                "public mutating func removeItems(forKey key: String) -> [Int: Int]?",
            ],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "[String: [[String: Int]]]",
            helpers: ["public mutating func updateItems(_ value: [[String: Int]], forKey key: String)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "[Int: (a: Int, b: Int)]",
            helpers: ["public mutating func updateItems(_ value: (a: Int, b: Int), forKey key: Int)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "Dictionary<Pair<Int, Int>, Int>",
            helpers: ["public mutating func updateItems(_ value: Int, forKey key: Pair<Int, Int>)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "Dictionary<String, Dictionary<String, Int>>",
            helpers: ["public mutating func updateItems(_ value: Dictionary<String, Int>, forKey key: String)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "Set<Pair<Int, Int>>",
            helpers: ["public mutating func insertItems(_ element: Pair<Int, Int>) -> (inserted: Bool, memberAfterInsert: Pair<Int, Int>)"],
            absentHelpers: ["func appendItems", "func updateItems"]
        ),
    ]

    @Test("A container field whose element type has its own separator expands to valid helpers", arguments: cases)
    func nestedContainerFieldExpands(_ testCase: Case) {
        let (expanded, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var items: \(testCase.fieldType) = .init()
                init() {}
            }
            """,
            macros: ["StateNodeBuilder": StateNodeBuilderMacro.self]
        )
        #expect(context.diagnostics.isEmpty, "\(context.diagnostics.map(\.message))")
        for helper in testCase.helpers {
            #expect(expanded.contains(helper), "missing `\(helper)`")
        }
        for helper in testCase.absentHelpers {
            #expect(!expanded.contains(helper), "unexpected `\(helper)`")
        }
    }

    @Test("A typealias element keeps array helpers, as before #582")
    func typealiasElementKeepsArrayHelpers() {
        let (expanded, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var items: [Counts] = []
                init() {}
            }
            """,
            macros: ["StateNodeBuilder": StateNodeBuilderMacro.self]
        )
        #expect(context.diagnostics.isEmpty)
        #expect(expanded.contains("public mutating func appendItems(_ element: Counts)"))
    }
}

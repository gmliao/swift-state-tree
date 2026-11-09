// Tests/SwiftStateTreeTests/RecursiveStateSchemaTests.swift
//
// Schema generation refuses a recursive state type (#286). A recursive type has infinitely many
// path patterns, so its path hashes can't cover it; generating them used to overflow the stack.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Shapes

/// Recursive through a map of itself.
@StateNodeBuilder
struct RecursiveTreeNode: StateNodeProtocol {
    @Sync(.broadcast) var pos: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var children: [String: RecursiveTreeNode] = [:]
}

@StateNodeBuilder
struct RecursiveTreeRoot: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var tree: RecursiveTreeNode = RecursiveTreeNode()
}

/// The state type itself is recursive.
@StateNodeBuilder
struct RecursiveSelfRoot: StateNodeProtocol {
    @Sync(.broadcast) var name: String = ""
    @Sync(.broadcast) var children: [String: RecursiveSelfRoot] = [:]
}

/// Two types that hold each other.
@StateNodeBuilder
struct MutualA: StateNodeProtocol {
    @Sync(.broadcast) var bs: [String: MutualB] = [:]
}

@StateNodeBuilder
struct MutualB: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var as_: [String: MutualA] = [:]
}

@StateNodeBuilder
struct MutualRoot: StateNodeProtocol {
    @Sync(.broadcast) var a: MutualA = MutualA()
}

/// The same type on two sibling fields: not recursive.
@StateNodeBuilder
struct SharedLeaf: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
}

@StateNodeBuilder
struct SharedTypeRoot: StateNodeProtocol {
    @Sync(.broadcast) var left: SharedLeaf = SharedLeaf()
    @Sync(.broadcast) var right: [String: SharedLeaf] = [:]
}

// MARK: - Tests

@Suite("Recursive state types in schema generation (#286)")
struct RecursiveStateSchemaTests {
    @Test("A recursive state node is refused, naming the type and where it re-enters")
    func recursiveNodeIsRefused() throws {
        let land = Land("recursive-tree", using: RecursiveTreeRoot.self) { Rules {} }
        let error = #expect(throws: RecursiveStateTypeError.self) {
            _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        }
        #expect(error == RecursiveStateTypeError(typeName: "RecursiveTreeNode", path: "tree.children.*"))
        #expect(error?.description.contains("RecursiveTreeNode") == true)
        #expect(error?.description.contains("tree.children.*") == true)

        #expect(throws: RecursiveStateTypeError.self) {
            _ = try SchemaExtractor.extract(from: land)
        }
        #expect(throws: RecursiveStateTypeError.self) {
            try SchemaGenCLI.generate(landDefinitions: [AnyLandDefinition(land)], outputPath: "/dev/null")
        }
    }

    @Test("A recursive state type is refused")
    func recursiveRootIsRefused() throws {
        let land = Land("recursive-root", using: RecursiveSelfRoot.self) { Rules {} }
        let error = #expect(throws: RecursiveStateTypeError.self) {
            _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        }
        #expect(error == RecursiveStateTypeError(typeName: "RecursiveSelfRoot", path: "children.*"))
    }

    @Test("Mutually recursive types are refused at the first type that re-enters")
    func mutualRecursionIsRefused() throws {
        let land = Land("mutual", using: MutualRoot.self) { Rules {} }
        let error = #expect(throws: RecursiveStateTypeError.self) {
            _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        }
        #expect(error == RecursiveStateTypeError(typeName: "MutualA", path: "a.bs.*.as_.*"))
    }

    @Test("The same type on sibling fields is not recursion")
    func sharedTypeIsNotRecursion() throws {
        let land = Land("shared", using: SharedTypeRoot.self) { Rules {} }
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        let paths = try #require(schema.lands["shared"]?.pathHashes)
        #expect(Set(paths.keys) == ["left", "left.hp", "right", "right.*", "right.*.hp"])
    }

    @Test("PathFlattener.flatten stops at a recursive type instead of overflowing the stack")
    func flattenStopsAtRecursion() {
        // Node { value: Int, children: [String: Node] }, from Root { tree: Node }.
        let definitions: [String: JSONSchema] = [
            "Root": JSONSchema(type: .object, properties: ["tree": JSONSchema(ref: "#/defs/Node")]),
            "Node": JSONSchema(
                type: .object,
                properties: [
                    "value": JSONSchema(type: .integer),
                    "children": JSONSchema(type: .object, additionalProperties: JSONSchema(ref: "#/defs/Node")),
                ]
            ),
        ]
        let paths = PathFlattener.flatten(rootTypeName: "Root", definitions: definitions)
        #expect(Set(paths.keys) == ["tree", "tree.value", "tree.children", "tree.children.*"])
        #expect(throws: RecursiveStateTypeError(typeName: "Node", path: "tree.children.*")) {
            _ = try PathFlattener.flattenRejectingRecursion(rootTypeName: "Root", definitions: definitions)
        }
    }
}

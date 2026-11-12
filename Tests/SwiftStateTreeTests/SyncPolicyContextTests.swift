// Tests/SwiftStateTreeTests/SyncPolicyContextTests.swift
//
// Node types the macro can't prove non-generic (#520): nested in a generic type, in an
// extension, or in a function. They get no static stored properties, and each field's policy is
// a static computed one. Before #520 the first two didn't compile: the macro gave them a static
// stored `_hasPlayerDependentSyncFields`. Also a policy written as a qualified static of the
// node type.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Sync policy in contexts without static storage")
struct SyncPolicyContextTests {
    @Test("A node nested in a generic type, in an extension and in a function filters through its policy")
    func nodesInGenericAndLocalContexts() throws {
        @StateNodeBuilder
        struct Local: StateNodeProtocol {
            @Sync(.masked({ (v: Int) in v + 1 })) var v: Int = 1
            init() {}
        }
        #expect(try Local().snapshot(for: nil, dirtyFields: nil).values["v"] == .int(2))
        #expect(try PolicyGenericOuter<Int>.Inner().snapshot(for: nil, dirtyFields: nil).values["v"] == .int(2))
        #expect(try PolicyGenericOuter<Int>.InExtension().snapshot(for: nil, dirtyFields: nil).values["v"] == .int(2))
    }

    @Test("A policy written as a qualified static of the node type")
    func qualifiedStaticPolicy() throws {
        let values = try PolicyQualifiedNode().snapshot(for: nil, dirtyFields: nil).values
        #expect(values["viaSelf"] == .int(2))
        #expect(values["viaName"] == .int(4))
    }
}

struct PolicyGenericOuter<T: Sendable> {
    @StateNodeBuilder
    struct Inner: StateNodeProtocol {
        @Sync(.masked({ (v: Int) in v + 1 })) var v: Int = 1
        init() {}
    }
}

extension PolicyGenericOuter {
    @StateNodeBuilder
    struct InExtension: StateNodeProtocol {
        @Sync(.masked({ (v: Int) in v + 1 })) var v: Int = 1
        init() {}
    }
}

@StateNodeBuilder
struct PolicyQualifiedNode: StateNodeProtocol {
    @Sync(Self.doubling) var viaSelf: Int = 1
    @Sync(PolicyQualifiedNode.doubling) var viaName: Int = 2
    init() {}
}

extension PolicyQualifiedNode {
    static let doubling: SyncPolicy<Int> = .masked { $0 * 2 }
}

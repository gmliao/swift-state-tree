// Tests/SwiftStateTreeTestSupport/RecordFieldList.swift
//
// How the differential harness (#555) compares each field of a decoded replay record. A field
// that depends on the wall clock or the machine is replaced with a constant; every other field
// is compared as it is. A field on neither list is unclassified, and a test fails on it.

import Foundation

/// How the harness compares one record field.
package enum RecordFieldRule: Sendable, Equatable {
    /// Compared as it is: the scenario fixes it (session IDs, request IDs, the land ID), the
    /// harness makes it stable (client IDs, by connection attempt), or the run computes it.
    case compared
    /// Replaced with a constant before the comparison, with the field's subtree: it depends on
    /// the wall clock or the machine, not on the code under test.
    case replaced(because: String)
}

package enum RecordFieldList {
    /// Fields whose subtree is replaced. A path here covers every path below it.
    package static let replaced: [String: String] = [
        "metadata.createdAt": "wall clock at recording",
        "metadata.hardwareInfo": "the recording machine",
    ]

    /// Fields compared as they are, by their `recordFieldPaths` path.
    package static let compared: Set<String> = [
        "completeness",
        "holdsNonNFCText",
        "metadata",
        "metadata.extensions",
        "metadata.initialStateHash",
        "metadata.landConfig",
        "metadata.landDefinitionID",
        "metadata.landID",
        "metadata.landType",
        "metadata.metadata",
        "metadata.recordsSyncStream",
        "metadata.rngSeedCoding",
        "metadata.rngSeedCoding.value",
        "metadata.ruleParams",
        "metadata.ruleVariantId",
        "metadata.schemaFingerprint",
        "metadata.syncConfig",
        "metadata.syncConfig.fullSnapshot",
        "metadata.syncConfig.mergedBroadcastFrame",
        "metadata.version",
        "frames",
        "frames[].tickId",
        "frames[].stateHash",
        "frames[].sequenceBeforeInputs",
        "frames[].sequenceBeforeTickHandler",
        "frames[].actions",
        "frames[].actions[].kind",
        "frames[].actions[].sequence",
        "frames[].actions[].typeIdentifier",
        "frames[].actions[].payload",
        "frames[].actions[].payload.base",
        "frames[].actions[].playerID",
        // Stable by connection attempt (`WebSocketTransport.setClientIDSupplierForTesting`).
        "frames[].actions[].clientID",
        "frames[].actions[].sessionID",
        "frames[].actions[].resolvedAtTick",
        "frames[].actions[].resolverOutputs",
        "frames[].clientEvents",
        "frames[].serverEvents",
        "frames[].serverInputs",
        "frames[].lifecycleEvents",
        "frames[].initialize",
        "frames[].landFailure",
        "frames[].passes",
        "frames[].rejected",
        "frames[].syncOutputs",
        "frames[].syncMarkers",
        "frames[].syncMarkers[].afterPass",
        "frames[].syncMarkers[].kind",
        "frames[].syncMarkers[].observedTickId",
        "frames[].syncMarkers[].playerID",
        "frames[].syncMarkers[].rejoin",
        "frames[].syncMarkers[].sequence",
        "frames[].syncMarkers[].streamIndex",
        "frames[].syncMarkers[].viewDropFields",
        "frames[].syncMarkers[].viewDrops",
        "frames[].syncMarkers[].viewHash",
    ]

    /// The rule for `path`, or nil when it is on neither list.
    package static func rule(for path: String) -> RecordFieldRule? {
        for (prefix, reason) in replaced where path == prefix || path.hasPrefix(prefix + ".") || path.hasPrefix(prefix + "[]") {
            return .replaced(because: reason)
        }
        return compared.contains(path) ? .compared : nil
    }

    /// The paths in `paths` that no rule covers, sorted.
    package static func unclassified(_ paths: Set<String>) -> [String] {
        paths.filter { rule(for: $0) == nil }.sorted()
    }
}

// Tests/SwiftStateTreeTestSupport/RecordFieldList.swift
//
// How the differential harness (#555) treats each field of a decoded replay record. A field
// that depends on the wall clock or the machine is pinned before the record's header is written
// (the record-identity override, plan §5.5); every other field is compared as it is. A field on
// neither list is unclassified, and the field-list test fails on it.
//
// Paths are the record's coding keys, as `RecordFieldProbe` names them: `metadata.rngSeed`, not
// the stored property behind it.

import Foundation

/// How the harness treats one record field.
package enum RecordFieldRule: Sendable, Equatable {
    /// Compared as it is: the scenario fixes it (session IDs, request IDs, the land ID), the
    /// harness makes it stable (client IDs, by connection attempt), or the run computes it.
    case compared
    /// Pinned to a fixed value before the header is written, with the field's subtree: it
    /// depends on the wall clock or the machine, not on the code under test.
    case pinned(because: String)
}

package enum RecordFieldList {
    /// Fields pinned by the record-identity override. A path here covers every path below it.
    package static let pinned: [String: String] = [
        "metadata.createdAt": "wall clock at recording",
        "metadata.hardwareInfo": "the recording machine",
    ]

    /// Fields compared as they are. The first four are the decoded contents' own fields; the
    /// rest are the coding-key paths of the metadata and the frames.
    package static let compared: Set<String> = [
        "completeness",
        "holdsNonNFCText",
        "metadata",
        "frames",
        "frames[].actions",
        "frames[].actions[].clientID",
        "frames[].actions[].kind",
        "frames[].actions[].payload",
        "frames[].actions[].playerID",
        "frames[].actions[].resolvedAtTick",
        "frames[].actions[].resolverOutputs",
        "frames[].actions[].resolverOutputs[].typeIdentifier",
        "frames[].actions[].resolverOutputs[].value",
        "frames[].actions[].sequence",
        "frames[].actions[].sessionID",
        "frames[].actions[].typeIdentifier",
        "frames[].clientEvents",
        "frames[].clientEvents[].clientID",
        "frames[].clientEvents[].kind",
        "frames[].clientEvents[].payload",
        "frames[].clientEvents[].playerID",
        "frames[].clientEvents[].resolvedAtTick",
        "frames[].clientEvents[].sequence",
        "frames[].clientEvents[].sessionID",
        "frames[].clientEvents[].typeIdentifier",
        "frames[].initialize",
        "frames[].initialize.sequence",
        "frames[].initialize.serverEvents",
        "frames[].initialize.serverEvents[].kind",
        "frames[].initialize.serverEvents[].payload",
        "frames[].initialize.serverEvents[].sequence",
        "frames[].initialize.serverEvents[].target",
        "frames[].initialize.serverEvents[].target.ids",
        "frames[].initialize.serverEvents[].target.kind",
        "frames[].initialize.serverEvents[].tickId",
        "frames[].initialize.serverEvents[].typeIdentifier",
        "frames[].initialize.stateHash",
        "frames[].landFailure",
        "frames[].landFailure.detail",
        "frames[].landFailure.field",
        "frames[].landFailure.kind",
        "frames[].landFailure.position",
        "frames[].landFailure.position.endsInputs",
        "frames[].landFailure.position.pass",
        "frames[].landFailure.position.sequence",
        "frames[].landFailure.position.stage",
        "frames[].landFailure.position.tickId",
        "frames[].lifecycleEvents",
        "frames[].lifecycleEvents[].clientID",
        "frames[].lifecycleEvents[].deviceID",
        "frames[].lifecycleEvents[].isGuest",
        "frames[].lifecycleEvents[].kind",
        "frames[].lifecycleEvents[].metadata",
        "frames[].lifecycleEvents[].playerID",
        "frames[].lifecycleEvents[].resolvedAtTick",
        "frames[].lifecycleEvents[].resolverOutputs",
        "frames[].lifecycleEvents[].resolverOutputs[].typeIdentifier",
        "frames[].lifecycleEvents[].resolverOutputs[].value",
        "frames[].lifecycleEvents[].sequence",
        "frames[].lifecycleEvents[].sessionID",
        "frames[].lifecycleEvents[].tickId",
        "frames[].passes",
        "frames[].passes[].inputs",
        "frames[].passes[].ordinal",
        "frames[].passes[].rejected",
        "frames[].passes[].sequenceBefore",
        "frames[].rejected",
        "frames[].sequenceBeforeInputs",
        "frames[].sequenceBeforeTickHandler",
        "frames[].serverEvents",
        "frames[].serverEvents[].kind",
        "frames[].serverEvents[].payload",
        "frames[].serverEvents[].sequence",
        "frames[].serverEvents[].target",
        "frames[].serverEvents[].target.ids",
        "frames[].serverEvents[].target.kind",
        "frames[].serverEvents[].tickId",
        "frames[].serverEvents[].typeIdentifier",
        "frames[].serverInputs",
        "frames[].serverInputs[].kind",
        "frames[].serverInputs[].payload",
        "frames[].serverInputs[].resolvedAtTick",
        "frames[].serverInputs[].sequence",
        "frames[].serverInputs[].typeIdentifier",
        "frames[].stateHash",
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
        "frames[].syncOutputs",
        "frames[].syncOutputs[].afterPass",
        "frames[].syncOutputs[].broadcastHash",
        "frames[].syncOutputs[].encodeDropScopes",
        "frames[].syncOutputs[].eventsHash",
        "frames[].syncOutputs[].eventsNotMerged",
        "frames[].syncOutputs[].eventsNotMerged.lost",
        "frames[].syncOutputs[].eventsNotMerged.sentAlone",
        "frames[].syncOutputs[].eventsNotQueued",
        "frames[].syncOutputs[].eventsThroughSequence",
        "frames[].syncOutputs[].extractionDrops",
        "frames[].syncOutputs[].index",
        "frames[].syncOutputs[].observedTickId",
        "frames[].syncOutputs[].patches",
        "frames[].syncOutputs[].patches[][].op",
        "frames[].syncOutputs[].patches[][].path",
        "frames[].syncOutputs[].patches[][].value",
        "frames[].syncOutputs[].perPlayerHash",
        "frames[].syncOutputs[].perPlayerHashes",
        "frames[].syncOutputs[].perPlayerUncommitted",
        "frames[].syncOutputs[].perPlayerUnverified",
        "frames[].syncOutputs[].resetsKeyScopes",
        "frames[].syncOutputs[].sequence",
        "frames[].syncOutputs[].streamIndex",
        "frames[].syncOutputs[].turnKind",
        "frames[].tickId",
        "metadata.extensions",
        "metadata.initialStateHash",
        "metadata.landConfig",
        "metadata.landDefinitionID",
        "metadata.landID",
        "metadata.landType",
        "metadata.metadata",
        "metadata.recordsSyncStream",
        "metadata.rngSeed",
        "metadata.ruleParams",
        "metadata.ruleVariantId",
        "metadata.schemaFingerprint",
        "metadata.syncConfig",
        "metadata.syncConfig.fullSnapshot",
        "metadata.syncConfig.mergedBroadcastFrame",
        "metadata.version",
    ]

    /// The rule for `path`, or nil when it is on neither list.
    package static func rule(for path: String) -> RecordFieldRule? {
        for (prefix, reason) in pinned where path == prefix || path.hasPrefix(prefix + ".") || path.hasPrefix(prefix + "[]") {
            return .pinned(because: reason)
        }
        return compared.contains(path) ? .compared : nil
    }

    /// The paths in `paths` that no rule covers, sorted.
    package static func unclassified(_ paths: Set<String>) -> [String] {
        paths.filter { rule(for: $0) == nil }.sorted()
    }
}

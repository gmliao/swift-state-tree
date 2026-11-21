import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

/// Pipeline component for encoding state updates and events.
///
/// This component centralizes all encoding logic, supporting multiple encoding formats
/// and strategies (including event merging with opcode 107).
///
/// **Important: Join/JoinResponse Encoding**
/// This pipeline does NOT handle join/joinResponse encoding - that's handled by LandRouter
/// during the handshake phase (always JSON). This pipeline focuses on state updates and
/// events sent after join completes.
///
/// **Performance**: This is a value type (struct) with zero allocation overhead. It has no isolation
/// of its own; it runs in its caller's (no actor hopping).
///
/// It reads none of the adapter's state: every per-cycle value (the sync sequence, a resync, the
/// fault hooks' results) is an argument (#554), so code outside the actor can call it as is. Its
/// one side effect is the encoders' shared `UnmappedPathCounter`.
struct EncodingPipeline: Sendable {
    let stateUpdateEncoder: any StateUpdateEncoder
    /// `stateUpdateEncoder` as a sequenced encoder (#332), cast once here instead of per
    /// recipient. Every built-in encoder is one; a sequence is planned only with sync-lag tracking.
    let sequencedStateUpdateEncoder: (any SyncSequencedStateUpdateEncoder)?
    let messageEncoder: any TransportMessageEncoder
    let landID: String
    /// Counts the event body encodes (tests only, #521 D10); nil in production.
    let encodeCounts: EventEncodeCountsForTesting?

    init(
        stateUpdateEncoder: any StateUpdateEncoder,
        messageEncoder: any TransportMessageEncoder,
        landID: String,
        encodeCounts: EventEncodeCountsForTesting? = nil
    ) {
        self.encodeCounts = encodeCounts
        self.stateUpdateEncoder = stateUpdateEncoder
        self.sequencedStateUpdateEncoder = stateUpdateEncoder as? any SyncSequencedStateUpdateEncoder
        self.messageEncoder = messageEncoder
        self.landID = landID
    }

    /// A state update, carrying `syncSeq` when one is planned (the encoder must then be able to
    /// carry it).
    func encodeStateUpdate(
        update: StateUpdate,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope,
        syncSeq: UInt64?
    ) throws -> Data {
        if let syncSeq {
            guard let sequenced = sequencedStateUpdateEncoder else {
                preconditionFailure("a sync sequence planned with an encoder that can't carry it")
            }
            return try sequenced.encode(
                update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: scope, syncSeq: syncSeq
            )
        }
        return try encodeStateUpdate(update: update, playerID: playerID, playerSlot: playerSlot, scope: scope)
    }

    /// A per-player state update (per-player key scope). `resync` marks the frame as a resync's
    /// when a sync sequence is planned.
    func encodePerPlayerUpdate(
        _ update: StateUpdate,
        playerID: PlayerID,
        playerSlot: Int32?,
        syncSeq: UInt64?,
        resync: Bool
    ) throws -> Data {
        if let syncSeq {
            guard let sequenced = sequencedStateUpdateEncoder else {
                preconditionFailure("a sync sequence planned with an encoder that can't carry it")
            }
            return try sequenced.encode(
                update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: .perPlayer,
                syncSeq: syncSeq, resync: resync
            )
        }
        return try stateUpdateEncoder.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot)
    }

    /// The broadcast state part of a merged frame: an array to merge in place with opcode
    /// MessagePack, encoded bytes otherwise.
    enum MergedBroadcastUpdate {
        case array([MessagePackValue])
        case data(Data)
    }

    /// The broadcast state update a merged frame (opcode 107) carries, encoded once for every
    /// recipient. `mergeEvents` completes the frame.
    func encodeMergedBroadcastUpdate(update: StateUpdate, playerID: PlayerID, syncSeq: UInt64?) throws -> MergedBroadcastUpdate {
        if let mpEncoder = stateUpdateEncoder as? OpcodeMessagePackStateUpdateEncoder {
            return .array(try mpEncoder.encodeToMessagePackArray(
                update: update,
                landID: landID,
                playerID: playerID,
                playerSlot: nil,
                scope: .broadcast,
                syncSeq: syncSeq
            ))
        }
        return .data(try encodeStateUpdate(update: update, playerID: playerID, playerSlot: nil, scope: .broadcast, syncSeq: syncSeq))
    }

    /// The merged frame: `update` with `eventBodies` (opcode 107). When it doesn't pack (or
    /// `failsPack`, a test's fault), the state frame alone, unless that would lose events
    /// (`refuseLosingMergedEvents`).
    func mergeEvents(into update: MergedBroadcastUpdate, eventBodies: [MessagePackValue], failsPack: Bool) throws -> Data {
        var packError: (any Error)?
        switch update {
        case .array(let updateArray):
            if !failsPack {
                do {
                    if let combined = try buildStateUpdateWithEventBodies(
                        stateUpdateArray: updateArray,
                        eventBodies: eventBodies,
                        allowEmptyEvents: true
                    ) {
                        return combined
                    }
                } catch {
                    packError = error
                }
            }
            try Self.refuseLosingMergedEvents(eventBodies, cause: packError)
            return try pack(.array(updateArray))
        case .data(let updateData):
            if !failsPack {
                do {
                    if let combined = try buildStateUpdateWithEventBodies(
                        stateUpdateData: updateData,
                        eventBodies: eventBodies,
                        allowEmptyEvents: true
                    ) {
                        return combined
                    }
                } catch {
                    packError = error
                }
            }
            try Self.refuseLosingMergedEvents(eventBodies, cause: packError)
            return updateData
        }
    }

    /// The merged frame didn't pack. Without events the state-only frame says the same; with
    /// events, the plan has already staged them, so sending the state alone would lose them: the
    /// land ends (#535 row 17).
    static func refuseLosingMergedEvents(_ eventBodies: [MessagePackValue], cause: (any Error)? = nil) throws {
        guard !eventBodies.isEmpty else { return }
        throw LandFailure(
            kind: .eventEncode,
            detail: "the opcode 107 frame merging \(eventBodies.count) broadcast event(s) didn't pack" + (cause.map { ": \($0)" } ?? ""),
            position: LandFailurePosition(stage: .syncPhase)
        )
    }

    /// An event frame (opcode 103) for one event body, or nil for a body that isn't an array.
    func packEventFrame(_ body: MessagePackValue) throws -> Data? {
        guard case .array(let bodyArray) = body else { return nil }
        return try pack(.array([.int(Int64(MessageKindOpcode.event.rawValue))] + bodyArray))
    }
    
    /// Encode a state update.
    ///
    /// - Parameters:
    ///   - update: State update to encode
    ///   - playerID: Player ID
    ///   - playerSlot: Player slot (optional)
    ///   - scope: State update key scope (broadcast or perPlayer)
    /// - Returns: Encoded state update data
    /// - Throws: Encoding errors
    func encodeStateUpdate(
        update: StateUpdate,
        playerID: PlayerID,
        playerSlot: Int32?,
        scope: StateUpdateKeyScope
    ) throws -> Data {
        if let scopedEncoder = stateUpdateEncoder as? StateUpdateEncoderWithScope {
            return try scopedEncoder.encode(
                update: update,
                landID: landID,
                playerID: playerID,
                playerSlot: playerSlot,
                scope: scope
            )
        }
        
        return try stateUpdateEncoder.encode(
            update: update,
            landID: landID,
            playerID: playerID,
            playerSlot: playerSlot
        )
    }
    
    /// Build MessagePack frame [107, stateUpdatePayload, eventsArray].
    ///
    /// This merges state update with pending events into a single MessagePack frame (opcode 107).
    /// Throws when the frame doesn't unpack or pack. With events, the caller ends the land rather
    /// than send the state alone, which would lose them (#535 row 17).
    ///
    /// - Parameters:
    ///   - stateUpdateData: Encoded state update data
    ///   - eventBodies: Event bodies to merge
    ///   - allowEmptyEvents: Allow merging even if event array is empty
    /// - Returns: Combined frame data, or nil without events when `allowEmptyEvents` is false
    func buildStateUpdateWithEventBodies(
        stateUpdateData: Data,
        eventBodies: [MessagePackValue],
        allowEmptyEvents: Bool = false
    ) throws -> Data? {
        if eventBodies.isEmpty, !allowEmptyEvents {
            return nil
        }
        guard case .array(let stateArr) = try unpack(stateUpdateData) else {
            throw MessagePackError.invalidData("the state update frame is not a MessagePack array")
        }
        let combined: MessagePackValue = .array([
            .int(MessageKindOpcode.stateUpdateWithEvents),
            .array(stateArr),
            .array(eventBodies)
        ])
        return try pack(combined)
    }
    
    /// Build MessagePack frame [107, stateUpdateArray, eventsArray] from pre-unpacked state array.
    ///
    /// This variant is used when the state update is already in MessagePackValue array form
    /// (e.g., from OpcodeMessagePackStateUpdateEncoder.encodeToMessagePackArray).
    ///
    /// - Parameters:
    ///   - stateUpdateArray: State update as MessagePack array
    ///   - eventBodies: Event bodies to merge
    ///   - allowEmptyEvents: Allow merging even if event array is empty
    /// - Returns: Combined frame data, or nil without events when `allowEmptyEvents` is false
    func buildStateUpdateWithEventBodies(
        stateUpdateArray: [MessagePackValue],
        eventBodies: [MessagePackValue],
        allowEmptyEvents: Bool = false
    ) throws -> Data? {
        if eventBodies.isEmpty, !allowEmptyEvents {
            return nil
        }
        let combined: MessagePackValue = .array([
            .int(MessageKindOpcode.stateUpdateWithEvents),
            .array(stateUpdateArray),
            .array(eventBodies)
        ])
        return try pack(combined)
    }
    
    /// Encode a server event body without opcode (MessagePack array [direction, type, payload, ...]).
    ///
    /// Succeeds only when the message encoder is MessagePack (typical production: clients use encoding from joinResponse).
    /// Returns nil when the message encoder is JSON or opcodeJsonArray: we encode to bytes then try MessagePack unpack,
    /// which fails. The adapter doesn't call this in such a hybrid configuration: it sends each
    /// event as its own frame, decided at init (#521 D10). With MessagePack messages, a nil body
    /// means the event is lost.
    ///
    /// - Parameter event: Server event to encode
    /// - Returns: Event body as MessagePackValue, or nil if encoding failed
    func encodeServerEventBody(_ event: AnyServerEvent) -> MessagePackValue? {
        try? encodeServerEventBodyOrThrow(event)
    }

    /// `encodeServerEventBody`, throwing why the body didn't encode: the adapter logs the cause
    /// of a lost event (#521 D10).
    func encodeServerEventBodyOrThrow(_ event: AnyServerEvent) throws -> MessagePackValue {
        encodeCounts?.countBody()
        if let mpEncoder = messageEncoder as? MessagePackTransportMessageEncoder {
            return try mpEncoder.encodeServerEventBody(event)
        }
        let transportMsg = TransportMessage.event(event: .fromServer(event: event))
        let eventData = try messageEncoder.encode(transportMsg)
        let eventUnpacked = try unpack(eventData)
        guard case .array(let eventArr) = eventUnpacked, eventArr.count >= 2 else {
            throw EncodingError.invalidValue(event.type, .init(
                codingPath: [], debugDescription: "the message encoder's event frame is not a MessagePack array"
            ))
        }
        return .array(Array(eventArr.dropFirst()))
    }
}

/// A per-player sync update before encoding.
struct PendingSyncUpdate: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
    let playerSlot: Int32?
    let update: StateUpdate
    let updateType: String
    let patchCount: Int
}

/// An encoded per-player sync update, ready to send.
struct EncodedSyncUpdate: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
    let updateType: String
    let patchCount: Int
    let payload: Data
}

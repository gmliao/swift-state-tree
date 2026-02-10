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
/// **Performance**: This is a value type (struct) with zero allocation overhead. All logic remains
/// within TransportAdapter's actor isolation domain (no actor hopping).
struct EncodingPipeline: Sendable {
    let stateUpdateEncoder: any StateUpdateEncoder
    let messageEncoder: any TransportMessageEncoder
    let landID: String
    
    /// Opcode for state update with events (107). Same numeric range as MessageKindOpcode.
    private let opcodeStateUpdateWithEvents: Int64 = 107
    
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
    /// Returns nil on failure (caller should send state update separately).
    ///
    /// - Parameters:
    ///   - stateUpdateData: Encoded state update data
    ///   - eventBodies: Event bodies to merge
    ///   - allowEmptyEvents: Allow merging even if event array is empty
    /// - Returns: Combined frame data, or nil if merging failed
    func buildStateUpdateWithEventBodies(
        stateUpdateData: Data,
        eventBodies: [MessagePackValue],
        allowEmptyEvents: Bool = false
    ) -> Data? {
        if eventBodies.isEmpty, !allowEmptyEvents {
            return nil
        }
        do {
            let stateUnpacked = try unpack(stateUpdateData)
            guard case .array(let stateArr) = stateUnpacked else { return nil }

            let combined: MessagePackValue = .array([
                .int(opcodeStateUpdateWithEvents),
                .array(stateArr),
                .array(eventBodies)
            ])
            return try pack(combined)
        } catch {
            return nil
        }
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
    /// - Returns: Combined frame data, or nil if packing failed
    func buildStateUpdateWithEventBodies(
        stateUpdateArray: [MessagePackValue],
        eventBodies: [MessagePackValue],
        allowEmptyEvents: Bool = false
    ) -> Data? {
        if eventBodies.isEmpty, !allowEmptyEvents {
            return nil
        }
        let combined: MessagePackValue = .array([
            .int(opcodeStateUpdateWithEvents),
            .array(stateUpdateArray),
            .array(eventBodies)
        ])
        return try? pack(combined)
    }
    
    /// Encode a server event body without opcode (MessagePack array [direction, type, payload, ...]).
    ///
    /// Succeeds only when the message encoder is MessagePack (typical production: clients use encoding from joinResponse).
    /// Returns nil when the message encoder is JSON or opcodeJsonArray: we encode to bytes then try MessagePack unpack,
    /// which fails. Caller must then send the event as a separate frame.
    ///
    /// - Parameter event: Server event to encode
    /// - Returns: Event body as MessagePackValue, or nil if encoding failed
    func encodeServerEventBody(_ event: AnyServerEvent) -> MessagePackValue? {
        do {
            if let mpEncoder = messageEncoder as? MessagePackTransportMessageEncoder {
                return try mpEncoder.encodeServerEventBody(event)
            }
            let transportMsg = TransportMessage.event(event: .fromServer(event: event))
            let eventData = try messageEncoder.encode(transportMsg)
            let eventUnpacked = try unpack(eventData)
            guard case .array(let eventArr) = eventUnpacked, eventArr.count >= 2 else { return nil }
            return .array(Array(eventArr.dropFirst()))
        } catch {
            return nil
        }
    }
}

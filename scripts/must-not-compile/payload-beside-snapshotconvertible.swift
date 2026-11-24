// expect-error: @Payload and @SnapshotConvertible both write getFieldMetadata()
import SwiftStateTree

@Payload
@SnapshotConvertible
struct BothEvent: ServerEventPayload {
    let n: Int
}

// expect-error: a payload uses @Payload only
import SwiftStateTree

// @Payload beside @SnapshotConvertible: both write the field metadata, so @Payload refuses the
// pair. @SnapshotConvertible yields the PlainData witness to @Payload, so no second witness is
// written on top of that error.
@Payload
@SnapshotConvertible
struct Reward: ServerEventPayload, Equatable {
    var gold: Int
}

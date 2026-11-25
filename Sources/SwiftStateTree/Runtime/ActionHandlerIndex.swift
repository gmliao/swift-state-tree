import SwiftStateTurns

/// A position in this land's `definition.actionHandlers` (#700 K1b-1, F9). Valid only in this
/// process; never persisted, sent or compared across runs.
///
/// A queued action names its handler by this index instead of holding the action's metatype,
/// which `@PlainData` refuses. It isn't `Codable`, and must not become so: a position depends on
/// the order the land declared its handlers in, and a record names a handler by its action type's
/// name (`ReevaluationRecordedAction.typeIdentifier`), never by a position.
@PlainData
package struct ActionHandlerIndex: Hashable, Sendable {
    package let position: Int

    package init(_ position: Int) {
        self.position = position
    }
}

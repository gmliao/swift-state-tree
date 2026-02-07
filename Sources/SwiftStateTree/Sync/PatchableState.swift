// Sources/SwiftStateTree/Sync/PatchableState.swift

import Foundation

/// Protocol for state types that support incremental patch recording.
///
/// Types conforming to this protocol can receive path context injection
/// from parent containers (like `ReactiveDictionary`) to enable
/// automatic patch recording during mutations.
///
/// This protocol is automatically conformed by `@StateNodeBuilder` macro.
public protocol PatchableState {
    /// The JSON Pointer path to this state node from the root.
    /// Injected by parent container during access.
    var _$parentPath: String { get set }
    
    /// Reference to the shared patch recorder.
    /// Injected by parent container during access.
    var _$patchRecorder: PatchRecorder? { get set }
}

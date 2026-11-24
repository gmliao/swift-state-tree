// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// `C.Element` names `C`, so the macro writes `C: PlainData`, which doesn't give
// `C.Element: PlainData`, and the field's check fails at the declaration. The declaration
// writes that requirement itself (plaindata-unstored-parameter-compiles.swift).
@PlainData
struct FirstOf<C: Collection & Sendable> {
    let first: C.Element?
}

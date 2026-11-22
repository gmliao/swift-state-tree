// expect-error: has no member 'setLandID'
// The land ID goes to LandKeeper's init (#593): the init starts the initialization eagerly, so a
// setter called later would race with it.
import SwiftStateTree

func setLandIDLate(_ keeper: LandKeeper<SnippetState>) async {
    await keeper.setLandID("snippet:late")
}

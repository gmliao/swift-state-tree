// expect-error: no exact matches in call to static method 'buildExpression'
// #771 D-Q5: `@Land`'s body is the land's nodes, `[LandNode]`; another type doesn't compile.
import SwiftStateTree

@Land(SnippetState.self)
struct SnippetWrongBodyLand {
    static var body: Int { 1 }
}

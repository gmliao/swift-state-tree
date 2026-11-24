// expect-error: no exact matches in call to static method 'buildExpression'
// #771 D-Q5, #794: `@Land`'s body is the land's rules, `LandRules<State, NoServices>`; another
// type doesn't compile.
import SwiftStateTree

@Land(SnippetState.self)
struct SnippetWrongBodyLand {
    static var body: Int { 1 }
}

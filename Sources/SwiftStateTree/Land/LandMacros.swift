// Macro entry points for Land DSL

/// Macro for defining a Land using struct-based syntax.
///
/// This macro generates a static `definition` property that returns a `LandDefinition`, built
/// from the struct's `static var body: [LandNode]`. It also puts `body` under the land's builder,
/// `@LandDSL<State, NoServices>`, so its handler closures get the land's types without
/// annotations, as in `Land(_:using:)`. A `body` with any attribute other than `@available` is
/// left as written (a hand-written `@LandDSL<…>`, or an alias of it), and `body` must be a
/// computed `static var`.
///
/// `@Land` makes a land without services. A land with services is written with
/// `Land(_:using:services:)`.
///
/// - Parameters:
///   - state: The StateNodeProtocol type for this Land.
///   - id: Optional Land ID. If omitted, the struct name is converted to kebab-case.
///
/// Example:
/// ```swift
/// @Land(GameState.self)
/// struct GameLand {
///     static var body: [LandNode] {
///         ClientEvents {
///             Register(ChatEvent.self)
///         }
///         ServerEvents {
///             Register(WelcomeEvent.self)
///         }
///         Rules {
///             HandleEvent(ChatEvent.self) { state, event, ctx in ... }
///         }
///     }
/// }
/// ```
@attached(member, names: named(definition))
@attached(memberAttribute)
public macro Land(
    _ state: Any.Type,
    id: String? = nil
) = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "LandMacro"
)


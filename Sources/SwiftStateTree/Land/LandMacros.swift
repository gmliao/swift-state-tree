// Macro entry points for Land DSL

/// Macro for defining a Land using struct-based syntax.
///
/// This macro generates a static `definition` property that returns a `LandDefinition`.
/// The struct must contain a static `body` property with the DSL content.
///
/// Client and server events are now registered via `ClientEvents { Register(...) }` and
/// `ServerEvents { Register(...) }` DSL blocks in the body.
///
/// - Parameters:
///   - state: The StateNodeProtocol type for this Land.
///   - id: Optional Land ID. If omitted, the struct name is converted to kebab-case.
///
/// Example:
/// ```swift
/// @Land(GameState.self)
/// struct GameLand {
///     static var body: some LandDSL {
///         ClientEvents {
///             Register(ChatEvent.self)
///         }
///         ServerEvents {
///             Register(WelcomeEvent.self)
///         }
///         AccessControl { ... }
///         Rules { ... }
///     }
/// }
/// ```
@attached(member, names: named(definition))
public macro Land(
    _ state: Any.Type,
    id: String? = nil
) = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "LandMacro"
)


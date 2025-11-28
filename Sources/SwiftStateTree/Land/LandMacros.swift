// Macro entry points for Land DSL

/// Macro for defining a Land using struct-based syntax.
///
/// This macro generates a static `definition` property that returns a `LandDefinition`.
/// The struct must contain a static `body` property with the DSL content.
///
/// - Parameters:
///   - state: The StateNodeProtocol type for this Land.
///   - client: The ClientEventPayload type.
///   - server: The ServerEventPayload type.
///   - id: Optional Land ID. If omitted, the struct name is converted to kebab-case.
///
/// Example:
/// ```swift
/// @Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self)
/// struct GameLand {
///     static var body: some LandDSL {
///         AccessControl { ... }
///         Rules { ... }
///     }
/// }
/// ```
@attached(member, names: named(definition))
public macro Land(
    _ state: Any.Type,
    client: Any.Type,
    server: Any.Type,
    id: String? = nil
) = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "LandMacro"
)

/// Macro for generating semantic event handlers from a ClientEventPayload enum.
///
/// When applied to an enum conforming to `ClientEventPayload`, this macro generates
/// helper functions like `OnReady`, `OnMove`, `OnChat`, etc., one for each enum case.
/// These helpers wrap the generic `On(ClientEvents.self)` function and provide
/// type-safe, case-specific event handling.
///
/// Example:
/// ```swift
/// @GenerateLandEventHandlers
/// enum ClientEvents: ClientEventPayload {
///     case ready
///     case move(Vec2)
///     case chat(String)
/// }
/// // Generates: OnReady, OnMove, OnChat
/// ```
@attached(member, names: arbitrary)
public macro GenerateLandEventHandlers() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "GenerateLandEventHandlersMacro"
)

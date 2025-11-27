// Macro entry points for Land DSL

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

@attached(peer, names: arbitrary)
public macro GenerateLandEventHandlers() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "GenerateLandEventHandlersMacro"
)


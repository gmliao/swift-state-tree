import Foundation
import SwiftStateTurns

/// A request for data from outside the land, written as a value (#769).
///
/// A resolver is a `PlainData` struct whose fields are its parameters. The land builds it in
/// the turn that admits the input, from the State and the input, with the entry's `resolvers:`
/// closure. Off the actor, `resolve` sees only the value's own fields and the dependencies it
/// declares; it never reads the land's state.
///
/// ```swift
/// protocol HasProductDatabase { var productDatabase: ProductDatabase { get } }
///
/// @PlainData
/// struct ProductInfo<D: HasProductDatabase & Sendable>: Resolver, Codable, Hashable {
///     typealias Dependencies = D
///     let productID: Int
///     func resolve(_ deps: D) async throws -> ProductInfoOutput {
///         try await deps.productDatabase.fetchProduct(by: productID)
///     }
/// }
/// ```
///
/// - **Dependencies** is the land's services type (`Land(_:using:services:)`), or `NoServices`
///   for a land without one. A resolver generic over a capability protocol works in every land
///   whose services conform; a land whose services lack it doesn't compile.
/// - **The name** used in errors (`ResolverExecutionError.resolverFailed(name:)`, the deadline's
///   `timedOut(names:)`) is the base type name, without generic arguments.
public protocol Resolver: PlainData, Codable, Hashable, Sendable {
    /// What `resolve` may use: the land's services type, or a generic parameter constrained to
    /// the capabilities it needs.
    associatedtype Dependencies: Sendable
    /// The resolved data the handler receives.
    associatedtype Output: ResolverOutput

    /// Loads the data this value asks for. It runs off the land's actor, so it reads only the
    /// value's fields and `deps`.
    func resolve(_ deps: Dependencies) async throws -> Output
}

/// The errors the runtime adds around a `Resolver` value.
public enum ResolverServicesError: Error, Sendable, Equatable {
    /// The land's services value isn't the resolver's `Dependencies`. Registration refuses a
    /// land whose declarations name other services, and a live keeper given a value of another
    /// type fails its initialization (`LandRegistrationError.wrongServices`), so this is a
    /// backstop.
    case servicesMismatch(resolver: String, expected: String, actual: String)
}

extension ResolverExecutor {
    /// The base type name of `type`, without generic arguments: `ProductInfo`, not
    /// `ProductInfo<AppServices>` (#769 §3.1). Used in errors and, through
    /// `convertResolverTypeToPropertyName`, as the name an output is recorded under.
    package static func baseTypeName(_ type: Any.Type) -> String {
        baseTypeName(String(describing: type))
    }

    /// `name` without its generic arguments.
    package static func baseTypeName(_ name: String) -> String {
        guard let generic = name.firstIndex(of: "<") else { return name }
        return String(name[..<generic])
    }

    /// The name a `Resolver`'s output is stored and recorded under: `convertResolverTypeToPropertyName`
    /// of its base type name. Distinct types can share it (`Price` and `PriceResolver` are both
    /// `price`), so registration compares this, not the type name.
    package static func outputName(forBaseTypeName name: String) -> String {
        convertResolverTypeToPropertyName(name)
    }
}

/// An executor that knows, without running, the name its output is stored under. Registration
/// uses it to refuse two resolvers of one entry that would write the same output.
package protocol ResolverOutputNaming {
    var outputName: String { get }
}

/// Runs one resolver value with the land's services (#769). The keeper builds it at the point
/// that admits the input, from the entry's `resolvers:` closure.
struct ResolverValueExecutor<R: Resolver>: AnyResolverExecutor, ResolverOutputNaming {
    let value: R
    /// The base type name, for errors (`ResolverSlot` computes it once per declaration).
    let resolverName: String
    /// The name the output is stored and recorded under.
    let outputName: String

    func execute(ctx: ResolverContext) async throws -> (String, any ResolverOutput) {
        guard let deps = ctx.resolverServices as? R.Dependencies else {
            throw ResolverServicesError.servicesMismatch(
                resolver: resolverName,
                expected: String(reflecting: R.Dependencies.self),
                actual: ctx.resolverServices.map { String(reflecting: type(of: $0)) } ?? "none"
            )
        }
        let output = try await value.resolve(deps)
        return (outputName, output)
    }
}


/// An entry's resolvers, as the node holds them until the keeper admits an input (#769 §3.2).
///
/// `build` runs the entry's `resolvers:` closure. It reads the State, the input and a read-only
/// context, must not mutate anything, and returns one executor per value the closure built: a `nil`
/// value is skipped, and the handler gets `nil` for that output.
package struct ResolverDeclaration<Input>: Sendable {
    /// The resolvers' base type names, in declaration order. Two that store their outputs under
    /// one name (`ResolverExecutor.outputName(forBaseTypeName:)`) in one declaration are refused
    /// at registration until the record keys outputs by position (#769 §3.5).
    package let names: [String]
    /// The services type every resolver in the declaration depends on: the land's.
    package let servicesType: Any.Type
    /// `fileID:line` of the entry, for registration errors.
    package let site: String
    package let build: @Sendable (Input, ValidateContext) -> [any AnyResolverExecutor]

    package init(
        names: [String],
        servicesType: Any.Type,
        site: String,
        build: @escaping @Sendable (Input, ValidateContext) -> [any AnyResolverExecutor]
    ) {
        self.names = names
        self.servicesType = servicesType
        self.site = site
        self.build = build
    }

}

/// One resolver of a declaration: its names, computed once when the entry is declared, not for
/// each built value or output read.
struct ResolverSlot<R: Resolver>: Sendable {
    /// The base type name, without generic arguments: errors and registration use it.
    let name: String
    /// The name the output is stored and recorded under.
    let outputName: String

    init(_ type: R.Type) {
        name = ResolverExecutor.baseTypeName(R.self)
        outputName = ResolverExecutor.outputName(forBaseTypeName: name)
    }

    /// The executor for one built value, or none for `nil`.
    func executors(_ value: R?) -> [any AnyResolverExecutor] {
        value.map { [ResolverValueExecutor(value: $0, resolverName: name, outputName: outputName)] } ?? []
    }

    /// Appends the executor for a built value; `nil` appends nothing.
    func append(_ value: R?, to executors: inout [any AnyResolverExecutor]) {
        if let value {
            executors.append(ResolverValueExecutor(value: value, resolverName: name, outputName: outputName))
        }
    }

    /// The output a handler receives for `R`: the one the group produced, live or recorded, or
    /// `nil` when the closure built no value (or, with `.continue`, when the group failed).
    func output(in ctx: LandContext) -> R.Output? {
        ctx.resolverOutput(R.Output.self, named: outputName)
    }
}

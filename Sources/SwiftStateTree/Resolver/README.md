# Resolver: error handling

This folder holds the resolver machinery: the `Resolver` protocol (values, #769), `ContextResolver` (still used by `CanJoin`, `OnJoin` and `OnLeave`), and the executor that runs an entry's resolvers in parallel. The user guide is [docs/core/resolver.md](../../../docs/core/resolver.md). This page covers what happens when a resolver fails.

## A resolver that fails

A resolver that can't load its data throws: a `ResolverError` or its own error.

```swift
@PlainData
struct ProductInfo<D: HasProductDatabase>: Resolver {
    typealias Dependencies = D
    let productID: String

    func resolve(_ deps: D) async throws -> ProductInfoOutput {
        do {
            let data = try await deps.productDatabase.fetchProduct(by: productID)
            return ProductInfoOutput(id: data.id, name: data.name, price: data.price, stock: data.stock)
        } catch DatabaseError.notFound {
            throw ResolverError.dataLoadFailed("Product not found: \(productID)")
        } catch {
            throw ResolverError.dataLoadFailed("Failed to load product: \(error.localizedDescription)")
        }
    }
}
```

A cache check belongs in the entry's `resolvers:` closure, which sees the State: it returns `nil` when the State already has the data, and nothing is loaded.

## What the runtime does with the error

1. **Wrap.** The error is wrapped in `ResolverExecutionError.resolverFailed(name:underlyingError:)`. `name` is the resolver's base type name, without generic arguments (`"ProductInfo"`, not `"ProductInfo<ShopServices>"`).
2. **Cancel the rest.** The entry's other resolvers, running in parallel, are cancelled.
3. **Skip the handler.** The handler doesn't run. The exception is `OnInitialize` with `onResolverFailure: .continue`, which runs without the outputs.
4. **Tell the caller.** For an action, the transport sends an `ErrorPayload` to the client.

The handler needs no error handling for its resolvers: it runs only after they succeeded, or, with `.continue`, gets `nil` outputs.

```swift
HandleAction(UpdateCart.self, resolvers: { _, action, _ in ProductInfo(productID: action.productID) }) {
    state, action, productInfo, ctx in
    // Reached only after the resolver succeeded; productInfo is nil only when the closure built no value.
    ...
}
```

## Error types

```swift
public enum ResolverError: Error, Sendable {
    case missingParameter(String)
    case dataLoadFailed(String)
    case cancelled
    case custom(String)
}

public enum ResolverExecutionError: Error, Sendable {
    case resolverFailed(name: String, underlyingError: Error)
    case multipleResolversFailed([(name: String, error: Error)])
    case timedOut(names: [String], after: Duration)
}
```

`ResolverServicesError.servicesMismatch` is thrown when a keeper's services value isn't the resolver's `Dependencies`. Registration refuses such a land, so only a keeper built by hand can see it.

## Events

Client events take no resolvers (`HandleEvent` has no `resolvers:` parameter). An event that can be refused is declared in two stages: `validate` throws to refuse, with nothing written, and `apply` writes and can't throw ([Land DSL: Two-Phase Handlers](../../../docs/core/land-dsl.md#two-phase-handlers)).

```swift
enum ChatError: Error { case emptyMessage }

HandleEvent(ChatEvent.self,
    validate: { state, event, ctx in
        guard let message = event.message, !message.isEmpty else { throw ChatError.emptyMessage }
        return message
    },
    apply: { state, event, message, ctx in
        state.messages.append(message)
    })
```

On a tickless land the client gets an `ErrorPayload` for a refused event. On a tick land the event is applied in the next tick, so its refusal is only logged.

## Practices

1. **Say what failed.** `ResolverError.dataLoadFailed("Product not found: \(productID)")`. The runtime adds the resolver's name.
2. **Check the State in the closure, not in `resolve`.** `resolve` can't read the State.
3. **Use the `ResolverError` case that fits**: `missingParameter` for a value built without what it needs, `dataLoadFailed` for a load that failed.

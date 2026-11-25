// expect: compiles
import SwiftStateTurns

// A generic parameter that no stored value names adds no constraint (#769): a resolver generic
// over services it doesn't store is plain data with services that hold a class.
final class Database: Sendable {}
struct AppServices: Sendable { let db = Database() }
protocol HasDatabase { var db: Database { get } }
extension AppServices: HasDatabase {}

@PlainData
struct ProductInfo<D: HasDatabase>: Codable, Hashable, Sendable {
    let productID: Int
    func lookup(_ deps: D) -> Database { deps.db }
}

// Only the case that stores `T` constrains it; `U` is stored nowhere.
@PlainData
enum Choice<T: Hashable, U> {
    case some(T)
    case none
}

@PlainData
struct Box<T> { let t: T }

// A member type of a parameter needs the declaration's own requirement.
@PlainData
struct FirstOf<C: Collection & Sendable> where C.Element: PlainData {
    let first: C.Element?
}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(ProductInfo<AppServices>.self)
    requirePlainData(Choice<Int, Database>.self)
    requirePlainData(Box<Int>.self)
    requirePlainData(FirstOf<[Int]>.self)
}

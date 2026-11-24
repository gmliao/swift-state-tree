// expect: compiles
import SwiftStateTurns

// `D.ID == Int` binds an associated type to a concrete type. A field of type `Int` doesn't make
// `D` named through it: only generic parameters carry a name across a same-type requirement. So
// the resolver shape stays plain data with services that hold a class.
protocol HasID { associatedtype ID }
final class Database: Sendable {}
struct AppServices: HasID, Sendable {
    typealias ID = Int
    let db = Database()
}

@PlainData
struct ProductInfo<D: HasID> where D.ID == Int {
    let productID: Int
}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(ProductInfo<AppServices>.self)
}

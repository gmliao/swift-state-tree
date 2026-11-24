// expect-error: 'Outer.Item' conform to 'PlainData'
import SwiftStateTurns

// The extension the macro writes is at file scope, where `Item` names the file-scope struct, not
// the class nested beside `Inner`. The check reads the stored value, so it sees the class.
@PlainData
struct Item {}

enum Outer {
    final class Item {}

    @PlainData
    struct Inner {
        var item: Item
    }
}

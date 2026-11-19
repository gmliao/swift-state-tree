// Tests/SwiftStateTreeTestSupport/RecordFieldWalk.swift
//
// Walks a decoded value's stored fields by reflection and names each one by its path, so a test
// can check that every field of the replay record is classified (#555).

import Foundation

/// The field paths of `value`: `a.b` for a nested field, `a[]` for an element of an array or a
/// dictionary value, `a?` unwrapped silently. Leaves are values with no children (numbers,
/// strings, `Date`, `Data`, payload values); a path is listed once however often it occurs.
package func recordFieldPaths(of value: Any) -> Set<String> {
    var paths = Set<String>()
    walk(value, path: "", into: &paths)
    return paths
}

private func walk(_ value: Any, path: String, into paths: inout Set<String>) {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional:
        if let wrapped = mirror.children.first { walk(wrapped.value, path: path, into: &paths) }
        return
    case .collection, .set:
        for element in mirror.children { walk(element.value, path: path + "[]", into: &paths) }
        return
    case .dictionary:
        for entry in mirror.children {
            // An entry is a (key, value) tuple.
            let pair = Mirror(reflecting: entry.value).children.map(\.value)
            if pair.count == 2 { walk(pair[1], path: path + "[]", into: &paths) }
        }
        return
    case .struct, .class, .enum, .tuple:
        break
    default:
        return
    }
    if isLeaf(value) { return }
    for child in mirror.children {
        guard let label = child.label else { continue }
        let childPath = path.isEmpty ? label : path + "." + label
        paths.insert(childPath)
        walk(child.value, path: childPath, into: &paths)
    }
}

private func isLeaf(_ value: Any) -> Bool {
    value is String || value is Date || value is Data || value is UUID || value is Bool
        || value is any BinaryInteger || value is any BinaryFloatingPoint
}

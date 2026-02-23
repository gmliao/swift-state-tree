// DecodeReplayState.swift
// Utility for decoding typed state from replay actualState (AnyCodable JSON string).
// Supports flat JSON and "values" wrapper format used by StateSnapshot.

import Foundation
import SwiftStateTree

/// Decodes a `Decodable` type from a replay step's `actualState` (an `AnyCodable` whose `.base`
/// is a JSON string). Returns `nil` on any failure (wrong type, invalid JSON, decode error).
///
/// Two formats are supported:
/// 1. Flat JSON: `{"x":10,"label":"test"}`
/// 2. StateSnapshot "values" wrapper: `{"values":{"x":10,"label":"test"}}`
///
/// The function first attempts flat decode, then falls back to the values-wrapper format.
public func decodeReplayState<T: Decodable>(_ type: T.Type, from actualState: AnyCodable?) -> T? {
    guard let jsonString = actualState?.base as? String else { return nil }
    guard let data = jsonString.data(using: .utf8) else { return nil }

    let decoder = JSONDecoder()

    // Attempt 1: flat decode
    if let result = try? decoder.decode(type, from: data) {
        return result
    }

    // Attempt 2: values-wrapper format
    if let wrapper = try? decoder.decode(_ValuesWrapper<T>.self, from: data) {
        return wrapper.values
    }

    return nil
}

private struct _ValuesWrapper<T: Decodable>: Decodable {
    let values: T
}

// Sources/SwiftStateTreeTransport/TransportAdapterAdoption.swift
//
// The adoption level of TransportAdapter's move onto the turn core (#546), one slice at a
// time. The differential harness (#555) runs a scenario at two levels and compares them.

import Foundation
import SwiftStateTree

/// Which slices of the turn-core adapter (#546) a land's adapter uses. Each level includes the
/// slices before it. Package only: a server sets it through `TRANSPORT_ADAPTER_ADOPTION`, and
/// tests pass it as a parameter, so both levels can run in one process.
package enum TransportAdapterAdoption: String, Sendable, CaseIterable {
    /// Today's adapter, with no turn-core slice.
    case legacy

    /// The level `TRANSPORT_ADAPTER_ADOPTION` names; `.legacy` when it is unset.
    ///
    /// - Throws: `TransportAdapterAdoptionError.unknown` for a value that names no level, so a
    ///   typo stops the server at startup instead of running `.legacy` without a word.
    package static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TransportAdapterAdoption {
        let raw = EnvHelpers.getEnvString(
            key: TransportEnvKeys.adapterAdoption,
            defaultValue: TransportAdapterAdoption.legacy.rawValue,
            environment: environment
        )
        guard let level = TransportAdapterAdoption(rawValue: raw) else {
            throw TransportAdapterAdoptionError.unknown(raw)
        }
        return level
    }
}

/// A `TRANSPORT_ADAPTER_ADOPTION` value that names no adoption level.
package enum TransportAdapterAdoptionError: Error, Equatable, CustomStringConvertible {
    case unknown(String)

    package var description: String {
        switch self {
        case .unknown(let value):
            let known = TransportAdapterAdoption.allCases.map(\.rawValue).joined(separator: ", ")
            return "\(TransportEnvKeys.adapterAdoption)=\(value) names no adoption level (known: \(known))"
        }
    }
}

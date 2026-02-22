import Foundation

/// Recursive JSON diff for state snapshot comparison (debugging reevaluation mismatches).
public enum StateSnapshotDiff: Sendable {
    public struct Difference: Sendable {
        public let path: String
        public let recorded: String
        public let computed: String
    }

    /// Compare two JSON-like dictionaries recursively.
    /// - Parameters:
    ///   - recorded: Ground truth from live recording
    ///   - computed: Result from reevaluation
    ///   - pathPrefix: Current path for nested reporting (e.g. "players.p1")
    /// - Returns: List of differences with path and both values
    public static func compare(
        recorded: [String: Any],
        computed: [String: Any],
        pathPrefix: String = ""
    ) -> [Difference] {
        var diffs: [Difference] = []
        let allKeys = Set(recorded.keys).union(Set(computed.keys))
        for key in allKeys.sorted() {
            let path = pathPrefix.isEmpty ? key : "\(pathPrefix).\(key)"
            let r = recorded[key]
            let c = computed[key]
            if r == nil, c == nil { continue }
            if let rDict = r as? [String: Any], let cDict = c as? [String: Any] {
                diffs.append(contentsOf: compare(recorded: rDict, computed: cDict, pathPrefix: path))
            } else if let rArr = r as? [Any], let cArr = c as? [Any] {
                if rArr.count != cArr.count {
                    diffs.append(Difference(path: path, recorded: "\(rArr.count) items", computed: "\(cArr.count) items"))
                } else {
                    for (i, (rv, cv)) in zip(rArr, cArr).enumerated() {
                        let p = "\(path)[\(i)]"
                        if let rd = rv as? [String: Any], let cd = cv as? [String: Any] {
                            diffs.append(contentsOf: compare(recorded: rd, computed: cd, pathPrefix: p))
                        } else if !isEqual(rv, cv) {
                            diffs.append(Difference(path: p, recorded: "\(rv)", computed: "\(cv)"))
                        }
                    }
                }
            } else if !isEqual(r, c) {
                diffs.append(Difference(
                    path: path,
                    recorded: r.map { "\($0)" } ?? "nil",
                    computed: c.map { "\($0)" } ?? "nil"
                ))
            }
        }
        return diffs
    }

    private static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if let ad = a as? [String: Any], let bd = b as? [String: Any] {
            return compare(recorded: ad, computed: bd, pathPrefix: "").isEmpty
        }
        return "\(a)" == "\(b)"
    }
}

// Sources/SwiftStateTree/Support/HoldPoints.swift
//
// Named hold points for forced-interleaving tests: a test holds the code at the `await` where a
// race can happen, issues the competing call, then lets it go. No timing involved.

/// One optional hook per instance, called at named points. A no-op (one `nil` check) unless a
/// test installs it.
///
/// In the owning type:
/// ```swift
/// enum HoldPoint: Hashable, Sendable { case afterLandLookup }
/// var holds = HoldPoints<HoldPoint>()
/// ...
/// await holds.at(.afterLandLookup)
/// ```
package struct HoldPoints<Point: Hashable & Sendable>: Sendable {
    private var hook: (@Sendable (Point) async -> Void)?

    package init() {}

    /// Installs (or, with `nil`, removes) the hook. Tests only.
    package mutating func install(_ hook: (@Sendable (Point) async -> Void)?) {
        self.hook = hook
    }

    /// Awaits the hook at `point`, if one is installed.
    package func at(_ point: Point) async {
        if let hook { await hook(point) }
    }
}

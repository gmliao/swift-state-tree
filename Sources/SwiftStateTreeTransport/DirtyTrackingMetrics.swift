import SwiftStateTree

/// Dirty tracking metrics calculator (pure computation, no async/await).
///
/// Tracks object-level change rate and exponential moving average (EMA) to support
/// automatic dirty tracking mode switching. The metrics help determine when to
/// enable or disable dirty tracking based on actual change patterns.
///
/// ## Purpose
/// - Calculate change rate: `changedObjects / totalObjects`
/// - Track EMA for smoothed change rate
/// - Support auto-switch decisions in TransportAdapter
///
/// ## Usage
/// ```swift
/// let metrics = DirtyTrackingMetrics(emaAlpha: 0.2)
/// var state = DirtyTrackingMetrics.State()
///
/// let result = metrics.calculate(
///     updates: updates,
///     broadcastSnapshot: snapshot,
///     state: &state,
///     extractPatches: { ... },
///     estimateTotalObjects: { ... },
///     objectKeyFromPath: { ... }
/// )
///
/// // Use result.changeRateEma for auto-switch decisions
/// ```
struct DirtyTrackingMetrics: Sendable {
    /// Calculated metrics result.
    struct Result: Sendable {
        let changedObjects: Int
        let unchangedObjects: Int
        let estimatedTotalObjects: Int
        let changeRate: Double
        let changeRateEma: Double
    }
    
    /// Mutable state for EMA calculation.
    struct State: Sendable {
        var syncCount: UInt64
        var changeRateEma: Double
        var hasEma: Bool
        
        init() {
            self.syncCount = 0
            self.changeRateEma = 0
            self.hasEma = false
        }
    }
    
    /// EMA smoothing factor (alpha).
    /// Higher values (e.g., 0.5) respond faster to changes.
    /// Lower values (e.g., 0.1) provide more smoothing.
    let emaAlpha: Double
    
    init(emaAlpha: Double) {
        self.emaAlpha = emaAlpha
    }
    
    /// Calculate change metrics from state updates.
    ///
    /// This method performs pure computation without any async/await or side effects.
    /// It collects changed object keys, calculates metrics, and updates EMA.
    ///
    /// - Parameters:
    ///   - updates: State updates to analyze
    ///   - broadcastSnapshot: Current broadcast snapshot
    ///   - state: Mutable state (syncCount, EMA) - updated in place
    ///   - extractPatches: Closure to extract patches from update
    ///   - estimateTotalObjects: Closure to estimate total objects in snapshot
    ///   - objectKeyFromPath: Closure to extract object key from patch path
    /// - Returns: Calculated metrics result
    func calculate(
        updates: [StateUpdate],
        broadcastSnapshot: StateSnapshot,
        state: inout State,
        extractPatches: (StateUpdate) -> [StatePatch],
        estimateTotalObjects: (StateSnapshot) -> Int,
        objectKeyFromPath: (String, StateSnapshot) -> String?
    ) -> Result {
        state.syncCount += 1
        
        // Collect changed object keys
        var changedObjectKeys = Set<String>()
        changedObjectKeys.reserveCapacity(64)
        for update in updates {
            let patches = extractPatches(update)
            for patch in patches {
                if let objectKey = objectKeyFromPath(patch.path, broadcastSnapshot) {
                    changedObjectKeys.insert(objectKey)
                }
            }
        }
        
        // Calculate metrics
        let changedObjects = changedObjectKeys.count
        let estimatedTotalObjects = max(estimateTotalObjects(broadcastSnapshot), changedObjects)
        let unchangedObjects = max(0, estimatedTotalObjects - changedObjects)
        let changeRate = estimatedTotalObjects > 0
            ? Double(changedObjects) / Double(estimatedTotalObjects)
            : 0
        
        // Update EMA (exponential moving average)
        let newEma: Double
        if state.hasEma {
            newEma = (emaAlpha * changeRate) + ((1 - emaAlpha) * state.changeRateEma)
        } else {
            newEma = changeRate
            state.hasEma = true
        }
        state.changeRateEma = newEma
        
        return Result(
            changedObjects: changedObjects,
            unchangedObjects: unchangedObjects,
            estimatedTotalObjects: estimatedTotalObjects,
            changeRate: changeRate,
            changeRateEma: newEma
        )
    }
}

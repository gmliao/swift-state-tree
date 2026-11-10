import Foundation
import SwiftStateTree

/// Hero Defense's state size over a land's life, for measurement: per land, its tick, live
/// monster count, base health and player count, and its monster flows so far (spawned, killed,
/// reached the base), as of its last tick in each window, written as one JSONL line per window.
/// The load grows with a land's age (the spawn interval shortens over
/// `monsterSpawnAccelerationTicks`), and this is what shows by how much and through which flow.
///
/// It is outside the state: a land notes itself through `ctx.services`, and a land without a
/// recorder notes nothing, so records and replays don't change. GameServer registers it for live
/// hero-defense lands only: not for its replay land, nor for re-evaluation.
public enum HeroDefenseStatsEnvKeys {
    /// The JSONL file the stats are appended to. Unset: no stats.
    public static let path = "HERO_DEFENSE_STATS_PATH"
    /// Window length in ms, 100...60000. Default 1000.
    public static let intervalMs = "HERO_DEFENSE_STATS_INTERVAL_MS"
}

/// One land, as of its last tick in the window. The flows are the land's totals so far:
/// `monsters` = `spawned` - `killed` - `reachedBase` (kills by players and turrets alike).
public struct HeroDefenseLandSample: Codable, Equatable, Sendable {
    /// The land's 0-based tick ID of its last tick in the window (its age in ticks, less one).
    public var tick: Int64
    public var monsters: Int
    public var baseHealth: Int
    public var players: Int
    public var spawned: Int
    public var killed: Int
    public var reachedBase: Int

    public init(tick: Int64, monsters: Int, baseHealth: Int, players: Int, spawned: Int = 0, killed: Int = 0, reachedBase: Int = 0) {
        self.tick = tick
        self.monsters = monsters
        self.baseHealth = baseHealth
        self.players = players
        self.spawned = spawned
        self.killed = killed
        self.reachedBase = reachedBase
    }
}

/// The process's lands: each land's latest sample, with its kill and base totals kept here
/// (outside the state). A window holds the lands that ticked since the last one was taken.
public final class HeroDefenseStatsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lands: [String: HeroDefenseLandSample] = [:]
    /// Each land's tick as of the last window taken: a land is in the next window once it ticks past it.
    private var taken: [String: Int64] = [:]

    public init() {}

    /// Called at the end of the land's Tick handler, with this tick's kills and arrivals at the base.
    public func note(landID: String, tick: Int64, monsters: Int, baseHealth: Int, players: Int, spawned: Int,
                     killedThisTick: Int, reachedBaseThisTick: Int) {
        lock.lock()
        defer { lock.unlock() }
        let previous = lands[landID]
        lands[landID] = HeroDefenseLandSample(tick: tick, monsters: monsters, baseHealth: baseHealth, players: players,
                                              spawned: spawned,
                                              killed: (previous?.killed ?? 0) + killedThisTick,
                                              reachedBase: (previous?.reachedBase ?? 0) + reachedBaseThisTick)
    }

    /// The lands that ticked since the last window was taken, each as of its latest tick.
    public func takeWindow() -> [String: HeroDefenseLandSample] {
        lock.lock()
        defer { lock.unlock() }
        let window = lands.filter { landID, sample in taken[landID].map { sample.tick > $0 } ?? true }
        for (landID, sample) in window { taken[landID] = sample.tick }
        return window
    }
}

/// One JSONL line per window `(fromTs, ts]`: `ts` (ms since epoch on the server's wall clock,
/// when the window was taken, as the transport profiler's lines), `fromTs` the previous line's
/// `ts` (the writer's start for the first), and `lands`, by land ID. A land that didn't tick in
/// the window (not yet created, or destroyed) is absent. `writeFailures`: earlier lines that
/// couldn't be written, over the writer's life.
public struct HeroDefenseStatsLine: Codable, Equatable, Sendable {
    public var fromTs: Int
    public var ts: Int
    public var writeFailures: Int
    public var lands: [String: HeroDefenseLandSample]

    public init(fromTs: Int, ts: Int, lands: [String: HeroDefenseLandSample], writeFailures: Int = 0) {
        self.fromTs = fromTs
        self.ts = ts
        self.writeFailures = writeFailures
        self.lands = lands
    }
}

public struct HeroDefenseStatsSettingsError: Error, CustomStringConvertible {
    public let description: String
}

/// Appends a line per window to the stats file, from start until the process ends.
public enum HeroDefenseStatsWriter {
    public static let intervalRange = 100...60_000

    /// The recorder to register when `HERO_DEFENSE_STATS_PATH` is set (its writer started), or
    /// nil. Throws on a bad interval or a file that can't be opened.
    public static func startFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> HeroDefenseStatsRecorder? {
        guard let path = environment[HeroDefenseStatsEnvKeys.path], !path.isEmpty else { return nil }
        var intervalMs = 1000
        if let raw = environment[HeroDefenseStatsEnvKeys.intervalMs] {
            guard let value = Int(raw), intervalRange.contains(value) else {
                throw HeroDefenseStatsSettingsError(description: "\(HeroDefenseStatsEnvKeys.intervalMs)=\(raw): expected an integer in \(intervalRange)")
            }
            intervalMs = value
        }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw HeroDefenseStatsSettingsError(description: "\(HeroDefenseStatsEnvKeys.path)=\(path): can't create the file")
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw HeroDefenseStatsSettingsError(description: "\(HeroDefenseStatsEnvKeys.path)=\(path): can't open the file")
        }
        handle.seekToEndOfFile()
        let recorder = HeroDefenseStatsRecorder()
        let startTs = Int(Date().timeIntervalSince1970 * 1000)
        Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var fromTs = startTs
            var writeFailures = 0
            while !Task.isCancelled {
                try? await safeTaskSleep(for: .milliseconds(intervalMs))
                let ts = Int(Date().timeIntervalSince1970 * 1000)
                let line = HeroDefenseStatsLine(fromTs: fromTs, ts: ts, lands: recorder.takeWindow(), writeFailures: writeFailures)
                fromTs = ts
                do {
                    var data = try encoder.encode(line)
                    data.append(0x0A)
                    // Throws on a write error (a full disk) instead of raising an exception.
                    try handle.write(contentsOf: data)
                } catch {
                    writeFailures += 1
                    FileHandle.standardError.write(Data("hero-defense stats: line not written (\(error))\n".utf8))
                }
            }
        }
        return recorder
    }
}

// swift-tools-version: 5.9
// A standalone stress test for the release-only task-deallocation crash
// (Notes/solutions/2026-01-27-release-only-crashes-task-sleep-and-format-s.md). It depends on
// nothing in this repository, so it builds the same way on every toolchain.
import PackageDescription

let package = Package(
    name: "TaskSleepRepro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TaskSleepRepro"),
    ]
)

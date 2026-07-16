// swift-tools-version: 6.0
import PackageDescription

// Tests live in the `rc-tests` executable (run with `swift run rc-tests`):
// the Command Line Tools' swift-testing runner silently discovers no tests,
// so the suite uses a small hermetic harness instead.
let package = Package(
    name: "RhythmCoach",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RhythmCore", targets: ["RhythmCore"]),
        .library(name: "RhythmAudio", targets: ["RhythmAudio"]),
        .executable(name: "RhythmCoach", targets: ["RhythmCoachApp"]),
        .executable(name: "rc-cli", targets: ["rc-cli"]),
    ],
    targets: [
        .target(name: "RhythmCore"),
        .target(name: "RhythmAudio", dependencies: ["RhythmCore"]),
        .executableTarget(
            name: "RhythmCoachApp",
            dependencies: ["RhythmCore", "RhythmAudio"]
        ),
        .executableTarget(
            name: "rc-cli",
            dependencies: ["RhythmCore", "RhythmAudio"]
        ),
        .executableTarget(
            name: "rc-tests",
            dependencies: ["RhythmCore", "RhythmAudio"]
        ),
    ]
)

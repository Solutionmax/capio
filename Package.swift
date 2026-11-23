// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Capio",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CapioCore", path: "Sources/CapioCore"),
        .executableTarget(name: "Capio", dependencies: ["CapioCore"], path: "Sources/Capio"),
        .executableTarget(name: "capio-selftest", dependencies: ["CapioCore"], path: "Sources/capio-selftest"),
        .executableTarget(name: "capio-makeicon", dependencies: ["CapioCore"], path: "Sources/capio-makeicon"),
    ],
    swiftLanguageModes: [.v5]
)

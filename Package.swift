// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed, the build system sometimes leaves
// the Swift Testing macro plugin off incremental test builds ("plugin for module
// 'TestingMacros' not found"). Pointing at it explicitly makes it reliable.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins)
    ? [.unsafeFlags(["-plugin-path", testingPlugins])]
    : []

let package = Package(
    name: "PRtyTime",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PRtyTimeCore"),
        .executableTarget(name: "PRtyTime", dependencies: ["PRtyTimeCore"]),
        .testTarget(name: "PRtyTimeCoreTests", dependencies: ["PRtyTimeCore"], swiftSettings: testSettings),
    ]
)

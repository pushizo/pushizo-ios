// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeroSignalFramework",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "HeroSignal", targets: ["HeroSignal"]),
        .library(name: "HeroSignalExtension", targets: ["HeroSignalExtension"]),
    ],
    targets: [
        .target(name: "HeroSignalCore", path: "Sources/HeroSignalCore"),
        .target(name: "HeroSignal", dependencies: ["HeroSignalCore"], path: "Sources/HeroSignal"),
        .target(name: "HeroSignalExtension", dependencies: ["HeroSignalCore"], path: "Sources/HeroSignalExtension"),
        .testTarget(name: "HeroSignalTests", dependencies: ["HeroSignalCore"], path: "Tests/HeroSignalTests"),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PushizoFramework",
    // Mac Catalyst: iOS hedefiyle aynı asgari sürüm (iOS 15 ≙ Catalyst 15). Live Activities Catalyst'te `PLATFORM_NOT_SUPPORTED`.
    platforms: [.iOS(.v15), .macCatalyst(.v15)],
    products: [
        .library(name: "Pushizo", targets: ["Pushizo"]),
        .library(name: "PushizoExtension", targets: ["PushizoExtension"]),
    ],
    targets: [
        .target(name: "PushizoCore", path: "Sources/PushizoCore"),
        .target(name: "Pushizo", dependencies: ["PushizoCore"], path: "Sources/Pushizo"),
        .target(name: "PushizoExtension", dependencies: ["PushizoCore"], path: "Sources/PushizoExtension"),
        .testTarget(name: "PushizoTests", dependencies: ["PushizoCore"], path: "Tests/PushizoTests"),
    ]
)

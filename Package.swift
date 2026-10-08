// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Marquee",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Marquee", targets: ["Marquee"]),
        .library(name: "MarqueeCore", targets: ["MarqueeCore"]),
    ],
    targets: [
        .target(name: "MarqueeCore"),
        .executableTarget(name: "Marquee", dependencies: ["MarqueeCore"]),
        .testTarget(name: "MarqueeCoreTests", dependencies: ["MarqueeCore"]),
    ]
)

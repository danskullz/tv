// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Marquee",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Marquee", targets: ["Marquee"]),
        .library(name: "MarqueeCore", targets: ["MarqueeCore"]),
        .library(name: "MarqueeUI", targets: ["MarqueeUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MarqueeCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "MarqueeUI", dependencies: ["MarqueeCore"]),
        .executableTarget(name: "Marquee", dependencies: ["MarqueeCore", "MarqueeUI"]),
        .testTarget(
            name: "MarqueeCoreTests",
            dependencies: ["MarqueeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

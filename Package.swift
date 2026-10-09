// swift-tools-version:6.0
import Foundation
import PackageDescription

// libtorrent, OpenSSL and the Boost headers it needs are built by `scripts/build-libtorrent.sh`
// into the git-ignored Vendor/libtorrent (universal static libs + headers). Run it once before
// `swift build` (it is a cache hit after the first time on a machine). The manifest deliberately
// does not look at the file system: SwiftPM caches manifest evaluations and would not notice the
// directory appearing or disappearing. Without the build, CTorrentShim fails with a clear #error.
let libtorrentDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/Vendor/libtorrent"

let package = Package(
    name: "Marquee",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Marquee", targets: ["Marquee"]),
        .library(name: "MarqueeCore", targets: ["MarqueeCore"]),
        .library(name: "MarqueeUI", targets: ["MarqueeUI"]),
        .library(name: "MarqueePlayer", targets: ["MarqueePlayer"]),
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
        // libmpv headers only (ISC). The LGPL libmpv dylib is built by scripts/build-mpv.sh into
        // Vendor/mpv and dlopen'd at runtime from Contents/Frameworks; nothing links against it.
        .target(name: "CMpv"),
        .target(
            name: "MarqueePlayer",
            dependencies: ["CMpv", "MarqueeCore"],
            // OpenGL is deprecated but is the only render API libmpv offers on macOS; silence the noise.
            swiftSettings: [.unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"])],
            linkerSettings: [.linkedFramework("OpenGL"), .linkedFramework("QuartzCore")]
        ),
        .executableTarget(name: "Marquee", dependencies: ["MarqueeCore", "MarqueeUI", "TorrentEngine", "MarqueeEngine", "MarqueePlayer"]),
        .testTarget(
            name: "MarqueeCoreTests",
            dependencies: ["MarqueeCore"],
            resources: [.copy("Fixtures")]
        ),

        // C++ implementation behind a pure-C header; owns the libtorrent link.
        .target(
            name: "CTorrentShim",
            cxxSettings: [
                // -isystem keeps third-party header warnings out of our build output.
                .unsafeFlags(["-isystem", libtorrentDir + "/include"]),
            ],
            linkerSettings: [
                // Universal archives: the linker picks the slice for the arch being built, so
                // `swift build --arch arm64` and `--arch x86_64` both work.
                .unsafeFlags([
                    libtorrentDir + "/lib/libtorrent-rasterbar.a",
                    libtorrentDir + "/lib/libssl.a",
                    libtorrentDir + "/lib/libcrypto.a",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(name: "TorrentEngine", dependencies: ["CTorrentShim"]),
        .testTarget(name: "TorrentEngineTests", dependencies: ["TorrentEngine"]),

        // Streaming critical path: joins the torrent engine to the stream server and the pack planner.
        .target(name: "MarqueeEngine", dependencies: ["MarqueeCore", "TorrentEngine"]),
        .testTarget(name: "MarqueeEngineTests", dependencies: ["MarqueeEngine", "MarqueeCore", "TorrentEngine"]),
        .testTarget(name: "MarqueePlayerTests", dependencies: ["MarqueePlayer"], resources: [.copy("Fixtures")]),
    ],
    cxxLanguageStandard: .cxx17
)

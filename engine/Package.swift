// swift-tools-version: 6.0
import PackageDescription

// SQLCipher is a 50 MB prebuilt framework fetched by scripts/fetch-sqlcipher.sh into .local/
// (checksum-verified, resumable). If a build says the path is missing, run that script, then
// `touch Package.swift` so SwiftPM re-reads the manifest.
let package = Package(
    name: "thatone-engine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ThatOneCore", targets: ["ThatOneCore"]),
        .executable(name: "thatone", targets: ["thatone"]),
    ],
    targets: [
        .binaryTarget(name: "SQLCipher", path: ".local/SQLCipher.xcframework"),
        .target(name: "CVec", cSettings: [.define("SQLITE_CORE"), .define("SQLITE_VEC_STATIC")]),
        .target(name: "ThatOneCore", dependencies: ["CVec", "SQLCipher"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "thatone", dependencies: ["ThatOneCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ThatOneCoreTests", dependencies: ["ThatOneCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

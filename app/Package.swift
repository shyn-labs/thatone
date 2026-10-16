// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "thatone-app",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../engine"),
        // Speech to text for audio search; the same version shyn pins. App target only: the engine and its tests never load it.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .target(name: "ThatOneApp", dependencies: [.product(name: "ThatOneCore", package: "engine"), .product(name: "WhisperKit", package: "WhisperKit")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ThatOne", dependencies: ["ThatOneApp"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ThatOneAppTests", dependencies: ["ThatOneApp", .product(name: "ThatOneCore", package: "engine")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceTermPoC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "1.2.3"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceTermPoC",
            dependencies: [
                "SwiftTerm",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        )
    ]
)

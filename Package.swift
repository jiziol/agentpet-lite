// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPet",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CUsageZstd", path: "Sources/CUsageZstd",
            exclude: ["LICENSE", "UPSTREAM.json"],
            sources: ["decode.c", "lib/common", "lib/decompress"], publicHeadersPath: "include",
            cSettings: [.define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_DISABLE_ASM")]),
        .target(
            name: "AgentPetCore",
            dependencies: ["CSQLite", "CUsageZstd"],
            path: "Sources/AgentPetCore",
            swiftSettings: [.define("AGENTPET_LOCAL")]
        ),
        .executableTarget(
            name: "agentpet",
            dependencies: ["AgentPetCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/App",
            resources: [.copy("Resources/DefaultPets"), .copy("Resources/Icons")],
            swiftSettings: [.define("AGENTPET_LOCAL")]
        ),
        .testTarget(
            name: "AgentPetCoreTests",
            dependencies: ["AgentPetCore"],
            path: "Tests/AgentPetCoreTests"
        ),
        .testTarget(
            name: "AgentPetAppTests",
            dependencies: ["agentpet"],
            path: "Tests/AgentPetAppTests"
        ),
    ]
)

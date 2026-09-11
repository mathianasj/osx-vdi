// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "osx-vdi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "vdi-server", targets: ["VDIServer"]),
        .executable(name: "vdi-client", targets: ["VDIClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "VDICore"
        ),
        .target(
            name: "CGVirtualDisplayBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "VDIServer",
            dependencies: [
                "VDICore",
                "CGVirtualDisplayBridge",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            resources: [
                .copy("WebLauncher/Resources"),
            ]
        ),
        .executableTarget(
            name: "VDIClient",
            dependencies: ["VDICore"]
        ),
        .testTarget(
            name: "VDICoreTests",
            dependencies: ["VDICore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

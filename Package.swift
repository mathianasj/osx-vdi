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
            dependencies: ["VDICore", "CGVirtualDisplayBridge"]
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

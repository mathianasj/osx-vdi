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
        .executable(name: "vdi-audio-test", targets: ["VDIAudioTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SHMBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VDICore",
            dependencies: ["SHMBridge"]
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
            ],
            resources: [
                .copy("WebLauncher/Resources"),
            ]
        ),
        .executableTarget(
            name: "VDIClient",
            dependencies: ["VDICore"]
        ),
        .executableTarget(
            name: "VDIAudioTest",
            dependencies: ["VDICore"]
        ),
        .testTarget(
            name: "VDICoreTests",
            dependencies: ["VDICore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

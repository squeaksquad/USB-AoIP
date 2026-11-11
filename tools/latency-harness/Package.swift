// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "USB16x16Latency",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USB16x16LatencyCore", targets: ["USB16x16LatencyCore"]),
        .executable(name: "usb16x16-latency", targets: ["usb16x16-latency"]),
    ],
    targets: [
        .target(
            name: "USB16x16LatencyCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "usb16x16-latency",
            dependencies: ["USB16x16LatencyCore"]
        ),
        .testTarget(
            name: "USB16x16LatencyCoreTests",
            dependencies: ["USB16x16LatencyCore"]
        ),
    ]
)

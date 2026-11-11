// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "usb-aoip-spike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "usb-aoip-spike",
            linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit")]
        )
    ]
)

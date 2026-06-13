// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mac-fanctl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fanctl", targets: ["fanctl"]),
    ],
    targets: [
        .executableTarget(
            name: "fanctl",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HuiSheng",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "HuiSheng", targets: ["HuiSheng"])],
    targets: [
        .executableTarget(name: "HuiSheng", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
